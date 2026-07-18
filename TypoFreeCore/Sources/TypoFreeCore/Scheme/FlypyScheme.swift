// 小鹤双拼 (flypy) — the sole v1 SchemeDefinition. EXPLORE.md Appendix A.
//
// Source of truth: rime `double_pinyin_flypy.schema.yaml` speller.algebra +
// translator.preedit_format (which Appendix A "逐条模拟 ... 与 ulpb.app 100%
// 交叉验证" was derived from). The joint `finalTable` below is built from those
// preedit rules, keyed by DESIGN.md's mandated 5-class `InitialClass` partition.
//
// NOTE (Appendix-A-prose vs rime ground truth): Appendix A's overloaded-key
// prose lists only the phonetically-distinctive initial sets, so it (a) omits
// `dt+s / nl+s -> ong` — but 东(ds)/通(ts)/农(ns)/龙(ls) REQUIRE it — and (b)
// narrows k/l/x to {g,k,h,zh,ch,sh}, excluding r/z/c/s. The 5-class model cannot
// split r/z/c/s away from g/k/h inside `gkhzh`, and rime maps all of them
// uniformly (rule `[gkhvuirzcs]k->uai`, `(\w)l->uang`, etc.), so this file
// follows rime: within each of the 5 classes every second key resolves to a
// single final. The only visible effect is that non-word combos like z+k("zk")
// decode to a non-word pinyin ("zuai") instead of nil — harmless, the lexicon
// never contains them.
public enum FlypyScheme {
    public static let flypy: SchemeDefinition = makeFlypy()

    private static func makeFlypy() -> SchemeDefinition {
        // A.1 声母 -> 键 (21): 18 literal + compressed zh->v, ch->i, sh->u.
        let keyToInitial: [Character: String] = [
            "b": "b", "p": "p", "m": "m", "f": "f",
            "d": "d", "t": "t",
            "n": "n", "l": "l",
            "g": "g", "k": "k", "h": "h",
            "j": "j", "q": "q", "x": "x",
            "r": "r", "z": "z", "c": "c", "s": "s",
            "v": "zh", "i": "ch", "u": "sh",
        ]
        let initialToClass: [String: InitialClass] = [
            "b": .bpmf, "p": .bpmf, "m": .bpmf, "f": .bpmf,
            "d": .dt, "t": .dt,
            "n": .nl, "l": .nl,
            "j": .jqx, "q": .jqx, "x": .jqx,
            "g": .gkhzh, "k": .gkhzh, "h": .gkhzh,
            "zh": .gkhzh, "ch": .gkhzh, "sh": .gkhzh,
            "r": .gkhzh, "z": .gkhzh, "c": .gkhzh, "s": .gkhzh,
        ]

        // A.2 韵母. Non-overloaded + literal keys — identical across all 5 classes.
        let common: [Character: String] = [
            "q": "iu", "w": "ei", "y": "un", "p": "ie", "d": "ai", "f": "en",
            "g": "eng", "h": "ang", "j": "an", "z": "ou", "c": "ao", "b": "in", "m": "ian",
            "a": "a", "e": "e", "i": "i", "u": "u",
        ]
        func withOverloads(_ extra: [Character: String]) -> [Character: String] {
            common.merging(extra) { _, new in new }
        }
        // Overloaded/conditional second keys per class (o/k/l/s/x/v/t and the
        // conditional r=uan-except-bpmf, n=iao-only-for-bpmfdtnljqx). Keys absent
        // from a class = illegal syllable (decode -> nil).
        let finalTable: [InitialClass: [Character: String]] = [
            .bpmf:  withOverloads(["o": "o",              "k": "ing", "l": "uang", "s": "ong",  "x": "ia", "n": "iao"]),
            .dt:    withOverloads(["o": "uo", "r": "uan", "k": "ing", "l": "uang", "s": "ong",  "x": "ia", "n": "iao", "v": "ui"]),
            .nl:    withOverloads(["o": "uo", "r": "uan", "k": "ing", "l": "iang", "s": "ong",  "x": "ia", "n": "iao", "v": "ü", "t": "üe"]),
            .jqx:   withOverloads([            "r": "uan", "k": "ing", "l": "iang", "s": "iong", "x": "ia", "n": "iao",           "t": "ue"]),
            .gkhzh: withOverloads(["o": "uo", "r": "uan", "k": "uai", "l": "uang", "s": "ong",  "x": "ua", "v": "ui"]),
        ]

        // A.3 零声母 (35, explicit — simple concatenation cannot derive them).
        let zeroDecodeTable: [String: String] = [
            // 真零辅音 (12)
            "aa": "a", "oo": "o", "ee": "e", "ai": "ai", "ei": "ei", "ao": "ao",
            "ou": "ou", "an": "an", "en": "en", "ah": "ang", "eg": "eng", "er": "er",
            // y-glide (14) — note the traps yao->yc, you->yz, yang->yh, yong->ys
            "yi": "yi", "ya": "ya", "ye": "ye", "yc": "yao", "yz": "you", "yj": "yan",
            "yb": "yin", "yh": "yang", "yk": "ying", "ys": "yong", "yu": "yu",
            "yr": "yuan", "yt": "yue", "yy": "yun",
            // w-glide (9) — note the traps wai->wd, wei->ww, wan->wj, wang->wh
            "wu": "wu", "wa": "wa", "wo": "wo", "wd": "wai", "ww": "wei", "wj": "wan",
            "wf": "wen", "wh": "wang", "wg": "weng",
        ]

        return SchemeDefinition(
            schemeId: 1,
            displayName: "小鹤双拼",
            zeroInitialLeadKeys: ["a", "e", "o", "w", "y"],
            keyToInitial: keyToInitial,
            initialToClass: initialToClass,
            finalTable: finalTable,
            zeroDecodeTable: zeroDecodeTable)
    }
}
