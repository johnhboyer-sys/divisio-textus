import Testing
import Foundation
import PDFKit
@testable import PDFCropper

@Suite("Whole-spread stack", .serialized)
struct WholeSpreadTests {
    @Test("Only spreads join, each whole; today's stacks are unchanged")
    func membership() throws {
        let types: [PageClassification] = [.single, .spread, .skip, .single, .spread, .single, .single]
        let pages = types.enumerated().map { BookPage(sourceIndex: $0.offset, classification: $0.element) }
        let whole = try #require(PageStack.wholeSpreads(pages: pages))
        #expect(whole.id == .spreads)
        #expect(whole.members.map { $0.page.sourceIndex } == [1, 4])
        #expect(whole.members.allSatisfy { $0.side == .whole && $0.regionMinX == 0 && $0.regionWidth == 1 })
        // groups() measures the page size and marks the rail: it never holds this stack.
        #expect(PageStack.groups(pages: pages).map(\.id) == [.left, .right, .singleA, .singleB])
        #expect(PageStack.all(pages: pages).map(\.id) == [.left, .right, .singleA, .singleB, .spreads])
        #expect(PageStack.wholeSpreads(pages: [pages[0], pages[2]]) == nil)
    }

    @Test("A spread is flagged when its split is over 3% of the scan's width from the median")
    func splitOutliers() throws {
        let splits = [0.50, 0.51, 0.49, 0.50, 0.535, 0.46, 0.475]
        var pages = splits.enumerated().map { BookPage(sourceIndex: $0.offset, splitX: $0.element) }
        pages[1].leftCrop.width += 0.2      // a crop of another size isn't this stack's concern
        pages.append(BookPage(sourceIndex: 7, classification: .single, splitX: 0.9))
        let stack = try #require(PageStack.wholeSpreads(pages: pages))
        #expect(stack.outliers.map { $0.page.sourceIndex } == [4, 5])
        #expect(stack.medianLayout.splitX == 0.5)
        func close(_ a: CropRect, _ b: CropRect) -> Bool {
            [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 1e-12 }
        }
        #expect(close(stack.medianLayout.leftCrop, BookPage(sourceIndex: 0).leftCrop))
        #expect(close(stack.medianLayout.rightCrop, BookPage(sourceIndex: 0).rightCrop))
    }

    @Test("Apply sets the split and both crops on the flagged spreads or all, keeps the angles, and undoes in one step")
    @MainActor
    func applyAndUndo() throws {
        let model = testModel(), undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.pages = [0.50, 0.50, 0.58].enumerated().map {
            BookPage(sourceIndex: $0.offset, splitX: $0.element, leftSkew: 0.4, rightSkew: -0.3, analyzed: true)
        } + [BookPage(sourceIndex: 3, classification: .single, analyzed: true)]
        let before = model.pages
        let stack = try #require(PageStack.wholeSpreads(pages: model.pages))
        #expect(stack.outliers.map { $0.page.sourceIndex } == [2])
        let layout = SpreadLayout(splitX: 0.52, leftCrop: CropRect(x: 0.05, y: 0.1, width: 0.42, height: 0.8),
                                  rightCrop: CropRect(x: 0.56, y: 0.12, width: 0.4, height: 0.78))
        func hasLayout(_ page: BookPage) -> Bool {
            page.splitX == layout.splitX && page.leftCrop == layout.leftCrop && page.rightCrop == layout.rightCrop
                && page.leftSkew == 0.4 && page.rightSkew == -0.3
        }

        undoable(undo) { model.applySpreadLayout(layout, to: stack.outliers) }
        #expect(hasLayout(model.pages[2]))
        #expect(Array(model.pages[0...1]) == Array(before[0...1]) && model.pages[3] == before[3])
        #expect(undo.undoActionName == "Apply Layout to Spreads")
        undo.undo()
        #expect(model.pages == before)

        undoable(undo) { model.applySpreadLayout(layout, to: stack.members) }
        #expect(model.pages.prefix(3).allSatisfy(hasLayout))
        #expect(model.pages[3] == before[3])
        #expect(PageStack.wholeSpreads(pages: model.pages)?.outliers.isEmpty == true)
        undo.undo()
        #expect(model.pages == before)
        #expect(!undo.canUndo)
    }

