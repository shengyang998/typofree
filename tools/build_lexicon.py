#!/usr/bin/env python3
"""
build_lexicon.py — TypoFree base lexicon compiler.

Compiles three offline sources into a single binary blob (lexicon.bin) that
the Swift runtime loads with ONE linear pass into `[String: [(word: String,
freq: Float)]]`, keyed by concatenated 小鹤双拼 (flypy) shuangpin codes.

Sources (see labs/typofree/research/EXPLORE.md Appendix B):
  - essay.txt        rime/rime-essay              LGPL-3.0   word \t intCount
  - large_pinyin.txt mozillazg/phrase-pinyin-data  MIT        phrase: py1 py2 ... (tone-marked)
  - pinyin.txt       mozillazg/pinyin-data         MIT        U+XXXX: py1,py2,... # char (tone-marked)

Pipeline (mirrors EXPLORE.md Appendix B step-by-step):
  1. essay.txt        -> (word, rawCount) frequency list, dedup-by-sum on the
                          rare (3/442,696) duplicate word lines.
  2. large_pinyin.txt -> phrase -> [toneMarkedSyllable, ...], word-level and
                          heteronym-correct. First occurrence wins on the 2
                          known duplicate phrase keys (朝阳, 那些).
  3. pinyin.txt       -> char -> firstToneMarkedReading (first of the
                          comma-separated readings), used both as the direct
                          lookup for 1-char essay words and as the per-char
                          decompose fallback for multi-char words that miss
                          large_pinyin.txt.
  4. For each essay word: resolve full tone-marked pinyin (len==1 -> pinyin.txt
     char lookup; len>1 -> exact large_pinyin.txt phrase match, else per-char
     decompose via pinyin.txt, failing the whole word if any char is missing);
     strip tones per syllable (ü/ǖǘǚǜ -> ASCII 'v', all other toned vowels via
     NFD-decompose + drop combining marks); encode each toneless syllable to
     its flypy 2-letter shuangpin code (Appendix A, ported below and
     cross-verified against the real rime/rime-double-pinyin
     double_pinyin_flypy.schema.yaml `algebra` — see comments below); if every
     syllable encodes, concatenate the codes into the lexicon lookup key
     (你好 -> "ni"+"hc" -> "nihc", exactly matching Appendix B's worked example).
  5. Group postings by key; sort keys ascending (byte order) for a
     deterministic, diffable build; sort postings within a key by rawCount
     descending (stable, so ties keep essay.txt's original order); emit
     lexicon.bin (binary, see format doc below) + lexicon_sample.tsv (first
     N postings in build order, human-readable).

Usage:
  uv run build_lexicon.py
  uv run build_lexicon.py --sources DIR --out-bin FILE --out-tsv FILE --sample-n 200

Binary format (lexicon.bin) — all multi-byte ints little-endian, all strings
UTF-8 byte sequences with a 1-byte length prefix (no NUL terminator), single
forward linear pass, no separate index/offset table:

  Header (16 bytes):
    0  4B  magic         ASCII "TFX1"
    4  2B  formatVersion UInt16 LE = 1
    6  2B  schemeId      UInt16 LE = 1 (小鹤双拼 flypy)
    8  4B  keyCount      UInt32 LE
   12  4B  postingCount  UInt32 LE  (total (word,freq) pairs, for capacity hints)
  Header is 16 bytes total (4 magic + 2 + 2 + 4 + 4).

  Then keyCount records, each:
    1B  keyLen        UInt8  (ASCII byte length of the shuangpin key, e.g. 4 for "nihc")
    keyLen B  keyBytes  ASCII lowercase a-z
    2B  postingCount  UInt16 LE (number of (word,freq) postings for this key)
    postingCount x posting record:
      1B  wordLen     UInt8 (UTF-8 byte length of the word)
      wordLen B  wordBytes  UTF-8
      4B  logFreq     Float32 LE = ln(1 + rawCount)  (natural log1p; handles the
                        essay.txt 0-count "coverage" entries -> logFreq 0.0
                        instead of -inf; NOT scaled/combined with any length
                        bonus — that combination is a Swift-side Viterbi concern)

License: this script is original code, not derived from any GPL/LGPL source.
The Appendix-A tables below are a data transcription of a public double-pinyin
layout specification (also independently re-derivable from the MIT-licensed
rime-double-pinyin schema's `algebra` rules), not copied source code.
"""

