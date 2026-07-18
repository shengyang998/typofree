# TypoFree base lexicon

`lexicon.bin` is the offline-compiled binary blob the Swift runtime loads at
startup (`Data(contentsOf:)` + one linear pass) into an in-memory
`[String: [(word: String, freq: Float)]]`, keyed by concatenated 小鹤双拼
(flypy) shuangpin codes. `readings.bin` (added M2) is a sidecar mapping every
single character to *all* of its toneless pinyin readings, used by the LLM
correction-validation gate to accept homophone swaps without being fooled by
heteronyms. Both are built by `../tools/build_lexicon.py`. See that file's
module docstring for the exact binary formats and the full encode-table
derivation/citations; this README covers sources, licenses, attribution, how
to rebuild, and known limitations.

**`data/lexicon.bin` and `data/readings.bin` are both symlinks**, not
physical files (added M0, extended to `readings.bin` in M2). The real,
git-tracked bytes live at
`../TypoFreeCore/Sources/TypoFreeCore/Resources/{lexicon,readings}.bin` —
SwiftPM's resource-copy step preserves symlinks-as-symlinks with their
original relative target string instead of dereferencing them, so a symlink
pointing *out* of the SPM resource directory (the original
`Resources/lexicon.bin -> ../../../../data/lexicon.bin` arrangement) goes
dangling once copied into a `.build/<triple>/<config>/*.bundle/` (or, later,
an Xcode-embedded) output directory at a different nesting depth (confirmed
empirically: `swift build` reports success, but the copied symlink 404s at
`open()`). Flipping the relationship keeps `data/` as this documented
canonical build-output path — `build_lexicon.py`'s `--out-bin`/
`--out-readings` defaults are unchanged and still work because
`Path.open("wb")` follows symlinks on write — while the SPM package only
ever sees a plain file, which survives any copy depth.

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

In addition to the three data sources above, the build depends on
**opencc-python-reimplemented** (`0.1.7`, Apache-2.0) — not a data file, a
build-time Python library (`tools/pyproject.toml`/`uv.lock`) used for the
Traditional→Simplified conversion step; see "OpenCC 繁→简 conversion" below.

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
  --out-readings ../data/readings.bin --out-tsv ../data/lexicon_sample.tsv --sample-n 200
