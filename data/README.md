# TypoFree base lexicon

`lexicon.bin` is the offline-compiled binary blob the Swift runtime loads at
startup (`Data(contentsOf:)` + one linear pass) into an in-memory
`[String: [(word: String, freq: Float)]]`, keyed by concatenated 小鹤双拼
(flypy) shuangpin codes. Built by `../tools/build_lexicon.py`. See that
file's module docstring for the exact binary format and the full
encode-table derivation/citations; this README covers sources, licenses,
attribution, how to rebuild, and known limitations.

## Sources

| File | Upstream | Commit (pinned by content, re-verified 2026-07-18) | License | Role |
|---|---|---|---|---|
| `sources/essay.txt` | [rime/rime-essay](https://github.com/rime/rime-essay) | `e9b1a374a6ea015fca5bdd04318924b4483ac35` | **LGPL-3.0** | Word list + integer frequency (442,693 unique words after dedup) — the *only* source of candidate words and ranking. |
| `sources/large_pinyin.txt` | [mozillazg/phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data) | `cee0ed6e6e4898580cafd2bd5e3723e20b214aa` | MIT | Word-level, heteronym-correct pinyin for multi-char phrases (411,956 phrases). Exact-match first choice for len&gt;1 words. |
| `sources/pinyin.txt` | [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data) | `923b108dc5d45dee061324c011b478fb649f8b7` | MIT | Per-character pinyin, first reading of the comma list used (44,435 chars). Used directly for 1-char words and as the char-decompose fallback for multi-char words that miss `large_pinyin.txt`. |

All three were fetched via `raw.githubusercontent.com` (reachable; no proxy
needed) on 2026-07-18. The commit hashes above were independently
re-resolved via the GitHub API at build time and match the ones cited in
`../research/EXPLORE.md` Appendix B — the upstream data has not moved since
that research pass.

## License posture (LGPL-3.0 on `essay.txt`)

`essay.txt` is data, not code, but it is licensed LGPL-3.0 by its publisher.
Per `../research/EXPLORE.md` Decision D15 and the precedent set by every
shipping rime-derived IME (Squirrel/Weasel/同文/鼠须管): **bundle the
compiled `lexicon.bin` + keep this build script open + ship in-app
Acknowledgements** naming rime-essay/LGPL-3.0. That satisfies the
"provide means to relink/regenerate" spirit even though LGPL's
code-linking mechanics don't map cleanly onto a flat data file. The
Swift app's Settings/About screen must list all three sources and licenses
verbatim (see table above) — this is a **hard requirement for the app
implementer**, not optional polish.

`large_pinyin.txt` and `pinyin.txt` are MIT — no reciprocal obligation
beyond attribution, which is included here and should also appear in the
app's Acknowledgements for completeness.

## How to rebuild

```bash
cd labs/typofree/tools
uv run build_lexicon.py
# optional flags:
uv run build_lexicon.py --sources ../data/sources --out-bin ../data/lexicon.bin \
  --out-tsv ../data/lexicon_sample.tsv --sample-n 200
```

Re-running is idempotent and deterministic (same inputs -> byte-identical
`lexicon.bin`, since keys are sorted and posting order is a stable sort on
`essay.txt`'s own iteration order). No network access needed once
`data/sources/*.txt` exist. To refresh the sources themselves, re-download
the three URLs above (see the table) or `git clone --depth 1` each repo.

## Output artifacts

- `lexicon.bin` — the compiled binary blob (8.67 MB). Format spec lives in
  `../tools/build_lexicon.py`'s module docstring (magic `TFX1`, 16-byte
  header, then keyCount records of `[keyLen][keyBytes][postingCount]` each
  followed by `postingCount` records of `[wordLen][wordBytes][logFreq f32]`,
  all little-endian, one forward linear pass, no offset table).
- `lexicon_sample.tsv` — first 200 `(key, word, count, logfreq)` rows in
  build order (key ascending, then freq descending within key), for human
  inspection. Not used at runtime.

## Known limitation: `essay.txt` is Traditional-Chinese-dominant

**This was not caught by the original EXPLORE.md research** (which measured
pinyin-resolvability only, not script). Discovered during this build: of
essay.txt's 442,693 words, the simplified/traditional divergent-character
pairs are wildly skewed traditional, e.g. 國(4,410 entries, freq-sum
2,323,179) vs 国(1 entry, freq-sum 100); 說 340,332 vs 说 0; 這 181,776 vs
这 0; 我們 vs 我们 similarly skewed. The top-40 most frequent essay.txt
words read 這個/我們/因爲/沒有/他們/什麼/還 — unambiguously Traditional.
`rime-essay`'s own README (written in Traditional) and its schema
dependency chain confirm why: **Rime's architecture ships dictionaries in
Traditional and applies an OpenCC-based `simplifier` filter at query time**
(visible in `double_pinyin_flypy.schema.yaml`'s `engine.filters:
[simplifier, uniquifier]`) — there is no separate pre-simplified essay
wordlist upstream (verified: rime-essay's repo contains only
`essay.txt`/`README.md`/`LICENSE`/`AUTHORS`/`Makefile`, no simplified
variant). TypoFree's locked architecture has no equivalent conversion step
anywhere (build-time or runtime). **This is flagged as `open_questions[0]`
in the design return — it needs an explicit decision before ship**, since
`大鹤`/`小鹤` shuangpin's real-world user base overwhelmingly types
Simplified Chinese.

## Known limitation: 31 words have no flypy code (post-pinyin-resolution encode gap)

442,402/442,693 = 99.9343% of essay.txt words fully resolve (pinyin AND
flypy-encode). Breaking that down: 260 words fail at the **pinyin**
resolution step (rare/unit characters, e.g. 瓧/兡/兙/㗎, plus proper-noun
phrases containing non-Han separators like "亞歷山大·杜布切克" or full-width
Latin like "卡拉ＯＫ") — this reproduces `EXPLORE.md`'s independently-measured
260 exactly. An *additional* 31 words resolve pinyin fully but fail at the
**flypy-encode** step: all contain one of the syllables `yo`/`n`/`m`/`hm`
(嗯/呣/噷/哟/唷/喲-family interjections, e.g. 哎唷/哎喲/莎喲娜拉), which are
outside Appendix A's 35-entry zero-initial table and the regular
initial+final system — i.e. standard 小鹤双拼 has no shuangpin code for
these at all. This is a genuine (tiny: 0.007% of words) gap in the locked
scheme spec, not a bug in the build script; see `open_questions` for the
one-line data fix if it ever matters in practice.

## Attribution text (for in-app Acknowledgements, copy verbatim)

```
Chinese lexicon data:
- rime-essay (github.com/rime/rime-essay), LGPL-3.0, © Rime Input Method Engine contributors
- phrase-pinyin-data (github.com/mozillazg/phrase-pinyin-data), MIT, © mozillazg
- pinyin-data (github.com/mozillazg/pinyin-data), MIT, © mozillazg
Compiled offline; build script at labs/typofree/tools/build_lexicon.py (open source, part of this app).
```
