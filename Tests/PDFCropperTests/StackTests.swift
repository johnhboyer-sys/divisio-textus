import Testing
import Foundation
import AppKit
import PDFKit
@testable import PDFCropper

@Suite("Stack review", .serialized)
struct StackTests {
    @Test("Spreads, alternating singles and skipped pages form separate stacks")
    func grouping() {
        let types: [PageClassification] = [.single, .spread, .skip, .single, .spread, .single, .single]
        let pages = types.enumerated().map { BookPage(sourceIndex: $0.offset, classification: $0.element) }
        let stacks = PageStack.groups(pages: pages)
        #expect(stacks.map(\.id) == [.left, .right, .singleA, .singleB])
        #expect(stacks.map { $0.members.map { $0.page.sourceIndex } } == [[1, 4], [1, 4], [0, 5], [3, 6]])
        #expect(PageStack.groups(pages: [pages[2]]).isEmpty)
        #expect(PageStack.groups(pages: [pages[0]]).map(\.id) == [.singleA])
    }

    @Test("Side coordinates round trip with each page's own split")
    func coordinates() {
        let crop = CropRect(x: 0.13, y: 0.17, width: 0.64, height: 0.7)
        for split in [0.35, 0.62] {
            let page = BookPage(sourceIndex: 0, splitX: split)
            for side in [PageStack.Member.Side.left, .right, .single] {
                let member = PageStack.Member(page: page, side: side)
                let result = member.localCrop(member.pageCrop(crop))
                #expect(abs(result.x - crop.x) < 1e-10)
                #expect(abs(result.width - crop.width) < 1e-10)
                #expect(result.y == crop.y && result.height == crop.height)
            }
        }
    }

    @Test("The smallest box stays on its own side and export leaves it as applied")
    func smallestBox() {
        // Against the gutter on the left side, and against it on the right.
        for (side, x) in [(PageStack.Member.Side.left, 0.98), (.right, 0.0)] {
            for split in [0.5, 0.3] {
                let member = PageStack.Member(page: BookPage(sourceIndex: 0, splitX: split), side: side)
                let c = member.clampedCrop(CropRect(x: x, y: 0.2, width: 0.02, height: 0.5))
                #expect(c.minX >= member.regionMinX - 1e-12)
                #expect(c.maxX <= member.regionMinX + member.regionWidth + 1e-12)
                #expect(c.normalized() == c)   // export normalizes; nothing may move
            }
        }
    }

