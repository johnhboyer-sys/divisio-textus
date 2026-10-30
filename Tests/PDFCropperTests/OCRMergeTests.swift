import Testing
import Foundation
import CoreGraphics
@testable import PDFCropper

/// The two OCR passes (full and half size) are merged line by line. Boxes are
/// Vision-style: normalized, bottom-left origin.
@Suite("OCR two-pass merge")
struct OCRMergeTests {

    /// Tightly set lines whose boxes are taller than the gap between them (as on
    /// Wallace's pages): boxes overlap, which once made lines appear twice.
    private func tightLines(_ texts: [String], dy: Double = 0) -> [OCRService.Line] {
        texts.enumerated().map { i, t in
            OCRService.Line(text: t, box: CGRect(x: 0.2, y: 0.70 - Double(i) * 0.023 + dy, width: 0.77, height: 0.034))
        }
    }

    @Test("Overlapping line boxes never duplicate a line")
    func noDuplicates() {
        let texts = (1...12).map { "line number \($0) of the page" }
        let merged = OCRService.merge(tightLines(texts), tightLines(texts, dy: 0.001))
        #expect(merged.map(\.text).sorted() == texts.sorted())
    }

    @Test("A line Vision garbled from two rows is replaced by the two rows")
    func garbledMerge() {
        let pass1 = [OCRService.Line(text: "garbled two rows", box: CGRect(x: 0.2, y: 0.60, width: 0.77, height: 0.06))]
        let pass2 = [OCRService.Line(text: "upper row", box: CGRect(x: 0.2, y: 0.632, width: 0.77, height: 0.025)),
                     OCRService.Line(text: "lower row", box: CGRect(x: 0.2, y: 0.602, width: 0.77, height: 0.025))]
        #expect(OCRService.merge(pass1, pass2).map(\.text).sorted() == ["lower row", "upper row"])
    }

