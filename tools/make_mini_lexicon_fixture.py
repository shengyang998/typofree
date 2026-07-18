#!/usr/bin/env python3
"""
make_mini_lexicon_fixture.py — emits TypoFreeCore's M0 test fixture.

Hand-writes a tiny, valid TFX1 blob (the same binary format `build_lexicon.py`
produces for the real `data/lexicon.bin` — see that script's module docstring
for the authoritative format spec, mirrored here for a *minimal* 3-key/4-posting
instance) so `TypoFreeCoreTests` can exercise a real byte-level decode of a
resource-embedded fixture without needing the 9MB production blob.

This is scaffolding for M0 (tasks.md §M0): the production `LexiconBlobFormat`/
`LexiconStore` parser (DESIGN.md §2.2) lands in M2. Re-run this script if the
fixture's expected values ever need to change; it is deterministic (no
sources/network — every value is inline below).

Usage:
  uv run make_mini_lexicon_fixture.py
  # writes ../TypoFreeCore/Tests/TypoFreeCoreTests/Fixtures/mini-lexicon.bin
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

MAGIC = b"TFX1"
FORMAT_VERSION = 1
SCHEME_ID = 1  # flypy, must match TFX1 header convention (DESIGN.md §2.2)

# key -> [(word, rawCount), ...] already in the on-disk order (descending
# rawCount, ties broken by insertion order here). Keys below are kept in
# strict ascending ASCII byte order, matching the real build's invariant.
ENTRIES: list[tuple[str, list[tuple[str, int]]]] = [
    ("aa", [("啊", 5000), ("阿", 120)]),
    ("hc", [("好", 8000)]),
    ("nihc", [("你好", 300)]),
]

OUT_PATH = (
    Path(__file__).resolve().parent.parent
    / "TypoFreeCore"
    / "Tests"
    / "TypoFreeCoreTests"
    / "Fixtures"
    / "mini-lexicon.bin"
)


def log_freq(raw_count: int) -> float:
    return math.log(1.0 + raw_count)


def build_blob() -> bytes:
    assert [k for k, _ in ENTRIES] == sorted(k for k, _ in ENTRIES), "keys must be ascending"

    body = bytearray()
    posting_count = 0
    for key, postings in ENTRIES:
        key_bytes = key.encode("ascii")
        assert len(key_bytes) <= 0xFF
        body += struct.pack("<B", len(key_bytes))
        body += key_bytes
        assert len(postings) <= 0xFFFF
        body += struct.pack("<H", len(postings))
        for word, raw_count in postings:
            word_bytes = word.encode("utf-8")
            assert len(word_bytes) <= 0xFF
            body += struct.pack("<B", len(word_bytes))
            body += word_bytes
            body += struct.pack("<f", log_freq(raw_count))
            posting_count += 1

    header = MAGIC + struct.pack("<HHII", FORMAT_VERSION, SCHEME_ID, len(ENTRIES), posting_count)
    return bytes(header) + bytes(body)


def main() -> None:
    blob = build_blob()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_bytes(blob)
    print(f"wrote {len(blob)} bytes -> {OUT_PATH}")
    print(f"keyCount={len(ENTRIES)} postingCount={sum(len(p) for _, p in ENTRIES)}")
    for key, postings in ENTRIES:
        rendered = ", ".join(f"{w}(logFreq={log_freq(c):.6f})" for w, c in postings)
        print(f"  {key!r}: {rendered}")


if __name__ == "__main__":
    main()
