import XCTest
@testable import TypoFreeCore

// M1 — FlypyScheme + ShuangpinDecoder (tasks.md §M1, DESIGN.md §2.1,
// EXPLORE.md Appendix A). All test classes are named `Scheme*` so the milestone
// verify command `swift test --filter Scheme` runs the whole suite.
//
// U+00FC ("ü") is written as an explicit scalar escape everywhere so the tests
// pin the exact code point the scheme table must emit (NFC precomposed), not an
// editor-dependent combining sequence.
private let uUmlaut = "\u{FC}"   // ü

// MARK: - Structure of the flypy scheme data

final class SchemeFlypyStructureTests: XCTestCase {
    func testHeaderMatchesTFX1SchemeId() {
        let s = FlypyScheme.flypy
        XCTAssertEqual(s.schemeId, 1, "must match the TFX1 lexicon header's schemeId")
        XCTAssertEqual(s.displayName, "小鹤双拼")
    }

    func testTwentyOneInitialsAllClassified() {
        let s = FlypyScheme.flypy
        XCTAssertEqual(s.keyToInitial.count, 21, "18 literal + zh/ch/sh compressed")
        // Every initial has a class.
        for initial in Set(s.keyToInitial.values) {
            XCTAssertNotNil(s.initialToClass[initial], "initial \(initial) unclassified")
        }
        // The three compressed initials.
        XCTAssertEqual(s.keyToInitial["v"], "zh")
        XCTAssertEqual(s.keyToInitial["i"], "ch")
        XCTAssertEqual(s.keyToInitial["u"], "sh")
    }

    func testZeroInitialTableHasAllThirtyFiveEntries() {
        let s = FlypyScheme.flypy
        XCTAssertEqual(s.zeroDecodeTable.count, 35, "12 真零辅音 + 14 y-glide + 9 w-glide")
        XCTAssertEqual(s.zeroInitialLeadKeys, ["a", "e", "o", "w", "y"])
    }

    func testInitialClassOfKey() {
        let s = FlypyScheme.flypy
        XCTAssertEqual(s.initialClass(ofKey: "b"), .bpmf)
        XCTAssertEqual(s.initialClass(ofKey: "d"), .dt)
        XCTAssertEqual(s.initialClass(ofKey: "n"), .nl)
        XCTAssertEqual(s.initialClass(ofKey: "j"), .jqx)
        XCTAssertEqual(s.initialClass(ofKey: "g"), .gkhzh)
        XCTAssertEqual(s.initialClass(ofKey: "v"), .gkhzh, "v = zh")
        XCTAssertEqual(s.initialClass(ofKey: "i"), .gkhzh, "i = ch")
        XCTAssertEqual(s.initialClass(ofKey: "u"), .gkhzh, "u = sh")
        // Zero-initial lead keys are not real initials.
        for lead in ["a", "e", "o", "w", "y"] {
            XCTAssertNil(s.initialClass(ofKey: Character(lead)))
        }
    }
}

// MARK: - The 8 counter-intuitive zero-initial traps + regular controls

final class SchemeZeroInitialTrapTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    /// wai→wd, wei→ww, wan→wj, wang→wh, yao→yc, you→yz, yang→yh, yong→ys —
    /// both directions must hold.
    func testEightTrapsDecodeAndEncode() {
        let traps: [(code: String, pinyin: String)] = [
            ("wd", "wai"), ("ww", "wei"), ("wj", "wan"), ("wh", "wang"),
            ("yc", "yao"), ("yz", "you"), ("yh", "yang"), ("ys", "yong"),
        ]
        for t in traps {
            XCTAssertEqual(decoder.decodeSyllable(t.code), t.pinyin, "decode \(t.code)")
            XCTAssertEqual(decoder.encode(syllable: t.pinyin), t.code, "encode \(t.pinyin)")
        }
    }

    /// Regular controls that follow the intuitive spelling — guards against a
    /// decoder that "over-corrects" the traps into a blanket rule.
    func testRegularControls() {
        let controls: [(code: String, pinyin: String)] = [
            ("yu", "yu"), ("yr", "yuan"), ("yt", "yue"), ("yy", "yun"),
            ("wu", "wu"), ("aa", "a"), ("er", "er"),
        ]
        for c in controls {
            XCTAssertEqual(decoder.decodeSyllable(c.code), c.pinyin, "decode \(c.code)")
            XCTAssertEqual(decoder.encode(syllable: c.pinyin), c.code, "encode \(c.pinyin)")
        }
    }
}