    @Test("A line the first pass dropped is recovered from the second")
    func droppedLine() {
        let pass1 = tightLines(["first", "second"])
        let pass2 = tightLines(["first", "second"]) + [OCRService.Line(text: "dropped", box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.03))]
        #expect(OCRService.merge(pass1, pass2).map(\.text).sorted() == ["dropped", "first", "second"])
    }

    // MARK: - Ghost lines

    /// A line from Vision's word boxes in pixels (top-left origin) on a 1101 × 1668 page.
    private func px(_ words: [(String, Double, Double, Double, Double)]) -> OCRService.Line {
        let ws = words.map { OCRService.Word(text: $0.0, box: CGRect(x: $0.1 / 1101, y: 1 - $0.4 / 1668,
                                                                      width: ($0.2 - $0.1) / 1101, height: ($0.4 - $0.3) / 1668)) }
        return OCRService.Line(text: ws.map(\.text).joined(separator: " "), box: ws.map(\.box).reduce(.null) { $0.union($1) }, words: ws)
    }

    /// A line whose words share its box out evenly, from x0 to x1 (pixels).
    private func even(_ text: String, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> OCRService.Line {
        let parts = text.split(separator: " ").map(String.init), w = (x1 - x0) / Double(parts.count)
        return px(parts.enumerated().map { ($1, x0 + Double($0) * w + 2, x0 + Double($0 + 1) * w - 2, y0, y1) })
    }

    // Wallace 1957, export page 30, as Vision read it at full and half size.
    private var page30: (real: [OCRService.Line], ghost: OCRService.Line, half: [OCRService.Line]) {
        let real = [
            px([("about", 167, 231, 1336, 1363), ("animals", 234, 322, 1336, 1363), ("that", 325, 376, 1336, 1363),
                ("not", 379, 420, 1336, 1363), ("even", 423, 477, 1336, 1363), ("expert", 480, 555, 1336, 1363),
                ("zoologists", 558, 663, 1336, 1363), ("pretend", 666, 754, 1336, 1363), ("to", 757, 787, 1336, 1363),
                ("have", 791, 845, 1336, 1363), ("attained.", 848, 953, 1336, 1363), ("Most", 956, 1014, 1336, 1363)]),
            px([("of", 172, 198, 1356, 1379), ("modern", 200, 290, 1356, 1379), ("science", 292, 379, 1356, 1380),
                ("is", 381, 410, 1357, 1380), ("far", 413, 453, 1357, 1380), ("removed", 456, 557, 1357, 1381),
                ("from", 559, 623, 1358, 1381), ("the", 626, 672, 1358, 1381), ("very", 674, 732, 1358, 1382),
                ("abstract", 735, 830, 1359, 1382), ("consideration", 832, 982, 1359, 1383), ("of", 985, 1014, 1360, 1384)]),
            px([("changeable", 167, 285, 1384, 1411), ("being", 288, 352, 1384, 1411), ("in", 356, 383, 1384, 1411),
                ("general,", 386, 474, 1384, 1411), ("but", 477, 521, 1384, 1411), ("for", 524, 561, 1384, 1411),
                ("the", 565, 605, 1384, 1411), ("most", 609, 666, 1384, 1411), ("part", 669, 720, 1384, 1411),
                ("it", 723, 747, 1384, 1411), ("still", 750, 797, 1384, 1411), ("has", 801, 841, 1384, 1411),
                ("not", 845, 888, 1384, 1411), ("attained", 892, 983, 1384, 1411), ("to", 986, 1011, 1384, 1411)])]
        let ghost = px([("1", 457, 466, 1341, 1418), ("Du", 476, 514, 1341, 1418), ("to", 524, 553, 1341, 1418),
                        ("the", 562, 616, 1341, 1418)])
        let half = [even(real[0].text, 168, 1013, 1331, 1362), even(real[1].text, 168, 1017, 1356, 1386),
                    even(real[2].text, 168, 1013, 1384, 1412)]
        return (real, ghost, half)
    }

    @Test("A line the first pass made up over three real lines is dropped")
    func ghostOverLines() {
        // Nothing is printed there.
        let (real, ghost, half) = page30
        #expect(OCRService.withoutGhosts(real + [ghost], half, isWord: isWord).map(\.text) == real.map(\.text))
    }

    @Test("A partial copy of a line, misread, is dropped")
    func partialCopy() {
        // Wallace 1957, export page 19: the first pass read a table row whole, and
        // again in part. The half-size pass read the row in pieces, "that" nearer the copy.
        let copy = px([("is", 418, 431, 981, 1005), ("A", 455, 471, 981, 1005), ("dav", 495, 530, 981, 1005),
                       ("that", 555, 595, 981, 1005)])
        let row = px([("is", 418, 431, 988, 1014), ("A", 455, 471, 988, 1013), ("day", 495, 530, 988, 1014),
                      ("that", 555, 595, 989, 1014), ("occurs", 620, 681, 989, 1015), ("is", 705, 719, 990, 1015),
                      ("longer", 743, 806, 990, 1016), ("and", 831, 867, 991, 1016), ("warmer", 892, 968, 991, 1018)])
        let half = [even("is A day", 418, 530, 986, 1013), even("that", 555, 595, 982, 1004)]
        #expect(OCRService.withoutGhosts([copy, row], half, isWord: isWord).map(\.text) == [row.text])
    }

    @Test("Real lines stay, even where boxes overlap or the second pass missed them")
    func realLinesKept() {
        // Tight print: the middle line, missed by the second pass, overlaps both neighbours.
        let tight = [even("the first line of the page", 100, 900, 500, 534),
                     even("the second line of the page", 100, 900, 523, 557),
                     even("the third line of the page", 100, 900, 546, 580)]
        #expect(OCRService.withoutGhosts(tight, [tight[0], tight[2]], isWord: isWord).count == 3)
        // A drop cap's line, boxed two lines tall, over the line below it, which
        // the second pass read; the first line it missed.
        let (real, _, half) = page30
        let tall = even("AT PRESENT it is generally agreed", 167, 900, 1300, 1363)
        #expect(OCRService.withoutGhosts([tall] + real, half, isWord: isWord).count == 4)
        // A short real line just below a longer one, overlapping it, sharing its word.
        let long = even("this is longer", 100, 700, 500, 540), short = even("is", 300, 340, 530, 555)
        #expect(OCRService.withoutGhosts([long, short], [long], isWord: isWord).count == 2)
        // Two lines on one spot with different words: both stay.
        let a = even("the first line", 100, 600, 500, 530), b = even("a second one", 102, 598, 502, 531)
        #expect(OCRService.withoutGhosts([a, b], [], isWord: isWord).count == 2)
    }

    @Test("Of two copies of a line exactly one stays, and no words are lost")
    func copiesKeepOne() {
        let first = even("the same line", 100, 600, 500, 530), second = even("the same line", 100, 600, 502, 531)
        #expect(OCRService.withoutGhosts([first, second], [], isWord: isWord).count == 1)
        // The second pass confirms only the second copy.
        #expect(OCRService.withoutGhosts([first, second], [second], isWord: isWord).map(\.box) == [second.box])
        // A copy of a line that isn't itself a copy: only the copy goes.
        let b = px([("red", 100, 200, 500, 530), ("cat", 210, 300, 500, 530), ("dog", 310, 400, 500, 530), ("fish", 410, 500, 500, 530)])
        let c = px([("dog", 100, 180, 500, 530), ("fish", 190, 260, 500, 530), ("blue", 270, 340, 500, 530),
                    ("green", 350, 420, 500, 530), ("gold", 430, 500, 500, 530)])
        let a = px([("red", 100, 200, 500, 530), ("cat", 210, 300, 500, 530)])
        #expect(OCRService.withoutGhosts([a, b, c], [], isWord: isWord).map(\.text) == [b.text, c.text])
        // Two readings of one spot that differ in a real word: no telling which
        // is right, so both stay.
        let cat = px([("red", 100, 200, 500, 530), ("cat", 210, 300, 500, 530)])
        let dog = px([("red", 100, 200, 503, 533), ("dog", 210, 300, 503, 533)])
        #expect(OCRService.withoutGhosts([cat, dog], [cat, dog], isWord: isWord).count == 2)
        // Word boxes may reach past their line's box: two copies whose line boxes
        // don't meet still lie on each other.
        let word = OCRService.Word(text: "word", box: CGRect(x: 0.2, y: 0.516, width: 0.1, height: 0.01))
        let upper = OCRService.Line(text: "word", box: CGRect(x: 0.2, y: 0.525, width: 0.1, height: 0.02), words: [word])
        let lower = OCRService.Line(text: "word", box: CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02), words: [word])
        #expect(OCRService.withoutGhosts([upper, lower], [], isWord: isWord).count == 1)
    }

    // MARK: - Word vote

    private func row(_ text: String) -> [OCRService.Line] {
        [OCRService.Line(text: text, box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.02))]
    }
    private let misspelled: Set<String> = ["dav", "carth", "cxrth", "specity", "ScriptureiLet", "quâ", "tz", "elec"]
    private func isWord(_ s: String) -> Bool {
        !misspelled.contains(s.trimmingCharacters(in: .punctuationCharacters.union(.symbols)))
    }

    @Test("A word the first pass misread takes the second pass's spelling")
    func misreadReplaced() {
        // Cherniss 1935, Wallace 1957 and Oesterle 1955, read by both passes.
        let cases = [("according to some the carth", "according to some the earth"),
                     ("In order to specity this notation", "In order to specify this notation"),
                     ("when it is said in ScriptureiLet us make man", "when it is said in Scripture \"Let us make man")]
        for (first, second) in cases {
            #expect(OCRService.correct(row(first), with: row(second), isWord: isWord).map(\.text) == [second])
        }
    }

    @Test("Accents, short marks, and words both passes misread stay as first read")
    func votesKept() {
        let cases = [("So the whole sky, quâ", "So the whole sky, qua"),     // printed quâ
                     ("tz in the plane", "t in the plane"),                  // printed t₂
                     ("the carth moves", "the cxrth moves"),                 // second pass no better
                     ("the earth moves", "the carth moves"),                 // first pass already right
                     ("Static elec-", "Static elect"),                       // broken at the line's end
                     ("\"carth\" 1957", "earth 1935")]                     // numbers differ
        for (first, second) in cases {
            #expect(OCRService.correct(row(first), with: row(second), isWord: isWord).map(\.text) == [first], "\(first)")
        }
    }

    private let notEnglish: Set<String> = ["Credk", "Gredt", "Philosophiac", "Philosophiae", "Aristotelico-Thomistica",
                                           "Aristotelico-Thomisticae", "Freihung", "Ject", "lect", "Iect",
                                           "physico-mathematically", "physico-mathematically,°s"]
    private func isEnglish(_ s: String) -> Bool {
        isWord(s) && !notEnglish.contains(s.trimmingCharacters(in: .punctuationCharacters.union(.symbols)))
    }

    @Test("Where the passes disagree on words not in English, a third reading decides")
    func thirdReadDecides() {
        // Wallace 1957 footnotes: full size, half size, three-quarter size.
        let cases = [("• J. Credk, O.S. B., Elementa Philosophiac Aristotelico-Thomistica (Freihung:",
                      "• J. Gredt, O.S. B., Elementa Philosophiae Aristotelico-Thomisticae (Freiburg:",
                      "* J. Gredt, O.S. B., Elementa Philosophiae Aristotelico-Thomisticae (Freiburg:",
                      "• J. Gredt, O.S. B., Elementa Philosophiae Aristotelico-Thomisticae (Freiburg:"),
                     ("' II Post. Anal., Ject. 9.", "1 II Post. Anal., lect. 9.", "'II Post. Anal., lect. 9.",
                      "' II Post. Anal., lect. 9."),
                     ("* I Post. Anal., Ject. 23, n. 7.", "* 1 Post. Anal., lect. 23, n. 7.", "* I Post. Anal., lect. 23, n. 7.",
                      "* I Post. Anal., lect. 23, n. 7."),
                     ("carth * Ject.", "earth * lect.", "earth * lect.", "earth * lect.")]       // after a word put right
        for (first, second, third, read) in cases {
            #expect(OCRService.correct(row(first), with: row(second), tieBreak: { row(third) }, isWord: isEnglish).map(\.text)
                    == [read], "\(first)")
        }
    }

    @Test("A third reading that agrees with the first, or with neither, changes nothing")
    func thirdReadKeeps() {
        let cases = [("Elementa Philosophiae", "Elementa Philosophiac", "Elementa Philosophiae"),   // first already right
                     ("Anal., Ject. 9.", "Anal., lect. 9.", "Anal., Iect. 9."),                   // no two agree
                     ("Anal., Ject. 9.", "Anal., lect. 9.", ""),                                  // no third line
                     ("the earth moves", "the Credk moves", "the Credk moves"),                   // first spelled right
                     ("lect. 4, Ject. 9.", "lect. 4, lect. 9.", "lect. 4, Iect. 9."),              // agrees elsewhere only
                     ("quia physico-mathematically, the", "quia physico-mathematically,°s the",    // printed ",⁹⁵"
                      "quia physico-mathematically,°s the"),
                     ("Gredt et Credk et", "Credk et Credk et", "Iect et Credk et"),             // agrees at the end only
                     ("et Credk et Gredt", "et Credk et Credk", "et Credk et Iect"),             // agrees at the start only
                     ("* Gredt et Credk et", "* Credk et Credk et", "* Iect et Credk et"),       // a mark before it
                     ("Anal., Ject. 9.", "Anal., lect.", "Anal., lect.")]                         // a number lost
        for (first, second, third) in cases {
            let tie = third.isEmpty ? [] : row(third)
            #expect(OCRService.correct(row(first), with: row(second), tieBreak: { tie }, isWord: isEnglish).map(\.text)
                    == [first], "\(first)")
        }
    }

    @Test("A line read two rows tall is voted on by its own row only")
    func tallLineOwnRow() {
        // Wallace 1957 p6: the first pass read "1952)." into the line below it, in a
        // box two rows tall; the other passes read "1952)." apart, nearer the line above.
        func line(_ text: String, _ y0: Double, _ y1: Double, _ x0: Double = 0.182, _ x1: Double = 0.92) -> OCRService.Line {
            OCRService.Line(text: text, box: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        let above = "Company, 1933); K. Dougherty, S. A., Cosmology (Peekskill: Graymoor Press,"
        let words: [(String, Double, Double, Double, Double)] = [
            ("1953,", 0.179, 0.231, 0.315, 0.345), ("Credk,", 0.235, 0.302, 0.314, 0.344), ("O.S.", 0.305, 0.347, 0.313, 0.343),
            ("B.,", 0.351, 0.377, 0.312, 0.342), ("Elementa", 0.381, 0.463, 0.310, 0.341), ("Philosophiac", 0.467, 0.585, 0.308, 0.340),
            ("Aristotelico-Thomistica", 0.589, 0.813, 0.304, 0.337), ("(Freihung:", 0.816, 0.920, 0.302, 0.333)]
        let tall = OCRService.Line(text: words.map(\.0).joined(separator: " "),
                                   box: CGRect(x: 0.179, y: 0.302, width: 0.741, height: 0.043),
                                   words: words.map { OCRService.Word(text: $0.0, box: CGRect(x: $0.1, y: $0.3, width: $0.2 - $0.1, height: $0.4 - $0.3)) })
        let first = [line(above, 0.342, 0.361), tall]
        let second = [line(above, 0.343, 0.362), line("1952）.", 0.331, 0.345, 0.182, 0.245),
                      line("• J. Gredt, O.S. B., Elementa Philosophiae Aristotelico-Thomisticae (Freiburg:", 0.317, 0.331, 0.199, 0.916)]
        let third = [line(above, 0.343, 0.361), line("1952) .", 0.331, 0.345, 0.179, 0.242),
                     line("* J. Gredt, O.S. B., Elementa Philosophiae Aristotelico-Thomisticae (Freiburg:", 0.312, 0.331, 0.198, 0.919)]
        #expect(OCRService.correct(first, with: second, tieBreak: { third }, isWord: isEnglish).map(\.text)
                == [above, second[2].text])
    }

    @Test("A number stays unless its word lies on a line of another row")
    func tallLineKeepsNumber() {
        let first = [OCRService.Line(text: "Anal., Ject. 9.", box: CGRect(x: 0.1, y: 0.49, width: 0.8, height: 0.04))]
        #expect(OCRService.correct(first, with: row("Anal., lect."), tieBreak: { row("Anal., lect.") }, isWord: isEnglish)
                .map(\.text) == ["Anal., Ject. 9."])
        // Tightly set: the next row's line overlaps this box, but lies mostly outside it.
        func line(_ text: String, _ y: Double, _ h: Double) -> OCRService.Line {
            OCRService.Line(text: text, box: CGRect(x: 0.1, y: y, width: 0.8, height: h))
        }
        let tight = [line("Anal., Ject. 9.", 0.500, 0.020), line("other row", 0.512, 0.020)]
        let later = [line("Anal., lect.", 0.500, 0.012), line("other row", 0.512, 0.012)]
        #expect(OCRService.correct(tight, with: later, tieBreak: { later }, isWord: isEnglish).map(\.text)
                == ["Anal., Ject. 9.", "other row"])
        // A drop cap makes the box take in the next row, but "9." lies on its own row.
        func word(_ text: String, _ x0: Double, _ x1: Double) -> OCRService.Word {
            OCRService.Word(text: text, box: CGRect(x: x0, y: 0.50, width: x1 - x0, height: 0.02))
        }
        let capped = OCRService.Line(text: "Anal., Ject. 9.", box: CGRect(x: 0.1, y: 0.46, width: 0.8, height: 0.06),
                                     words: [word("Anal.,", 0.1, 0.3), word("Ject.", 0.32, 0.5), word("9.", 0.52, 0.6)])
        let below = [line("Anal., lect.", 0.500, 0.020), line("next row", 0.470, 0.020)]
        #expect(OCRService.correct([capped, line("next row", 0.470, 0.020)], with: below, tieBreak: { below }, isWord: isEnglish)
                .map(\.text) == ["Anal., Ject. 9.", "next row"])
    }

    @Test("The third reading runs only where a vote is in doubt")
    func thirdReadOnlyWhenNeeded() {
        var asked = 0
        _ = OCRService.correct(row("according to some the carth"), with: row("according to some the earth"),
                               tieBreak: { asked += 1; return [] }, isWord: isWord)
        _ = OCRService.correct(row("Anal., Ject. 9."), with: row("Anal., lect. 9."), tieBreak: { asked += 10; return [] },
                               isWord: isEnglish)
        // Read once for the page, however many lines are in doubt.
        let lower = OCRService.Line(text: "Anal., Ject. 9.", box: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.02))
        let lowerAgain = OCRService.Line(text: "Anal., lect. 9.", box: lower.box)
        _ = OCRService.correct(row("Anal., Ject. 9.") + [lower], with: row("Anal., lect. 9.") + [lowerAgain],
                               tieBreak: { asked += 100; return [] }, isWord: isEnglish)
        #expect(asked == 110)
    }

    @Test("Only the line on the same row votes")
    func otherRowIgnored() {
        let below = [OCRService.Line(text: "according to some the earth", box: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.02))]
        #expect(OCRService.correct(row("according to some the carth"), with: below, isWord: isWord).map(\.text)
                == ["according to some the carth"])
    }

    @Test("A second-pass line votes only on its nearest row")
    func nearestRowVotes() {
        // A tall first-pass box whose row reaches the next line's.
        let tall = OCRService.Line(text: "the carth", box: CGRect(x: 0.1, y: 0.49, width: 0.8, height: 0.04))
        let next = OCRService.Line(text: "the carth", box: CGRect(x: 0.1, y: 0.485, width: 0.8, height: 0.02))
        let second = [OCRService.Line(text: "the earth", box: CGRect(x: 0.1, y: 0.487, width: 0.8, height: 0.02))]
        #expect(OCRService.correct([tall, next], with: second, isWord: isWord).map(\.text) == ["the carth", "the earth"])
    }

    @Test("The spell checker flags misreads, not numbers")
    func spelling() {
        #expect(!OCRService.spelledRight("specity", languages: ["en-US"]))
        #expect(!OCRService.spelledRight("dav", languages: ["en-US"]))
        #expect(!OCRService.spelledRight("Gredt,", languages: ["en-US"]))
        #expect(!OCRService.spelledRight("lect.", languages: ["en-US"]))
        #expect(OCRService.spelledRight("specify,", languages: ["en-US"]))
        #expect(OCRService.spelledRight("1957", languages: ["en-US"]))
    }

    @Test("A word boxed inside the word before it drops the line's word boxes")
    func wordInsideWord() throws {
        let row = CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.02)
        func line(_ boxes: [ClosedRange<Double>]) -> OCRService.Line? {
            let text = "first second", starts = [text.startIndex, text.index(text.startIndex, offsetBy: 6)]
            return OCRService.makeLine(text, box: row) { r in
                let k = starts.firstIndex(of: r.lowerBound)!
                return CGRect(x: boxes[k].lowerBound, y: 0.5, width: boxes[k].upperBound - boxes[k].lowerBound, height: 0.02)
            }
        }
        #expect(line([0.10...0.20, 0.22...0.40])?.words.count == 2)
        #expect(line([0.10...0.30, 0.26...0.28])?.words.isEmpty == true)
    }
}
