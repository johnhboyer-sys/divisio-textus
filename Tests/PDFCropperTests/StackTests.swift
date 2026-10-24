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
        undoable(undo) { model.applyStackCrop(outside, to: left.members, in: left) }
        for page in model.pages.prefix(2) {
            #expect(page.leftCrop.minX >= 0 && page.leftCrop.maxX <= page.splitX)
            #expect(abs(page.leftCrop.width - page.splitX) < 1e-10)
        }
        #expect(model.pages[2] == before[2])
        #expect(undo.undoActionName == "Apply Crop to Stack")
        undo.undo()
        #expect(model.pages == before)
        #expect(!undo.canUndo)
        undoable(undo) { model.applyStackCrop(outside, to: right.members, in: right) }
        for page in model.pages.prefix(2) {
            #expect(page.rightCrop.minX >= page.splitX && page.rightCrop.maxX <= 1)
        }
        undo.undo()
        #expect(model.pages == before)

        undoable(undo) { model.applyStackCrop(.full, to: [left.members[1]], in: left) }
        #expect(model.pages[0] == before[0] && model.pages[2] == before[2])
        #expect(model.pages[1].leftCrop.maxX <= model.pages[1].splitX)
        undo.undo()
        #expect(model.pages == before)
    }

    @Test("Applied crops are one size on the page, the same distance from the gutter")
    @MainActor
    func appliedSize() throws {
        // The gutter sits at 0.45 on one spread and 0.55 on the other, so their halves
        // differ; the text block, and so the applied crop, should not. The stack is as
        // wide as the widest half, 0.55, so a box 0.6 of the stack wide is 0.33 of a scan.
        let model = testModel()
        model.pages = [BookPage(sourceIndex: 0, splitX: 0.45, analyzed: true),
                       BookPage(sourceIndex: 1, splitX: 0.55, analyzed: true)]
        let groups = PageStack.groups(pages: model.pages)
        let left = try #require(groups.first { $0.id == .left })
        let right = try #require(groups.first { $0.id == .right })
        let box = CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        model.applyStackCrop(box, to: left.members, in: left)
        model.applyStackCrop(box, to: right.members, in: right)
        let (a, b) = (model.pages[0], model.pages[1])
        #expect(abs(a.leftCrop.width - 0.33) < 1e-10 && abs(b.leftCrop.width - 0.33) < 1e-10)
        #expect(abs((a.splitX - a.leftCrop.maxX) - (b.splitX - b.leftCrop.maxX)) < 1e-10)
        #expect(abs(a.rightCrop.width - b.rightCrop.width) < 1e-10)
        #expect(abs((a.rightCrop.minX - a.splitX) - (b.rightCrop.minX - b.splitX)) < 1e-10)
        // Applied crops are no longer flagged.
        for stack in PageStack.groups(pages: model.pages) { #expect(stack.outliers.isEmpty) }
    }

    @Test("Apply puts each page's crop exactly where the stack shows it (review finding 5)")
    func applyMatchesStack() throws {
        for kind in [PageStack.Kind.left, .right] {
            let pages = [0.45, 0.55].enumerated().map { BookPage(sourceIndex: $0.offset, splitX: $0.element) }
            let stack = try #require(PageStack.groups(pages: pages).first { $0.id == kind })
            let draft = CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
            for member in stack.members {
                let shown = member.pageCrop(draft), applied = member.clampedCrop(draft)
                #expect(abs(applied.minX - shown.minX) < 1e-9 && abs(applied.maxX - shown.maxX) < 1e-9,
                        "\(kind) split \(member.page.splitX): shown \(shown.minX)…\(shown.maxX), applied \(applied.minX)…\(applied.maxX)")
                // And what the stack outlines for that crop is the box itself.
                let back = member.localCrop(applied)
                #expect(abs(back.minX - draft.minX) < 1e-9 && abs(back.maxX - draft.maxX) < 1e-9)
            }
        }
    }

    @Test("A box at the stack's outer edge reaches each page's edge, and stays in its half")
    func outerEdgeAndNarrowHalf() {
        let pages = [0.45, 0.55].enumerated().map { BookPage(sourceIndex: $0.offset, splitX: $0.element) }
        let groups = PageStack.groups(pages: pages)
        for stack in groups where stack.id == .left || stack.id == .right {
            for member in stack.members {
                let split = member.page.splitX
                if stack.id == .left {
                    // Out to the stack's outer edge: the page's own outer edge, whatever its half.
                    let l = member.clampedCrop(CropRect(x: 0, y: 0.1, width: 0.8, height: 0.8))
                    #expect(l.minX == 0 && abs(split - l.maxX - 0.2 * stack.span) < 1e-10)
                } else {
                    let r = member.clampedCrop(CropRect(x: 0.2, y: 0.1, width: 0.8, height: 0.8))
                    #expect(abs(r.maxX - 1) < 1e-10 && abs(r.minX - split - 0.2 * stack.span) < 1e-10)
                }
            }
        }
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

    @Test("The blend shows each half at true size, lined up at the fold (review finding 5)")
    func trueSizeBlend() throws {
        // Two spreads whose fold sits at 0.45 and at 0.55 of the scan. On each, a line
        // 0.12 of the scan's width left of the fold and one 0.12 right of it: the same
        // place on the page, so a truthful blend draws each as one solid line.
        let media = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let splits = [0.45, 0.55]
        let url = Fixtures.writePDF("truesize-\(UUID().uuidString).pdf", media: media, pages: splits.map { split in
            { c in
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
                c.setFillColor(CGColor(gray: 0, alpha: 1))
                c.fill(CGRect(x: (split - 0.12) * 1000 - 8, y: 100, width: 16, height: 450))
                c.fill(CGRect(x: (split + 0.12) * 1000 - 8, y: 100, width: 16, height: 450))
            }
        })
        let doc = try #require(PDFDocument(url: url))
        let pages = splits.enumerated().map { BookPage(sourceIndex: $0.offset, splitX: $0.element, analyzed: true) }
        for (kind, offset) in [(PageStack.Kind.left, -0.12), (.right, 0.12)] {
            let stack = try #require(PageStack.groups(pages: pages).first { $0.id == kind })
            let image = try #require(StackRenderer.render(stack, from: doc))
            let g = try #require(GrayBuffer(cgImage: image, maxDim: max(image.width, image.height)))
            // The darkest column across the middle row: both lines on it means full ink.
            let y = g.height / 2
            let darkest = (0..<g.width).map { Int(g.value($0, y)) }.min() ?? 255
            #expect(darkest < 40, "\(kind): darkest \(darkest); one solid line expected, not two faint ones")
            // And it sits 0.12 of the scan from the fold, measured at true size.
            let x = (0..<g.width).min { g.value($0, y) < g.value($1, y) }!
            let fromFold = kind == .left ? Double(g.width - x) : Double(x)
            let scale = Double(g.width) / 0.55               // pixels per scan width: the widest half is 0.55
            #expect(abs(fromFold / scale - abs(offset)) < 0.02, "\(kind): \(fromFold / scale) of the scan from the fold")
        }
    }

    @Test("A line near the fold is drawn exactly where the stack's coordinates put it (review, rounding)")
    func blendMatchesCoordinates() throws {
        // A 240-point scan is 100 pixels at the blend's 30 DPI, so a split at 0.455
        // falls between pixels; the line at 0.445 must still land where Apply sees it.
        let media = CGRect(x: 0, y: 0, width: 240, height: 240)
        let url = Fixtures.writePDF("round-\(UUID().uuidString).pdf", media: media, pages: [{ c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
            c.setFillColor(CGColor(gray: 0, alpha: 1))
            c.fill(CGRect(x: 0.445 * 240 - 0.6, y: 40, width: 1.2, height: 160))
        }])
        let doc = try #require(PDFDocument(url: url))
        let page = BookPage(sourceIndex: 0, splitX: 0.455, analyzed: true)
        let stack = try #require(PageStack.groups(pages: [page]).first { $0.id == .left })
        let image = try #require(StackRenderer.render(stack, from: doc))
        let g = try #require(GrayBuffer(cgImage: image, maxDim: max(image.width, image.height)))
        let y = g.height / 2
        let darkest = (0..<g.width).min { g.value($0, y) < g.value($1, y) }!
        let shown = (Double(darkest) + 0.5) / Double(g.width)
        let expected = stack.members[0].localCrop(CropRect(x: 0.445, y: 0, width: 0, height: 1)).x
        #expect(abs(shown - expected) < 1.0 / Double(g.width), "shown at \(shown), coordinates say \(expected)")
    }

    @Test("A drawn box keeps its place on the page when a split elsewhere changes the stack's width (review)")
    @MainActor
    func draftFollowsSpan() throws {
        let model = testModel()
        model.pages = [BookPage(sourceIndex: 0, splitX: 0.5, analyzed: true),
                       BookPage(sourceIndex: 1, splitX: 0.6, analyzed: true)]
        let before = try #require(PageStack.groups(pages: model.pages).first { $0.id == .left })
        model.setStackDraft(CropRect(x: 0.2, y: 0.1, width: 0.7, height: 0.8), for: before)
        let onFirstPage = before.members[0].pageCrop(model.stackDraft(for: before))
        model.pages[1].splitX = 0.5                                  // the stack is now narrower
        let after = try #require(PageStack.groups(pages: model.pages).first { $0.id == .left })
        let now = after.members[0].pageCrop(model.stackDraft(for: after))
        #expect(abs(now.minX - onFirstPage.minX) < 1e-9 && abs(now.maxX - onFirstPage.maxX) < 1e-9,
                "was \(onFirstPage.minX)…\(onFirstPage.maxX), now \(now.minX)…\(now.maxX)")
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

@Suite("Leaving pages out of a stack", .serialized)
struct StackPickTests {
    /// Five spreads whose left crops are the same size except page 2, which is wider.
    private func book() -> [BookPage] {
        (0..<5).map { i in
            var page = BookPage(sourceIndex: i, splitX: 0.5, analyzed: true)
            page.leftCrop = CropRect(x: 0.05, y: 0.1, width: i == 2 ? 0.40 : 0.30, height: 0.8)
            page.rightCrop = CropRect(x: 0.55, y: 0.1, width: 0.3, height: 0.8)
            return page
        }
    }

    private func stack(_ kind: PageStack.Kind, _ pages: [BookPage], out: [Int]) throws -> PageStack {
        let excluded = Set(out.map { pages[$0].id })
        return try #require(PageStack.all(pages: pages, excluded: [kind: excluded]).first { $0.id == kind })
    }

    @Test("A page left out is not a member of its stack, but is still listed with the rest")
    func membersLeaveOut() throws {
        let pages = book()
        let left = try stack(.left, pages, out: [1, 3])
        #expect(left.members.map { $0.page.sourceIndex } == [0, 2, 4])
        #expect(left.excludedMembers.map { $0.page.sourceIndex } == [1, 3])
        #expect(left.allMembers.map { $0.page.sourceIndex } == [0, 1, 2, 3, 4])
        // Without a list of exclusions nothing changes.
        #expect(PageStack.all(pages: pages).allSatisfy { $0.excludedMembers.isEmpty })
        #expect(PageStack.all(pages: pages).first { $0.id == .left }?.members.count == 5)
    }

    @Test("A page left out of one stack stays in the others")
    func perStack() throws {
        let pages = book()
        let excluded: [PageStack.Kind: Set<BookPage.ID>] = [.left: [pages[0].id]]
        let stacks = PageStack.all(pages: pages, excluded: excluded)
        func count(_ kind: PageStack.Kind) -> Int? { stacks.first { $0.id == kind }?.members.count }
        #expect(count(.left) == 4)
        #expect(count(.right) == 5)
        #expect(count(.spreads) == 5)
    }

    @Test("A stack with every page left out still exists, and is empty")
    func allOut() throws {
        let pages = book()
        let empty = try stack(.right, pages, out: [0, 1, 2, 3, 4])
        #expect(empty.members.isEmpty && empty.excludedMembers.count == 5)
        #expect(empty.outliers.isEmpty)
    }

    @Test("Outliers and the median crop ignore a page left out")
    func outliersAndMedian() throws {
        let pages = book()
        #expect(try stack(.left, pages, out: []).outliers.map { $0.page.sourceIndex } == [2])
        let without = try stack(.left, pages, out: [2])
        #expect(without.outliers.isEmpty)
        // The median is in the stack's own coordinates; on the page it is the usual 0.30.
        #expect(abs(without.members[0].pageCrop(without.medianCrop).width - 0.30) < 1e-9)
        let only = try stack(.left, pages, out: [0, 1, 3, 4])
        #expect(only.members.map { $0.page.sourceIndex } == [2] && only.outliers.isEmpty)
        // Leaving two pages out moves the median.
        var tall = book()
        for i in 0..<5 { tall[i].leftCrop.y = 0.1 + 0.05 * Double(i) }
        let all = try stack(.left, tall, out: [])
        let fewer = try stack(.left, tall, out: [3, 4])
        #expect(abs(all.medianCrop.y - 0.2) < 1e-9)
        #expect(abs(fewer.medianCrop.y - 0.15) < 1e-9)
    }

    @Test("The whole-spread stack's median layout and split flags ignore a spread left out")
    func spreadLayoutIgnores() throws {
        var pages = book()
        pages[4].splitX = 0.6
        pages[4].leftCrop = CropRect(x: 0.1, y: 0.2, width: 0.4, height: 0.6)
        let all = try stack(.spreads, pages, out: [])
        #expect(all.outliers.map { $0.page.sourceIndex } == [4])
        let without = try stack(.spreads, pages, out: [4])
        #expect(without.outliers.isEmpty)
        #expect(without.members.count == 4)
        #expect(without.medianLayout.splitX == 0.5)
        #expect(without.medianLayout.leftCrop.minY == 0.1)
        #expect(all.medianLayout.leftCrop.minY == 0.1)
        // The median is of the crops that are in: put page 4's top high and it moves only when in.
        pages[4].leftCrop.y = 0.9
        pages[3].leftCrop.y = 0.9
        pages[2].leftCrop.y = 0.9
        #expect(try stack(.spreads, pages, out: []).medianLayout.leftCrop.minY == 0.9)
        #expect(try stack(.spreads, pages, out: [2, 3, 4]).medianLayout.leftCrop.minY == 0.1)
    }

    @Test("Apply to the stack and Apply to flagged leave the crops of pages left out as they were")
    @MainActor
    func applyLeavesOutPagesAlone() throws {
        let model = testModel()
        model.pages = book()
        let before = model.pages
        model.setStackPage(before[1].id, included: false, in: .left)
        model.setStackPage(before[2].id, included: false, in: .left)
        let left = try #require(model.stacks.first { $0.id == .left })
        let box = CropRect(x: 0.1, y: 0.2, width: 0.25, height: 0.6)
        model.applyStackCrop(box, to: left.members, in: left)
        for i in [1, 2] { #expect(model.pages[i] == before[i], "page \(i) was changed") }
        for i in [0, 3, 4] { #expect(model.pages[i].leftCrop != before[i].leftCrop, "page \(i) was not changed") }
        // A page that is out is not flagged either, so Apply to flagged never reaches it.
        model.pages = book()
        let flagged = try #require(model.stacks.first { $0.id == .left })
        #expect(flagged.outliers.map { $0.page.sourceIndex } == [2])
        model.setStackPage(model.pages[2].id, included: false, in: .left)
        let after = try #require(model.stacks.first { $0.id == .left })
        let kept = model.pages
        model.applyStackCrop(box, to: after.outliers, in: after)
        #expect(model.pages == kept)
        // The same page is still in the Right pages stack.
        #expect(model.stacks.first { $0.id == .right }?.members.count == 5)
    }

    @Test("Apply to spreads skips a spread left out")
    @MainActor
    func applyLayoutSkips() throws {
        let model = testModel()
        model.pages = book()
        let before = model.pages
        model.setStackPage(before[3].id, included: false, in: .spreads)
        let spreads = try #require(model.stacks.first { $0.id == .spreads })
        model.applySpreadLayout(SpreadLayout(splitX: 0.45, leftCrop: CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.8),
                                             rightCrop: CropRect(x: 0.5, y: 0.1, width: 0.3, height: 0.8)),
                                to: spreads.members)
        #expect(model.pages[3] == before[3])
        #expect(model.pages[0].splitX == 0.45)
    }

    @Test("All puts every page back and None takes every page out, in that stack only")
    @MainActor
    func allAndNone() throws {
        let model = testModel()
        model.pages = book()
        model.setStackPage(model.pages[0].id, included: false, in: .right)
        let left = try #require(model.stacks.first { $0.id == .left })
        model.setAllStackPages(included: false, in: left)
        #expect(model.stacks.first { $0.id == .left }?.members.isEmpty == true)
        #expect(model.stacks.first { $0.id == .left }?.excludedMembers.count == 5)
        #expect(model.stacks.first { $0.id == .right }?.members.count == 4)    // not touched
        let emptied = try #require(model.stacks.first { $0.id == .left })
        model.setAllStackPages(included: true, in: emptied)
        #expect(model.stacks.first { $0.id == .left }?.members.count == 5)
        #expect(model.stackExclusions[.left] == nil)
        // One page back in.
        model.setStackPage(model.pages[0].id, included: true, in: .right)
        #expect(model.stacks.first { $0.id == .right }?.members.count == 5)
    }

    @Test("A page left out of a stack is not flagged on the rail either")
    @MainActor
    func railFlags() throws {
        let model = testModel()
        model.pages = book()
        #expect(model.flaggedSides[model.pages[2].id] == [.left])
        model.setStackPage(model.pages[2].id, included: false, in: .left)
        #expect(model.flaggedSides[model.pages[2].id] == nil)
    }

    @Test("The blend draws only the pages in the stack")
    func blendIgnoresLeftOut() throws {
        let media = CGRect(x: 0, y: 0, width: 240, height: 240)
        let url = Fixtures.writePDF("stackpick-\(UUID().uuidString).pdf", media: media, pages: (0..<4).map { i in
            { c in
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(media)
                c.setFillColor(CGColor(gray: 0, alpha: 1))
                if i == 0 { c.fill(CGRect(x: 72, y: 48, width: 24, height: 24)) }   // only page 0 has it
                c.fill(CGRect(x: 24, y: 168, width: 24, height: 24))
            }
        })
        let doc = try #require(PDFDocument(url: url))
        let pages = (0..<4).map { BookPage(sourceIndex: $0) }
        let plain = try #require(PageStack.groups(pages: pages).first)
        let withAll = try #require(StackRenderer.render(plain, from: doc))
        let mark = try #require(GrayBuffer(cgImage: withAll))
        #expect(abs(Int(mark.value(35, 75)) - 128) < 12)                     // one page in four
        let stack = try #require(PageStack.groups(pages: pages, excluded: [.left: [pages[0].id]]).first)
        let image = try #require(StackRenderer.render(stack, from: doc))
        let gray = try #require(GrayBuffer(cgImage: image))
        #expect(gray.value(35, 75) > 245)                                    // page 0 is gone
        #expect(gray.value(15, 25) < 20)                                     // the shared mark stays
    }

    @Test("Pages left out are saved with the edits and come back when the PDF is opened again")
    @MainActor
    func roundTrip() async throws {
        let model = testModel()
        let url = Fixtures.sampleBook()
        model.load(url: url); await waitUntilIdle(model)
        let spreads = model.pages.filter { $0.classification == .spread }
        try #require(spreads.count >= 3)
        model.setStackPage(spreads[0].id, included: false, in: .left)
        model.setStackPage(spreads[1].id, included: false, in: .spreads)
        let expected = model.stackExclusions
        #expect(expected.count == 2)
        model.load(url: Fixtures.sampleBook()); await waitUntilIdle(model)     // saves this book, opens another
        #expect(model.stackExclusions.isEmpty)
        model.load(url: url); await waitUntilIdle(model)
        #expect(model.stackExclusions == expected)
        #expect(model.stacks.first { $0.id == .left }?.excludedMembers.map(\.id) == [spreads[0].id])
    }

    @Test("A save made before this setting existed opens with nothing left out")
    func olderSave() throws {
        _ = Fixtures.directory
        let pages = book()
        let key = "older-\(UUID().uuidString)"
        try ProjectStore.save(ProjectStore.Saved(pages: pages, direction: .leftToRight), key: key)
        let file = ProjectStore.directory!.appendingPathComponent("\(key).json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("stackExcluded"))                             // as an older build wrote it
        let loaded = try #require(ProjectStore.load(key: key))
        #expect(loaded.stackExcluded == nil)
        // Present: it reads back as written.
        try ProjectStore.save(ProjectStore.Saved(pages: pages, direction: .leftToRight,
                                                 stackExcluded: ["left": [pages[0].id]]), key: key)
        #expect(ProjectStore.load(key: key)?.stackExcluded == ["left": [pages[0].id]])
        // A kind this build doesn't know is dropped, not an error.
        #expect(ProjectStore.exclusions(from: ["left": [pages[0].id], "someday": [pages[1].id]]) == [.left: [pages[0].id]])
        #expect(ProjectStore.exclusions(from: nil).isEmpty)
        #expect(ProjectStore.stored(exclusions: [.right: []]) == nil)       // nothing left out: field absent
    }
}