from __future__ import annotations

import argparse
import math
import re
import struct
import sys
import time
import unicodedata
from collections import Counter, OrderedDict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# ==========================================================================
# Appendix A — 小鹤双拼 (flypy) ENCODE tables (pinyin syllable -> shuangpin code)
#
# Ported from labs/typofree/research/EXPLORE.md Appendix A. Cross-verified
# by hand-tracing rime/rime-double-pinyin's double_pinyin_flypy.schema.yaml
# `algebra` (cloned read-only to /tmp/typofree-design/rime-double-pinyin for
# this verification pass; MIT-style rime schema, cited for verification only,
# nothing vendored/copied from it into this file).
#
# Key insight validated during that trace: Appendix A.2's "overloaded keys"
# (o/k/l/s/x/v/t) are only ambiguous in the DECODE direction (same keystroke,
# different meaning depending on initial). For ENCODE (this script's
# direction: real final string -> key), every final-remainder string is
# unique, so a single flat dict is exact — no initial-class conditioning
# needed. E.g. "o"->'o' (b/p/m/f literal-o case) and "uo"->'o' (everyone
# else) are different input strings that happen to share an output key;
# there is no case where the same final-remainder string must map to two
# different keys.
# ==========================================================================

# A.1 — initials (first key). zh/ch/sh compress to v/i/u; the rest are
# literal (map to themselves). y/w are deliberately NOT here — real Mandarin
# y/w-initial syllables are a closed set of 23, fully covered by the
# ZERO_INITIAL table below (checked before this decomposition ever runs).
COMPRESSED_INITIALS = {"zh": "v", "ch": "i", "sh": "u"}
LITERAL_INITIALS = set("bpmfdtnlgkhjqxrzcs")

# A.2 — finals (second key), flattened final-remainder -> key.
FINAL_TO_KEY: dict[str, str] = {
    # "无歧义（non-overloaded）键" — unconditioned regardless of initial.
    # r=uan's Appendix A footnote "(除 b/p/m/f)" needs no special-case here:
    # b/p/m/f + uan is not a real Mandarin syllable (phonotactic gap), so the
    # "uan" remainder is simply never produced for those initials — verified
    # by hand-tracing schema.yaml's `xform/uan$/R/` (unconditioned) plus the
    # generic `xform/(.)an$/$1J/` fallback that ban/pan/man/fan actually hit.
    "iu": "q", "ei": "w", "uan": "r", "un": "y", "ie": "p", "ai": "d",
    "en": "f", "eng": "g", "ang": "h", "an": "j", "ou": "z", "ao": "c",
    "in": "b", "iao": "n", "ian": "m",
    # "literal（自映射）" — a/e/i/u pass through unchanged.
    "a": "a", "e": "e", "i": "i", "u": "u",
    # Overloaded key 'o': literal "o" (b/p/m/f, e.g. bo/po/mo/fo) vs "uo"
    # (everyone else, e.g. duo/tuo/guo/zhuo/luo...). Different strings, same key.
    "o": "o", "uo": "o",
    # Overloaded key 'k': "uai" (g/k/h/zh/ch/sh) vs "ing" (b/p/m/d/t/n/l/j/q/x).
    "uai": "k", "ing": "k",
    # Overloaded key 'l': "uang" (g/k/h/zh/ch/sh) vs "iang" (j/q/x/n/l).
    "uang": "l", "iang": "l",
    # Overloaded key 's': "ong" (g/k/h/zh/ch/sh/r/z/c/s) vs "iong" (j/q/x).
    "ong": "s", "iong": "s",
    # Overloaded key 'x': "ua" (g/k/h/zh/ch/sh) vs "ia" (b/p/m/d/t/n/l/j/q/x).
    "ua": "x", "ia": "x",
    # Overloaded key 'v': "ui" (d/t/g/k/h/zh/ch/sh/r/z/c/s) vs literal ü
    # (n/l only: nü/lü). ü was already normalized to ASCII "v" by strip_tone,
    # so the literal-ü case is just the single-char remainder "v".
    "ui": "v", "v": "v",
    # Overloaded key 't': üe, spelled "ue" after j/q/x (diaeresis dropped per
    # standard orthography) vs "ve" after n/l (diaeresis kept as "v").
    "ue": "t", "ve": "t",
}
assert len(FINAL_TO_KEY) == 33, f"expected 33 final-remainder entries, got {len(FINAL_TO_KEY)}"