    @Test("Applied boxes stay on their own side of the split")
    @MainActor
    func applyClamps() throws {
        let model = testModel()
        model.pages = [BookPage(sourceIndex: 0, analyzed: true)]
        let stack = try #require(PageStack.wholeSpreads(pages: model.pages))
        let layout = SpreadLayout(splitX: 0.4, leftCrop: CropRect(x: -0.1, y: 0.1, width: 0.6, height: 0.8),
                                  rightCrop: CropRect(x: 0.3, y: 0.1, width: 0.8, height: 0.8))
        model.applySpreadLayout(layout, to: stack.members)
        let page = model.pages[0]
        #expect(page.leftCrop.minX >= 0 && abs(page.leftCrop.maxX - 0.4) < 1e-12)
        #expect(abs(page.rightCrop.minX - 0.4) < 1e-12 && page.rightCrop.maxX <= 1 + 1e-12)
        #expect(page.leftCrop.normalized() == page.leftCrop && page.rightCrop.normalized() == page.rightCrop)
    }

    @Test("Moving the draft split carries the boxes' inner edges, as in Page view")
    func movingSplit() {
        var layout = SpreadLayout(splitX: 0.5, leftCrop: CropRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8),
                                  rightCrop: CropRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8))
        layout.moveSplit(to: 0.53)
        #expect(layout.splitX == 0.53)
        #expect(layout.leftCrop.minX == 0.05 && abs(layout.leftCrop.maxX - 0.53) < 1e-12)
        #expect(abs(layout.rightCrop.minX - 0.53) < 1e-12 && abs(layout.rightCrop.maxX - 0.95) < 1e-12)
        layout.moveSplit(to: 0.99)
        #expect(layout.splitX == 0.95)
    }

    @Test("The draft layout lasts until another PDF is opened, and the stack builds its blend")
    @MainActor
    func draftAndImage() async throws {
        let model = testModel()
        model.load(url: Fixtures.sampleBook())
        await waitUntilIdle(model)
        let stack = try #require(PageStack.wholeSpreads(pages: model.pages))
        #expect(await model.stackImage(for: stack) != nil)
        model.stackKind = .spreads
        model.spreadLayout = stack.medianLayout
        model.showsStack = false
        model.showsStack = true
        #expect(model.stackKind == .spreads && model.spreadLayout != nil)
        model.load(url: Fixtures.sampleBook())
        await waitUntilIdle(model)
        #expect(model.stackKind == .left && model.spreadLayout == nil)
    }

    @Test("A whole spread blends at full width, in page coordinates")
    func renderer() throws {
        let media = CGRect(x: 0, y: 0, width: 240, height: 120)
        let url = Fixtures.writePDF("whole-\(UUID().uuidString).pdf", media: media, pages: (0..<2).map { _ in
            { c in
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
                c.setFillColor(CGColor(gray: 0, alpha: 1))
                c.fill(CGRect(x: 24, y: 72, width: 24, height: 24))     // left half, near the top
                c.fill(CGRect(x: 192, y: 24, width: 24, height: 24))    // right half, near the bottom
            }
        })
        let doc = try #require(PDFDocument(url: url))
        let stack = try #require(PageStack.wholeSpreads(pages: (0..<2).map { BookPage(sourceIndex: $0) }))
        let image = try #require(StackRenderer.render(stack, from: doc))
        #expect(image.width == 100 && image.height == 50)
        let gray = try #require(GrayBuffer(cgImage: image))
        #expect(gray.value(15, 15) < 20)
        #expect(gray.value(85, 35) < 20)
        #expect(gray.value(50, 25) > 245 && gray.value(85, 15) > 245 && gray.value(15, 35) > 245)
    }
}