```

Re-running is idempotent and deterministic (same inputs -> byte-identical
`lexicon.bin`/`readings.bin`, since keys are sorted and posting order is a
stable sort on the post-OpenCC-merge iteration order — verified 2026-07-18 by
diffing two consecutive runs' output, both files byte-identical). No network
access needed once `data/sources/*.txt` exist (OpenCC's conversion tables
ship inside the `opencc-python-reimplemented` package itself — no network
call at build time either). To refresh the sources themselves, re-download
the three URLs above (see the table) or `git clone --depth 1` each repo.

## OpenCC 繁→简 conversion (added M2)

`essay.txt` is Traditional-Chinese-dominant (see "Known limitation" below,
now resolved) while 小鹤双拼 is a Simplified-oriented input scheme and this
app's target users overwhelmingly type Simplified. `build_lexicon.py` runs
every essay.txt word through `OpenCC('t2s').convert(word)` **before** any
pinyin resolution (DECISIONS.md user-Q1, DESIGN.md §8's "在拼音解析前繁→简"),
summing `rawCount` when two source words collapse onto the same simplified
spelling (e.g. 說 340,332 + 说 0 → 说 340,332). Converting *before*
resolution, not after, was a deliberate ordering choice, not just a script
change: `large_pinyin.txt` (the phrase-level, heteronym-correct pinyin
source) turned out to be **Simplified-only** — it has zero entries for
common Traditional phrases (spot-checked: 這/說/國/臺灣/電腦 combinations all
return no match) — while `pinyin.txt` (the per-character fallback) covers
both scripts. So pre-OpenCC, most Traditional multi-character words in
essay.txt were silently falling through phrase-exact matching straight to
per-character decomposition, losing `large_pinyin.txt`'s heteronym-correct
phrase readings. Converting first fixed both problems at once: the emitted
lexicon is pure Simplified, *and* phrase-exact match rates improved (the
post-OpenCC build's resolution-path breakdown shows `phrase_exact` claiming a
larger share of resolved words than before).

Rebuild result (2026-07-18, `uv run build_lexicon.py`, full sources):
- essay.txt: 442,693 unique words (pre-OpenCC) → **437,796** (post-merge);
  **4,897** source entries merged into an already-produced simplified key.
- Resolved 437,490 / 437,796 = **99.9301%** (306 unresolved — see "31 words
  have no flypy code" below; unresolved reasons are unchanged in kind by
  OpenCC, just recomputed against the smaller post-merge word set).
- `lexicon.bin`: 310,654 distinct flypy keys, 437,490 postings, **9,044,402
  bytes (8.63 MB)** — slightly *smaller* than the pre-OpenCC 8.67 MB blob,
  as expected from merging duplicate script-variant entries.
- Full rebuild (load + OpenCC + resolve + sort + write lexicon.bin +
  lexicon_sample.tsv + write readings.bin): **6.81s wall time** on the dev
  box (M2 Pro).
- `postings("aa")` changed from the pre-OpenCC `[啊,阿,錒,嗄,锕]` (5 entries,
  含 Traditional 錒) to the post-OpenCC `[啊,阿,锕,嗄]` (4 entries) — 錒
  converts to 锕 and its frequency (formerly a separate, low-count entry)
  merges into 锕's.

## readings.bin toneless convention (added M2, must_fix #2)

`readings.bin` (TFXR v1 — format doc in `build_lexicon.py`'s module
docstring) maps every character in `pinyin.txt` (44,435 chars, independent
of `essay.txt`/OpenCC/script) to *all* of its distinct toneless readings —
**6,992** characters have more than one distinct toneless reading (vs.
8,624 characters with more than one *tone-marked* reading before dedup —
e.g. 们's men/mén both strip to the same toneless "men", so 们 counts toward
the 8,624 but not the 6,992; the smaller, deduped number is the
semantically-correct one for a *toneless* gate).

**The ü-family is the one sharp edge.** `build_lexicon.py` already has an
ASCII-only toneless convention (`strip_tone`: ü/ǖ/ǘ/ǚ/ǜ → ASCII `"v"`), baked
into its shuangpin *encode* tables (`FINAL_TO_KEY`/`ZERO_INITIAL`, which are
keystroke-code tables, not pinyin-text tables) — but the Swift
`ShuangpinDecoder` built in M1
(`TypoFreeCore/Sources/TypoFreeCore/Scheme/FlypyScheme.swift`) canonicalizes
its `.nl`-class finals on the **precomposed U+00FC "ü"** character itself:
`decodeSyllable("nv")` (the shuangpin keys `n`+`v`) returns the pinyin string
`"nü"`, not `"nv"`. A `readings.bin` built with `strip_tone`'s ASCII `"v"`
would therefore never match what the decoder actually produces, and every
nü/lü/nüe/lüe correction would false-reject at the D12 validation gate —
exactly the bug must_fix #2 exists to prevent.

The fix: `readings.bin` uses a **separate** toneless function,
`strip_tone_keep_umlaut` (parallel to, and independent from, `strip_tone`),
that keeps ü on U+00FC instead of collapsing it to `"v"`. So 女's readings
are `["nü", "ru"]` (from nǚ/nǜ/rǔ), not `["nv", "ru"]`. Swift's
`PinyinReadingIndex.canRead` is written against this same convention — it
decodes the shuangpin code via `ShuangpinDecoder.decodeSyllable` (producing
`"nü"`, never `"v"`) and compares that string directly against
`readings(of:)`, so both sides agree. **Every reading byte in
`readings.bin` is therefore UTF-8, not strictly ASCII** — the one exception
to the general "ASCII except where noted" convention used elsewhere in this
lexicon's binary formats. This is intentional and load-bearing, not an
oversight; do not "fix" it back to ASCII without re-threading the conversion
on the Swift side first (see `PinyinReadingIndex.swift`'s header comment).

## Output artifacts

- `lexicon.bin` — the compiled binary blob (**8.63 MB**, post-OpenCC).
  Format spec lives in `../tools/build_lexicon.py`'s module docstring (magic
  `TFX1`, 16-byte header, then keyCount records of
  `[keyLen][keyBytes][postingCount]` each followed by `postingCount` records
  of `[wordLen][wordBytes][logFreq f32]`, all little-endian, one forward
  linear pass, no offset table).
- `readings.bin` (added M2) — the multi-reading sidecar (**445.1 KB**,
  44,435 characters, 6,992 with >1 distinct toneless reading, max 8 readings
  for one character). Format spec (magic `TFXR`, 12-byte header, then
  charCount records of `[charUTF8Len][charUTF8][readingCount]` each followed
  by `readingCount` records of `[readingLen][readingUTF8]`) is in the same
  docstring. See "readings.bin toneless convention" above for why its
  `reading` bytes are UTF-8 (not ASCII) for the ü-family.
- `lexicon_sample.tsv` — first 200 `(key, word, count, logfreq)` rows in
  build order (key ascending, then freq descending within key), for human
  inspection. Not used at runtime.

## Known limitation (RESOLVED M2): `essay.txt` is Traditional-Chinese-dominant

**This was not caught by the original EXPLORE.md research** (which measured
pinyin-resolvability only, not script). Discovered during the M0 build: of
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
variant). This was flagged as `open_questions[0]` in the original design
return; DECISIONS.md's "Design-phase user decisions" user-Q1 resolved it —
**build-time OpenCC 繁→简 conversion, implemented in M2**. See "OpenCC 繁→简
conversion" above for the mechanism and real before/after numbers;
`lexicon.bin` is now pure Simplified.

## Known limitation: 306 words have no flypy code (post-pinyin-resolution encode gap)

Numbers below are post-OpenCC (M2 rebuild, 2026-07-18; the pre-OpenCC M0
numbers were 442,402/442,693 = 99.9343% resolved, 260+31=291 unresolved —
superseded here, not carried over, since OpenCC's word-merge legitimately
changes the denominator and can shift which merged entries do/don't resolve).

437,490/437,796 = **99.9301%** of (post-OpenCC-merge) essay.txt words fully
resolve (pinyin AND flypy-encode). Breaking that down: **276** words fail at
the **pinyin** resolution step (200 multi-char phrases containing non-Han
separators like "亚历山大·杜布切克" or full-width Latin like "卡拉ＯＫ", plus 76
rare/unit single characters, e.g. 瓧/兡/兙/㗎) — same underlying cause as
before, just recomputed against the post-merge word set. An *additional*
**30** words resolve pinyin fully but fail at the **flypy-encode** step: all
contain one of the syllables `yo`/`n`/`m` (嗯/呣/哟/唷-family interjections,
e.g. 哎唷/哎哟/嗨哟), which are outside Appendix A's 35-entry zero-initial
table and the regular initial+final system — i.e. standard 小鹤双拼 has no
shuangpin code for these at all. This is a genuine (tiny: 0.007% of words)
gap in the locked scheme spec, not a bug in the build script; see
`open_questions` for the one-line data fix if it ever matters in practice.

## Attribution text (for in-app Acknowledgements, copy verbatim)

```
Chinese lexicon data:
- rime-essay (github.com/rime/rime-essay), LGPL-3.0, © Rime Input Method Engine contributors
- phrase-pinyin-data (github.com/mozillazg/phrase-pinyin-data), MIT, © mozillazg
- pinyin-data (github.com/mozillazg/pinyin-data), MIT, © mozillazg
- opencc-python-reimplemented (github.com/yichen0831/opencc-python), Apache-2.0, © Yichen Huang (Eugene) — pure-Python port using dictionary data from BYVoid's OpenCC (github.com/BYVoid/OpenCC); used at build time for Traditional-to-Simplified conversion
Compiled offline; build script at labs/typofree/tools/build_lexicon.py (open source, part of this app).
```