# A.3 — 35-entry zero-initial table, verbatim. Full-syllable exact match,
# checked BEFORE the general initial+final decomposition (y/w are not real
# initials in this scheme — see COMPRESSED_INITIALS/LITERAL_INITIALS above).
ZERO_INITIAL: dict[str, str] = {
    # 真零辅音 (12)
    "a": "aa", "o": "oo", "e": "ee", "ai": "ai", "ei": "ei", "ao": "ao",
    "ou": "ou", "an": "an", "en": "en", "ang": "ah", "eng": "eg", "er": "er",
    # y-glide (14)
    "yi": "yi", "ya": "ya", "ye": "ye", "yao": "yc", "you": "yz",
    "yan": "yj", "yin": "yb", "yang": "yh", "ying": "yk", "yong": "ys",
    "yu": "yu", "yuan": "yr", "yue": "yt", "yun": "yy",
    # w-glide (9)
    "wu": "wu", "wa": "wa", "wo": "wo", "wai": "wd", "wei": "ww",
    "wan": "wj", "wen": "wf", "wang": "wh", "weng": "wg",
}
assert len(ZERO_INITIAL) == 35, f"expected 35 zero-initial entries, got {len(ZERO_INITIAL)}"

# The 8 counter-intuitive "trap" spellings called out in Appendix A.3 — the
# orthography drops the medial vowel a naive analogy would expect, so these
# MUST come from the explicit table, not from generic initial+final decode.
TRAP_SYLLABLES = ["wai", "wei", "wan", "wang", "yao", "you", "yang", "yong"]
_EXPECTED_TRAP_CODES = {
    "wai": "wd", "wei": "ww", "wan": "wj", "wang": "wh",
    "yao": "yc", "you": "yz", "yang": "yh", "yong": "ys",
}
assert len(TRAP_SYLLABLES) == 8
for _syll, _code in _EXPECTED_TRAP_CODES.items():
    assert ZERO_INITIAL[_syll] == _code, f"trap mismatch: {_syll} -> {ZERO_INITIAL[_syll]!r}, expected {_code!r}"


def encode_syllable(syllable: str) -> Optional[str]:
    """Toneless pinyin syllable (ü already normalized to 'v') -> 2-char flypy code, or None."""
    if not syllable:
        return None
    zero = ZERO_INITIAL.get(syllable)
    if zero is not None:
        return zero
    prefix2 = syllable[:2]
    if prefix2 in COMPRESSED_INITIALS:
        initial_key = COMPRESSED_INITIALS[prefix2]
        remainder = syllable[2:]
    elif syllable[0] in LITERAL_INITIALS:
        initial_key = syllable[0]
        remainder = syllable[1:]
    else:
        return None  # no recognized initial and not a zero-initial syllable
    final_key = FINAL_TO_KEY.get(remainder)
    if final_key is None:
        return None
    return initial_key + final_key


# ==========================================================================
# Tone stripping: tone-marked pinyin syllable -> toneless ASCII, ü -> 'v'
# ==========================================================================

