import Foundation
import CoreGraphics

/// The 26 pages of the test set. A page takes more text than fits; the typesetter
/// stops at the foot and the truth is what it drew.
enum HCPages {

    private static let single = CGSize(width: 432, height: 648)    // 6 x 9 in
    private static let wide = CGSize(width: 540, height: 720)      // 7.5 x 10 in

    static func all() -> [HCPageSpec] {
        var specs: [HCPageSpec] = []
        let en = HCCorpus.english, quoted = HCCorpus.quoted, styled = HCCorpus.styled
        let gm = HCCorpus.greekMixed, gp = HCCorpus.greekProse

        func eng(_ start: Int, _ count: Int) -> [String] { (0..<count).map { en[(start + $0) % en.count] } }
        func paras(_ texts: [String], size: CGFloat = 11.5, leading: CGFloat = 14.5, notes: Int = 0,
                   locales: [String] = []) -> [HCPara] {
            texts.enumerated().map { k, t in
                // A note's number follows the end of an early paragraph.
                var para = HCPara(markup: k < notes ? t + ["¹", "²", "³"][k] : t, size: size, leading: leading)
                if k < locales.count { para.locale = locales[k] }
                return para
            }
        }
        func add(_ kind: String, family: String, size: CGSize = single, columns: Int = 1,
                 margins: (CGFloat, CGFloat, CGFloat, CGFloat) = (52, 52, 62, 66),
                 body: [HCPara], head: String? = nil, folio: Int? = nil, notes: [String] = []) {
            var spec = HCPageSpec(number: specs.count + 1, kind: kind, family: family, size: size,
                                  columns: columns, body: body, head: head,
                                  folio: folio.map(String.init), footnotes: notes)
            spec.margins = (margins.0, margins.1, margins.2, margins.3)
            specs.append(spec)
        }
        func twoColumn(_ kind: String, family: String, _ texts: [String]) {
            add(kind, family: family, size: wide, columns: 2, margins: (46, 46, 56, 60),
                body: paras(texts, size: 10, leading: 12.5))
        }
        let fn = HCCorpus.footnotes, heads = HCCorpus.heads

        // 1-5: one column, justified, hyphenated.
        add("prose", family: "times", body: paras(eng(0, 6)))
        add("prose", family: "times", body: paras(eng(5, 6)))
        add("prose", family: "times", body: paras(eng(10, 6)))
        add("prose", family: "palatino", body: paras(eng(3, 6), size: 11, leading: 14.5))
        add("prose", family: "palatino", body: paras([quoted[0], quoted[1]] + eng(14, 4), size: 11, leading: 14.5))

        // 6-9: two columns.
        twoColumn("twocol", family: "times", eng(1, 9))
        twoColumn("twocol", family: "times", eng(7, 9))
        twoColumn("twocol", family: "palatino", eng(13, 9))
        twoColumn("twocol", family: "palatino", [quoted[2], quoted[3], quoted[4]] + eng(2, 6))

        // 10-14: running head, footnotes in smaller type, folio.
        add("notes", family: "times", body: paras(eng(4, 5), notes: 3), head: "<sc>\(heads[0])</sc>", folio: 41,
            notes: [fn[0], fn[1], fn[2]])
        add("notes", family: "times", body: paras(eng(9, 5), notes: 2), head: "<i>\(heads[1])</i>", folio: 42,
            notes: [fn[3], fn[4]])
        add("notes", family: "times", body: paras(eng(12, 5), notes: 3), head: "<sc>\(heads[2])</sc>", folio: 117,
            notes: [fn[5], fn[6], fn[7]])
        add("notes", family: "palatino", body: paras(eng(16, 5), size: 11, leading: 14.5, notes: 2),
            head: "<i>\(heads[3])</i>", folio: 58, notes: [fn[8], fn[9]])
        add("notes", family: "palatino", body: paras(eng(2, 5), size: 11, leading: 14.5, notes: 3),
            head: "<sc>\(heads[4])</sc>", folio: 59, notes: [fn[1], fn[3], fn[6]])

        // 15-17: italic and small caps.
        add("styled", family: "times", body: paras(Array(styled[0...4]) + [en[6]]))
        add("styled", family: "palatino", body: paras(Array(styled[3...6]) + eng(8, 2), size: 11, leading: 14.5))
        add("styled", family: "times", body: paras([styled[5], styled[0], styled[2], styled[6], styled[1]]))

        // 18-21: English with polytonic Greek.
        add("greekmixed", family: "times", body: paras(Array(gm[0...4]), leading: 16, notes: 3),
            head: "<sc>\(heads[1])</sc>", folio: 23, notes: [fn[8], fn[4], fn[0]])
        add("greekmixed", family: "times", body: paras(Array(gm[3...7]), leading: 16, notes: 2),
            head: "<i>\(heads[1])</i>", folio: 24, notes: [fn[5], fn[9]])
        add("greekmixed", family: "palatino", body: paras([gm[2], gm[6], gm[1], gm[5], gm[0]], size: 11, leading: 16))
        add("greekmixed", family: "times", size: wide, columns: 2, margins: (46, 46, 56, 60),
            body: paras([gm[4], gm[7], gm[3], gm[1], gm[5], gm[2], gm[0]], size: 10, leading: 14))

        // 22-24: polytonic Greek throughout.
        var verse: [HCPara] = []
        let heading = { (t: String, before: CGFloat) in
            HCPara(markup: "<g>\(t)</g>", size: 12, leading: 17, justify: false, hyphenate: false,
                   indent: 0, center: true, before: before)
        }
        verse.append(heading("ΙΛΙΑΔΟΣ Α", 0))
        for line in HCCorpus.greekVerse[0] {
            verse.append(HCPara(markup: "<g>\(line)</g>", size: 12, leading: 17, justify: false, hyphenate: false, indent: 0))
        }
        verse.append(heading("ΟΔΥΣΣΕΙΑΣ Α", 14))
        for line in HCCorpus.greekVerse[1] {
            verse.append(HCPara(markup: "<g>\(line)</g>", size: 12, leading: 17, justify: false, hyphenate: false, indent: 0))
        }
        add("greekfull", family: "times", margins: (58, 40, 62, 66), body: verse)
        func prose(_ ix: [Int]) -> [HCPara] {
            ix.map { HCPara(markup: "<g>\(gp[$0])</g>", size: 12, leading: 17.5, hyphenate: false, before: 4) }
        }
        add("greekfull", family: "palatino", body: prose([0, 1, 2, 3, 7, 8, 0]))
        add("greekfull", family: "times", body: prose([4, 5, 6, 8, 7, 2, 1]))

        // 25-26: Latin and German beside English.
        let la = HCCorpus.latin, ge = HCCorpus.german
        add("latgerm", family: "times",
            body: paras([en[3], la[0], la[1], ge[0], en[6], la[2], ge[2]],
                        locales: ["en", "la", "la", "de", "en", "la", "de"]))
        add("latgerm", family: "palatino",
            body: paras([ge[2], la[1], en[11], ge[1], la[2], en[7], ge[0]], size: 11, leading: 14.5, notes: 2,
                        locales: ["de", "la", "en", "de", "la", "en", "de"]),
            head: "<sc>\(heads[2])</sc>", folio: 88, notes: [fn[7], fn[2]])
        return specs
    }

    /// Fixed scan look for page `n`: tilt of up to 0.8 degrees either way, a gutter
    /// shadow on every third page.
    static func look(_ n: Int) -> HCScanLook {
        var r = HCRandom(seed: UInt64(n) &* 7919)
        let tilt = (0.25 + 0.55 * r.unit()) * (n % 2 == 0 ? 1 : -1)
        var look = HCScanLook(angle: tilt, seed: UInt64(n) &* 104_729)
        if n % 3 == 0 {
            look.shadowSide = (n / 3) % 2 == 0 ? 1 : -1
            look.shadowStrength = 0.35 + 0.2 * r.unit()
        }
        look.paperPhase = r.unit() * .pi
        return look
    }
}