// MARK: - Overloaded second keys (o/k/l/s/x/v/t) + conditional exceptions

final class SchemeOverloadedKeyTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    /// Each overloaded key means different things per initial class. Real
    /// syllables where rime and Appendix A agree.
    func testOverloadedKeysWithRealSyllables() {
        let cases: [(code: String, pinyin: String)] = [
            ("bo", "bo"),      ("do", "duo"),              // o: literal vs uo
            ("hk", "huai"),    ("bk", "bing"),             // k: uai vs ing
            ("gl", "guang"),   ("jl", "jiang"), ("nl", "niang"), // l: uang vs iang
            ("gs", "gong"),    ("js", "jiong"), ("ds", "dong"),  // s: ong vs iong (dt+s=ong required)
            ("gx", "gua"),     ("jx", "jia"),              // x: ua vs ia
            ("dv", "dui"),     ("lv", "l\(uUmlaut)"),      // v: ui vs ü
            ("jt", "jue"),     ("lt", "l\(uUmlaut)e"),     // t: ue vs üe
        ]
        for c in cases {
            XCTAssertEqual(decoder.decodeSyllable(c.code), c.pinyin, "decode \(c.code)")
            XCTAssertEqual(decoder.encode(syllable: c.pinyin), c.code, "encode \(c.pinyin)")
        }
    }

    /// r = uan for all initials EXCEPT b/p/m/f (no buan/puan/muan/fuan).
    func testRUanExceptBpmf() {
        XCTAssertEqual(decoder.decodeSyllable("gr"), "guan")
        XCTAssertEqual(decoder.decodeSyllable("dr"), "duan")
        XCTAssertEqual(decoder.decodeSyllable("jr"), "juan")
        for illegal in ["br", "pr", "mr", "fr"] {
            XCTAssertNil(decoder.decodeSyllable(illegal), "\(illegal) must be illegal (bpmf take no uan)")
        }
    }

    /// n = iao only for b/p/m/f/d/t/n/l/j/q/x — never for the gkhzh class.
    func testNIaoOnlyForBpmfdtnljqx() {
        XCTAssertEqual(decoder.decodeSyllable("bn"), "biao")
        XCTAssertEqual(decoder.decodeSyllable("jn"), "jiao")
        XCTAssertEqual(decoder.decodeSyllable("nn"), "niao")
        for illegal in ["gn", "kn", "hn", "vn", "zn"] {   // g/k/h/zh/z + n
            XCTAssertNil(decoder.decodeSyllable(illegal), "\(illegal) must be illegal (gkhzh take no iao)")
        }
    }
}

// MARK: - Compressed initials + illegal combinations

final class SchemeDecodeEdgeTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    func testCompressedInitials() {
        XCTAssertEqual(decoder.decodeSyllable("vs"), "zhong")   // zh + ong
        XCTAssertEqual(decoder.decodeSyllable("ii"), "chi")     // ch + i
        XCTAssertEqual(decoder.decodeSyllable("ui"), "shi")     // sh + i
        XCTAssertEqual(decoder.decodeSyllable("ul"), "shuang")  // sh + uang
    }

    func testIllegalCombinationsReturnNil() {
        // Missing final for that class (jo/bv/dt), the deliberately-discarded
        // redundant derive code for ju (jv, D5), and zero codes not in the
        // 35-entry table (ax/wk — wai is wd, not wk).
        for illegal in ["br", "gn", "jv", "jo", "bv", "ft", "dt", "wk", "ax"] {
            XCTAssertNil(decoder.decodeSyllable(illegal), "\(illegal) must decode to nil")
        }
    }

    func testWrongLengthReturnsNil() {
        XCTAssertNil(decoder.decodeSyllable(""))
        XCTAssertNil(decoder.decodeSyllable("a"))
        XCTAssertNil(decoder.decodeSyllable("abc"))
    }
}

// MARK: - decode() chunking into syllables + trailing half-syllable

final class SchemeDecodeChunkingTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    func testEvenLengthChunksIntoCompleteSyllables() {
        let r = decoder.decode("nihc")   // 你好
        XCTAssertEqual(r.codes, ["ni", "hc"])
        XCTAssertEqual(r.syllables.map(\.pinyin), ["ni", "hao"])
        XCTAssertTrue(r.syllables.allSatisfy(\.isComplete))
        XCTAssertNil(r.incompleteTail)
    }

    func testOddLengthLeavesIncompleteTail() {
        let r = decoder.decode("nih")
        XCTAssertEqual(r.codes, ["ni"])
        XCTAssertEqual(r.incompleteTail, "h")
    }

    func testSingleKeyIsAllTail() {
        let r = decoder.decode("n")
        XCTAssertTrue(r.syllables.isEmpty)
        XCTAssertEqual(r.incompleteTail, "n")
    }

    func testEmptyInput() {
        let r = decoder.decode("")
        XCTAssertTrue(r.syllables.isEmpty)
        XCTAssertNil(r.incompleteTail)
    }

    func testIllegalChunkKeptWithNilPinyin() {
        let r = decoder.decode("brgn")   // both chunks illegal
        XCTAssertEqual(r.codes, ["br", "gn"])
        XCTAssertEqual(r.syllables.map(\.pinyin), [nil, nil])
        XCTAssertTrue(r.syllables.allSatisfy(\.isComplete))
        XCTAssertNil(r.incompleteTail)
    }
}

// MARK: - Reverse encode round-trips

final class SchemeEncodeRoundTripTests: XCTestCase {
    private let decoder = ShuangpinDecoder(scheme: FlypyScheme.flypy)

    func testWordRoundTrips() {
        XCTAssertEqual(decoder.encode(tonelessSyllables: ["ni", "hao"]), "nihc")   // 你好
        XCTAssertEqual(decoder.encode(tonelessSyllables: ["shi", "jie"]), "uijp")  // 世界
        XCTAssertEqual(decoder.encode(tonelessSyllables: ["wai"]), "wd")           // trap
        // Decoding the produced codes must recover the syllables.
        XCTAssertEqual(decoder.decode("uijp").syllables.map(\.pinyin), ["shi", "jie"])
    }

    func testWordEncodeFailsOnUnencodableSyllable() {
        XCTAssertNil(decoder.encode(tonelessSyllables: ["ni", "zzz"]))
    }

    /// Exhaustive per-syllable round-trip over a spread covering every class and
    /// every overloaded/conditional final. `decode(encode(s)) == s`.
    func testSyllableRoundTripSpread() throws {
        let syllables = [
            // bpmf
            "ba", "bo", "beng", "ban", "bao", "bin", "bian", "bie", "bai", "ben", "biao", "bing",
            // dt
            "dui", "duo", "dong", "ding", "diao", "duan", "da", "de", "dou",
            // nl
            "niang", "niao", "l\(uUmlaut)", "l\(uUmlaut)e", "ning", "nuan", "luo", "na", "nen",
            // jqx
            "jia", "jiang", "jiong", "jue", "juan", "jing", "jin", "qian", "xie", "ju", "qu", "xu",
            // gkhzh (incl. r/z/c/s + compressed)
            "guan", "guang", "gong", "gua", "guai", "gui", "guo", "hao", "hang",
            "zhong", "chi", "shi", "shuang", "ri", "zi", "cai", "sao", "san", "shan",
            // zero-initials incl. traps
            "a", "e", "er", "ai", "ang", "ying", "yong", "wang", "wai", "yuan", "yue", "you",
        ]
        for s in syllables {
            let code = try XCTUnwrap(decoder.encode(syllable: s), "encode failed for \(s)")
            XCTAssertEqual(decoder.decodeSyllable(code), s, "round-trip \(s) via \(code)")
        }
    }
}

// MARK: - Single-instance isolation (no shared global mutable state)

final class SchemeInstanceIsolationTests: XCTestCase {
    /// Building and using a *second*, deliberately different scheme must not
    /// change what the flypy decoder produces.
    func testFlypyUnaffectedBySecondScheme() {
        let flypy = ShuangpinDecoder(scheme: FlypyScheme.flypy)
        XCTAssertEqual(flypy.decodeSyllable("hc"), "hao")

        let alt = SchemeDefinition(
            schemeId: 2,
            displayName: "alt",
            zeroInitialLeadKeys: [],
            keyToInitial: ["h": "h"],
            initialToClass: ["h": .gkhzh],
            finalTable: [.gkhzh: ["c": "XX"]],   // h + c = "hXX", not "hao"
            zeroDecodeTable: [:])
        let altDecoder = ShuangpinDecoder(scheme: alt)

        XCTAssertEqual(altDecoder.decodeSyllable("hc"), "hXX")
        // Flypy decoder — and the shared FlypyScheme.flypy value — are unchanged.
        XCTAssertEqual(flypy.decodeSyllable("hc"), "hao")
        XCTAssertEqual(FlypyScheme.flypy.zeroDecodeTable.count, 35)
    }
}