_UMLAUT_U = {"ü", "ǖ", "ǘ", "ǚ", "ǜ"}


def strip_tone(syllable: str) -> str:
    out = []
    for ch in syllable:
        if ch in _UMLAUT_U:
            out.append("v")
            continue
        if ch.isascii():
            out.append(ch)
            continue
        decomposed = unicodedata.normalize("NFD", ch)
        base = "".join(c for c in decomposed if not unicodedata.combining(c))
        out.append(base if base else ch)
    return "".join(out)


# ==========================================================================
# Source parsers
# ==========================================================================


def load_essay(path: Path) -> "OrderedDict[str, int]":
    """word -> summed rawCount (first-seen order preserved; dedup-by-sum on dup lines)."""
    words: "OrderedDict[str, int]" = OrderedDict()
    malformed = 0
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                malformed += 1
                continue
            word, count_s = parts
            try:
                count = int(count_s)
            except ValueError:
                malformed += 1
                continue
            words[word] = words.get(word, 0) + count
    if malformed:
        print(f"  [essay.txt] WARNING: {malformed} malformed lines skipped", file=sys.stderr)
    return words


def load_large_pinyin(path: Path) -> dict[str, list[str]]:
    """phrase -> [toneMarkedSyllable, ...]; first occurrence wins on the rare dup keys."""
    mapping: dict[str, list[str]] = {}
    dup = 0
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            if ": " not in line:
                continue
            phrase, rest = line.split(": ", 1)
            if " #" in rest:  # one known line (地藏) has a trailing inline comment
                rest = rest.split(" #", 1)[0]
            sylls = rest.strip().split(" ")
            if phrase in mapping:
                dup += 1
                continue
            mapping[phrase] = sylls
    if dup:
        print(f"  [large_pinyin.txt] {dup} duplicate phrase keys, first occurrence kept", file=sys.stderr)
    return mapping


_PINYIN_LINE_RE = re.compile(r"^U\+([0-9A-Fa-f]+):\s*([^#]+?)\s*(?:#.*)?$")


def load_pinyin_chars(path: Path) -> dict[str, str]:
    """char (by codepoint) -> first tone-marked reading (first of comma-separated list)."""
    mapping: dict[str, str] = {}
    malformed = 0
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            m = _PINYIN_LINE_RE.match(line)
            if not m:
                malformed += 1
                continue
            cp_hex, readings = m.groups()
            try:
                char = chr(int(cp_hex, 16))
            except ValueError:
                malformed += 1
                continue
            first_reading = readings.split(",")[0].strip()
            mapping[char] = first_reading
    if malformed:
        print(f"  [pinyin.txt] WARNING: {malformed} malformed lines skipped", file=sys.stderr)
    return mapping


# ==========================================================================
# Word -> tone-marked syllables resolution (EXPLORE Appendix B step 3)
# ==========================================================================


def resolve_word(
    word: str, large_pinyin: dict[str, list[str]], pinyin_chars: dict[str, str]
) -> tuple[Optional[list[str]], str]:
    """Return (list of tone-marked syllables or None, resolution path tag)."""
    if len(word) == 1:
        r = pinyin_chars.get(word)
        return ([r], "single_char") if r else (None, "unresolved_single_char")
    exact = large_pinyin.get(word)
    if exact is not None:
        return (exact, "phrase_exact")
    sylls = []
    for ch in word:
        r = pinyin_chars.get(ch)
        if r is None:
            return (None, "unresolved_char_decompose")
        sylls.append(r)
    return (sylls, "char_decompose")


# ==========================================================================
# Binary writer
# ==========================================================================

MAGIC = b"TFX1"
FORMAT_VERSION = 1
SCHEME_ID_FLYPY = 1