    @Test("Outliers differ in size on the page, not in position or split")
    func outliers() throws {
        // The gutter moves from spread to spread, so the same text block is a different
        // share of each half; on the page it is the same size. Page 2 is changed.
        for (wider, shift, flagged) in [(0.04, 0.0, true), (0.01, 0.0, false), (0.0, 0.05, false)] {
            let pages = (0..<5).map { i -> BookPage in
                var page = BookPage(sourceIndex: i, splitX: [0.45, 0.55, 0.5, 0.47, 0.53][i])
                page.leftCrop = CropRect(x: 0.05 + (i == 2 ? shift : 0), y: 0.1,
                                         width: 0.35 + (i == 2 ? wider : 0), height: 0.8)
                return page
            }
            let stack = try #require(PageStack.groups(pages: pages).first)
            #expect(stack.outliers.map { $0.page.sourceIndex } == (flagged ? [2] : []))
        }
        var pages = (0..<5).map { BookPage(sourceIndex: $0, classification: .single,
            leftCrop: CropRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)) }
        pages[0].leftCrop.height += 0.1
        pages[4].leftCrop.y += 0.1
        pages[3].leftCrop.width -= 0.1
        let members = [4, 3, 2, 1, 0].map { PageStack.Member(page: pages[$0], side: .single) }
        #expect(PageStack(id: .singleA, members: members).outliers.map { $0.page.sourceIndex } == [0, 3])
    }

    @Test("Apply clamps to each split and one undo restores every changed page")
    @MainActor
    func applyAndUndo() throws {
        let model = testModel(), undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.pages = [BookPage(sourceIndex: 0, splitX: 0.35, analyzed: true),
                       BookPage(sourceIndex: 1, splitX: 0.65, analyzed: true),
                       BookPage(sourceIndex: 2, classification: .single, analyzed: true)]
        let before = model.pages
        let groups = PageStack.groups(pages: model.pages)
        let left = try #require(groups.first { $0.id == .left })
        let right = try #require(groups.first { $0.id == .right })
        let outside = CropRect(x: -0.2, y: -0.1, width: 1.4, height: 1.3)
        undoable(undo) { model.applyStackCrop(outside, to: left.members) }
        for page in model.pages.prefix(2) {
            #expect(page.leftCrop.minX >= 0 && page.leftCrop.maxX <= page.splitX)
            #expect(abs(page.leftCrop.width - page.splitX) < 1e-10)
        }
        #expect(model.pages[2] == before[2])
        #expect(undo.undoActionName == "Apply Crop to Stack")
        undo.undo()
        #expect(model.pages == before)
        #expect(!undo.canUndo)
        undoable(undo) { model.applyStackCrop(outside, to: right.members) }
        for page in model.pages.prefix(2) {
            #expect(page.rightCrop.minX >= page.splitX && page.rightCrop.maxX <= 1)
        }
        undo.undo()
        #expect(model.pages == before)

        undoable(undo) { model.applyStackCrop(.full, to: [left.members[1]]) }
        #expect(model.pages[0] == before[0] && model.pages[2] == before[2])
        #expect(model.pages[1].leftCrop.maxX <= model.pages[1].splitX)
        undo.undo()
        #expect(model.pages == before)
    }

    @Test("The chosen stack and its draft crop last until another PDF is opened")
    @MainActor
    func draftsReset() async {
        let model = testModel()
        model.load(url: Fixtures.sampleBook())
        await waitUntilIdle(model)
        model.stackKind = .right
        model.stackCrops[.right] = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        model.showsStack = false
        model.showsStack = true
        #expect(model.stackKind == .right && model.stackCrops[.right] != nil)
        model.load(url: Fixtures.sampleBook())
        await waitUntilIdle(model)
        #expect(model.stackKind == .left && model.stackCrops.isEmpty)
    }

    @Test("A blend puts common and rare ink at the correct side-local positions")
    func renderer() throws {
        let media = CGRect(x: 0, y: 0, width: 240, height: 240)
        let url = Fixtures.writePDF("stack-\(UUID().uuidString).pdf", media: media, pages: (0..<4).map { i in
            { c in
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
                c.setFillColor(CGColor(gray: 0, alpha: 1))
                // A shared mark near the left side's top, plus one rare mark below it.
                c.fill(CGRect(x: 24, y: 168, width: 24, height: 24))
                if i == 0 { c.fill(CGRect(x: 72, y: 48, width: 24, height: 24)) }
                c.fill(CGRect(x: 168, y: 108, width: 24, height: 24))
            }
        })
        let doc = try #require(PDFDocument(url: url))
        let pages = (0..<4).map { BookPage(sourceIndex: $0) }
        let groups = PageStack.groups(pages: pages)
        let image = try #require(StackRenderer.render(groups[0], from: doc))
        #expect(image.width == 50 && image.height == 100 && image.bitsPerPixel == 8)
        let gray = try #require(GrayBuffer(cgImage: image))
        #expect(gray.value(15, 25) < 20)
        #expect(abs(Int(gray.value(35, 75)) - 128) < 12)
        #expect(gray.value(35, 25) > 245)
        #expect(gray.value(15, 75) > 245)
        let rightImage = try #require(StackRenderer.render(groups[1], from: doc))
        let right = try #require(GrayBuffer(cgImage: rightImage))
        #expect(right.value(25, 50) < 20)
        #expect(right.value(15, 25) > 245)
        #expect(StackRenderer.render(groups[0], from: doc, isCancelled: { true }) == nil)

        // Split among threads, each with its own document, the blend comes out the same.
        let split = try #require(StackRenderer.render(groups[0], workers: 3,
                                                      open: { PDFDocument(url: url) }, isCancelled: { false }))
        let a = try #require(image.dataProvider?.data as Data?)
        let b = try #require(split.dataProvider?.data as Data?)
        #expect(a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }
}