def write_binary(sorted_keys: list[str], keyed: dict[str, list[tuple[str, int]]], out_path: Path) -> dict:
    key_count = len(sorted_keys)
    posting_count = sum(len(keyed[k]) for k in sorted_keys)
    max_key_len = 0
    max_word_utf8_len = 0
    max_postings_per_key = 0
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<H", FORMAT_VERSION))
        f.write(struct.pack("<H", SCHEME_ID_FLYPY))
        f.write(struct.pack("<I", key_count))
        f.write(struct.pack("<I", posting_count))
        for k in sorted_keys:
            kb = k.encode("ascii")
            if len(kb) > 255:
                raise ValueError(f"key too long for UInt8 length prefix: {k!r}")
            max_key_len = max(max_key_len, len(kb))
            postings = keyed[k]
            if len(postings) > 65535:
                raise ValueError(f"too many postings for UInt16 count: {k!r}")
            max_postings_per_key = max(max_postings_per_key, len(postings))
            f.write(struct.pack("<B", len(kb)))
            f.write(kb)
            f.write(struct.pack("<H", len(postings)))
            for word, count in postings:
                wb = word.encode("utf-8")
                if len(wb) > 255:
                    raise ValueError(f"word too long for UInt8 length prefix: {word!r}")
                max_word_utf8_len = max(max_word_utf8_len, len(wb))
                logfreq = math.log1p(count)
                f.write(struct.pack("<B", len(wb)))
                f.write(wb)
                f.write(struct.pack("<f", logfreq))
    return {
        "key_count": key_count,
        "posting_count": posting_count,
        "max_key_len": max_key_len,
        "max_word_utf8_len": max_word_utf8_len,
        "max_postings_per_key": max_postings_per_key,
        "bytes_on_disk": out_path.stat().st_size,
    }


def write_sample_tsv(sorted_keys: list[str], keyed: dict[str, list[tuple[str, int]]], out_path: Path, n: int) -> int:
    written = 0
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        f.write("key\tword\tcount\tlogfreq\n")
        for k in sorted_keys:
            for word, count in keyed[k]:
                if written >= n:
                    return written
                f.write(f"{k}\t{word}\t{count}\t{math.log1p(count):.6f}\n")
                written += 1
    return written


# ==========================================================================
# Spot-check report (task step 5)
# ==========================================================================


def encode_word_pipeline(
    word: str, large_pinyin: dict[str, list[str]], pinyin_chars: dict[str, str]
) -> tuple[Optional[str], str]:
    """Run a word through the exact same resolve->strip->encode pipeline as the main build."""
    sylls, path = resolve_word(word, large_pinyin, pinyin_chars)
    if sylls is None:
        return None, path
    toneless = [strip_tone(s) for s in sylls]
    codes = [encode_syllable(s) for s in toneless]
    if any(c is None for c in codes):
        return None, "encode_failed"
    return "".join(codes), path


def print_spot_checks(large_pinyin: dict[str, list[str]], pinyin_chars: dict[str, str]) -> None:
    print("\n=== Spot-check: 你好 (Appendix B worked example, expect 'nihc') ===")
    code, path = encode_word_pipeline("你好", large_pinyin, pinyin_chars)
    print(f"  你好 -> {code!r} (via {path}) {'OK' if code == 'nihc' else 'MISMATCH!!'}")

    print("\n=== Spot-check: multi-char words ===")
    for w in ["中国", "谢谢", "北京", "双拼输入法", "小鹤双拼", "程序员", "输入法"]:
        code, path = encode_word_pipeline(w, large_pinyin, pinyin_chars)
        print(f"  {w} -> {code!r} (via {path})")

    print("\n=== Spot-check: 8 zero-initial trap syllables (standalone, direct table) ===")
    for s in TRAP_SYLLABLES:
        code = encode_syllable(s)
        expect = _EXPECTED_TRAP_CODES[s]
        status = "OK" if code == expect else "MISMATCH!!"
        print(f"  {s} -> {code!r} (expect {expect!r}) {status}")

    print("\n=== Spot-check: 8 traps via a real dictionary character (full pipeline) ===")
    trap_chars = {
        "wai": "歪", "wei": "位", "wan": "弯", "wang": "王",
        "yao": "腰", "you": "有", "yang": "阳", "yong": "用",
    }
    for s, ch in trap_chars.items():
        code, path = encode_word_pipeline(ch, large_pinyin, pinyin_chars)
        expect = _EXPECTED_TRAP_CODES[s]
        status = "OK" if code == expect else "MISMATCH (informational: char may carry a different reading)"
        print(f"  {ch} ({s}) -> {code!r} (expect {expect!r}, via {path}) {status}")


# ==========================================================================
# Main build
# ==========================================================================


@dataclass
class BuildStats:
    essay_lines: int = 0
    essay_unique_words: int = 0
    resolved: int = 0
    unresolved: int = 0
    resolution_paths: Counter = field(default_factory=Counter)
    unresolved_examples: list = field(default_factory=list)
    encode_fail_examples: list = field(default_factory=list)
    zero_count_words: int = 0


def build(sources_dir: Path, out_bin: Path, out_tsv: Path, sample_n: int) -> None:
    t0 = time.time()
    print(f"[1/5] Loading sources from {sources_dir} ...")
    essay = load_essay(sources_dir / "essay.txt")
    large_pinyin = load_large_pinyin(sources_dir / "large_pinyin.txt")
    pinyin_chars = load_pinyin_chars(sources_dir / "pinyin.txt")
    t_load = time.time()
    print(
        f"      essay.txt: {len(essay)} unique words | "
        f"large_pinyin.txt: {len(large_pinyin)} phrases | "
        f"pinyin.txt: {len(pinyin_chars)} chars"
    )
    print(f"      load time: {t_load - t0:.2f}s")

    print("[2/5] Resolving pinyin + encoding flypy keys ...")
    stats = BuildStats(essay_lines=len(essay), essay_unique_words=len(essay))
    keyed: dict[str, list[tuple[str, int]]] = {}

    for word, count in essay.items():
        if count == 0:
            stats.zero_count_words += 1
        sylls, path = resolve_word(word, large_pinyin, pinyin_chars)
        if sylls is None:
            stats.resolution_paths[path] += 1
            stats.unresolved += 1
            if len(stats.unresolved_examples) < 40:
                stats.unresolved_examples.append(word)
            continue
        toneless = [strip_tone(s) for s in sylls]
        codes = [encode_syllable(s) for s in toneless]
        if any(c is None for c in codes):
            stats.resolution_paths[path + "_encode_failed"] += 1
            stats.unresolved += 1
            if len(stats.unresolved_examples) < 40:
                stats.unresolved_examples.append(word)
            if len(stats.encode_fail_examples) < 20:
                bad_i = next(i for i, c in enumerate(codes) if c is None)
                stats.encode_fail_examples.append((word, toneless, toneless[bad_i]))
            continue
        stats.resolution_paths[path] += 1
        stats.resolved += 1
        key = "".join(codes)
        keyed.setdefault(key, []).append((word, count))

    t_resolve = time.time()
    print(f"      resolve+encode time: {t_resolve - t_load:.2f}s")

    print("[3/5] Sorting keys + postings ...")
    sorted_keys = sorted(keyed.keys())
    for k in sorted_keys:
        keyed[k].sort(key=lambda wc: -wc[1])  # freq desc, stable -> essay.txt order breaks ties
    t_sort = time.time()
    print(f"      sort time: {t_sort - t_resolve:.2f}s")

    print(f"[4/5] Writing {out_bin} ...")
    bin_stats = write_binary(sorted_keys, keyed, out_bin)
    print(f"[5/5] Writing {out_tsv} (first {sample_n} postings) ...")
    tsv_written = write_sample_tsv(sorted_keys, keyed, out_tsv, sample_n)
    t_write = time.time()
    print(f"      write time: {t_write - t_sort:.2f}s")

    total_time = t_write - t0

    # ---- Report ----
    print("\n" + "=" * 72)
    print("BUILD REPORT")
    print("=" * 72)
    print(f"essay.txt lines (raw):        {stats.essay_lines}")
    print(f"essay.txt unique words:       {stats.essay_unique_words}")
    print(f"  of which rawCount==0:       {stats.zero_count_words} ({stats.zero_count_words/stats.essay_unique_words*100:.3f}%)")
    print(f"resolved:                     {stats.resolved} ({stats.resolved/stats.essay_unique_words*100:.4f}%)")
    print(f"unresolved:                   {stats.unresolved} ({stats.unresolved/stats.essay_unique_words*100:.4f}%)")
    print("resolution path breakdown:")
    for p, c in stats.resolution_paths.most_common():
        print(f"    {p:32s} {c}")
    print(f"unresolved examples (up to 40): {stats.unresolved_examples}")
    if stats.encode_fail_examples:
        print(f"encode-layer failures (pinyin resolved, flypy encode failed): {stats.encode_fail_examples}")
    print()
    print(f"distinct flypy keys:          {bin_stats['key_count']}")
    print(f"total postings:                {bin_stats['posting_count']}")
    print(f"max key length (bytes):        {bin_stats['max_key_len']}")
    print(f"max word length (utf8 bytes):  {bin_stats['max_word_utf8_len']}")
    print(f"max postings for one key:      {bin_stats['max_postings_per_key']}")
    print(f"lexicon.bin size:              {bin_stats['bytes_on_disk']} bytes ({bin_stats['bytes_on_disk']/1024/1024:.2f} MB)")
    print(f"lexicon_sample.tsv rows:       {tsv_written}")
    print()
    # Rough resident-memory estimate for the Swift in-memory Dictionary.
    # Swift String: ~16B inline for <=15 UTF8 bytes (small-string optimized,
    # true for virtually all words/keys here), else heap alloc w/ ~32B+ header.
    # Dictionary<String,[(String,Float)]> entry: ~32-48B bucket overhead per
    # key (hash + control bytes + key/value storage) + Array<(String,Float)>
    # per key: ~32B header + posting_count*(16B String + 4B Float, +padding).
    est_key_overhead = bin_stats["key_count"] * 56
    est_array_headers = bin_stats["key_count"] * 32
    est_posting_bytes = bin_stats["posting_count"] * (16 + 4 + 4)  # string + float + slop
    est_total = est_key_overhead + est_array_headers + est_posting_bytes
    print(f"ESTIMATED Swift resident memory (rough, not measured): ~{est_total/1024/1024:.1f} MB")
    print(f"  (blob-to-resident inflation ~{est_total/bin_stats['bytes_on_disk']:.1f}x; cross-check vs EXPLORE.md's")
    print(f"   independent D3 estimate of 30-70MB for the base lexicon)")
    print()
    print(f"wall time: load={t_load-t0:.2f}s resolve={t_resolve-t_load:.2f}s sort={t_sort-t_resolve:.2f}s "
          f"write={t_write-t_sort:.2f}s TOTAL={total_time:.2f}s")

    print_spot_checks(large_pinyin, pinyin_chars)


def main() -> None:
    repo_root_data = Path(__file__).resolve().parent.parent / "data"
    ap = argparse.ArgumentParser(description="Compile TypoFree's base lexicon into lexicon.bin")
    ap.add_argument("--sources", type=Path, default=repo_root_data / "sources")
    ap.add_argument("--out-bin", type=Path, default=repo_root_data / "lexicon.bin")
    ap.add_argument("--out-tsv", type=Path, default=repo_root_data / "lexicon_sample.tsv")
    ap.add_argument("--sample-n", type=int, default=200)
    args = ap.parse_args()

    for name in ("essay.txt", "large_pinyin.txt", "pinyin.txt"):
        p = args.sources / name
        if not p.exists():
            print(f"ERROR: missing source file {p}", file=sys.stderr)
            sys.exit(1)

    build(args.sources, args.out_bin, args.out_tsv, args.sample_n)


if __name__ == "__main__":
    main()
