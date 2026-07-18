# TypoFree — LOCKED DECISIONS (authoritative override of EXPLORE.md)

> Read `EXPLORE.md` for full evidence/appendices. Where this file conflicts with
> EXPLORE.md, **this file wins** (name change + MLX-primary are the two big overrides).
> Date 2026-07-18.

## Identity
- **Product / IME name**: **TypoFree** (EXPLORE.md's "CraneIME" is dead — global rename).
- **Bundle id**: `com.soleilyu.typofree`
- **Module name** (PRODUCT_MODULE_NAME): `TypoFree`
- **IMKInputController class**: `TypoFreeInputController` → `InputMethodServerControllerClass = $(PRODUCT_MODULE_NAME).TypoFreeInputController`
- **InputMethodConnectionName**: `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection` (i.e. `com.soleilyu.typofree_Connection`)
- **TISInputSourceID / mode**: `com.soleilyu.typofree.mode.shuangpin`
- **Menu display**: "TypoFree" with 小鹤双拼 subtitle.
- **Repo dir**: `labs/typofree/`

## Target machine (LLM hard boundary)
- **Apple Silicon (M1+), 8 GB RAM, macOS 26.x.** This is the deployment target.
- **Dev/build machine**: this box = MacBook Pro M2 Pro, 32 GB, macOS 26.4.1, Xcode 26.4, Swift 6.3. Builds + MLX testing happen here; the 8 GB ceiling is the design constraint, not the dev box.
- **Verified on dev machine (2026-07-18)**: `SystemLanguageModel.default.availability == .unavailable(.appleIntelligenceNotEnabled)`, system locale `zh_CN`, languages `zh-Hans-CN`. ⇒ **FoundationModels is NOT testable on the dev machine.** MLX is the only locally-exercisable backend. Design so FM is optional and gracefully absent; all local testing targets the MLX path.

## LLM backend (Q2 answer = "MLX 为主 + FM 自动探测") — OVERRIDES EXPLORE.md
- **MLX is v1 IN, PRIMARY, load-bearing** (EXPLORE.md had it OUT/deferred — overridden).
- Default backend resolution at runtime, all behind `LLMCorrectionProvider` protocol:
  1. If `SystemLanguageModel.default.isAvailable` → **FoundationModelsProvider** (≈0 MB in-process, preferred when present).
  2. Else if MLX model present/downloadable → **MLXProvider** (Qwen3-0.6B-4bit, `enable_thinking:false`), **on-demand load + idle unload (~10–15 min)**, never resident at idle.
  3. Else → **NullProvider** (Candidate #1 = engineBest; LLM feature silently inert).
- **MLX model delivery**: download on first enable (HuggingFace `mlx-community/Qwen3-0.6B-4bit`, fallback `hf-mirror.com` — both reachable 200), cache under Application Support; keep the `.app` small (do NOT bundle the weights). Progress UI on first fetch.
- Memory budget: MLX ~500–650 MB **only while loaded**; FM ~0 MB in-process. Loaded state must be transient on 8 GB.
- Package: `ml-explore/mlx-swift-lm` (MIT). Reference usage: `mlx-swift-examples/.../LLMEvaluator.swift`.

## Privacy posture (Q3 answer = "默认全开 + 一键清除")
- Context-capture **and** learning loop **default ON** (secure-field always excluded).
- Secure-field double guard: `IsSecureEventInputEnabled()` (dynamic) + AX subrole/roleDescription wide marker table (static, incl. CVV/OTP).
- Learning stores only short spans (**≤20 chars**), never full field contents; zero telemetry, all local.
- Ship day 1: "清除学习数据" (clear learned dictionary) control + a plain local-only / no-telemetry statement in Settings.

## Architecture invariants (from EXPLORE.md decision table, still in force)
- **Unsandboxed**, Developer ID sign + notarize for distribution; ad-hoc signing OK for local dev/install. App Sandbox ⨯ AX API are mutually exclusive — do NOT design sandboxed.
- Core lattice/Viterbi/lexicon 100% **scheme-agnostic**; `SchemeDefinition` data drives decoding; v1 ships only 小鹤 (flypy). Decode is joint `(initialClass, finalKey) → final` + a 35-entry zero-initial table (see EXPLORE Appendix A — the 8 counter-intuitive zero-initial spellings are mandatory test cases).
- conversion = unigram Viterbi word-lattice + length bonus, **full recompute per keystroke**, no bigram, no incremental (sub-ms; libpinyin bigram is GPLv3 — excluded).
- base lexicon = offline-compiled **binary blob** → in-memory `[String:[(word,freq)]]`; user dict = `userdict.sqlite` (WAL) additive log-boost overlay.
- Candidate window = **self-drawn NSPanel** (not IMKCandidates); slot #1 must update **asynchronously** when the LLM result lands (100 ms–2 s late) without blocking typing.
- IMK layer via **vChewing/IMKSwift (MIT)**, `@MainActor`; context fetch is sync on MainActor, LLM call hops OFF MainActor (`await`) then back — **never** block the client's typing thread.
- send-detection = **polling + identity-signature** `{bundleId,pid,role,subrole,roundedFrame}`, NOT AXObserver push; AX calls set ~50 ms messaging timeout; "element unresolved" == "empty string" == session end.
- diff→learn = char Myers diff + reject gate (edit-ratio > 0.5 or length-delta > 0.6 → discard) + occurrence ≥ 2 before affecting ranking.
- LLM output safety = `@Generable` single-field constrained decode + deterministic re-pinyinize + length ±1 gate; on failure silently fall back to engineBest.

## Lexicon (EXPLORE Appendix B)
- essay.txt (rime-essay, LGPL-3.0, 442,696 word+freq) + large_pinyin.txt (phrase-pinyin-data, MIT, word→syllables) + pinyin.txt (pinyin-data, MIT, char→pinyin). Measured 99.94% resolvable.
- Bundle the **compiled blob** + keep the build script open + in-app Acknowledgements (LGPL "means to relink" spirit). Build script uses **uv** (repo convention).

## Network facts (dev machine, 2026-07-18)
- GitHub raw + github.com: reachable. HuggingFace + hf-mirror.com: reachable (200). (services.gradle.org / Maven Central blocked — irrelevant here.)

## Design-phase user decisions (2026-07-18, answered after DESIGN.md was written — these LOCK the four "open_questions" in the design workflow output; DESIGN.md §5 said preedit was unlocked, it is now locked here)
1. **Lexicon 繁→简 (user-Q1)**: **Build-time OpenCC conversion** in `build_lexicon.py` (opencc-python-reimplemented, Apache-2.0) + merge frequencies of forms that map to the same simplified word. Output is a pure-Simplified lexicon. **Do this in M2** (同时改 build_lexicon.py 加 readings.bin 侧车), NOT M9 — re-run the build, re-verify 你好→nihc + the 8 zero-initial traps after conversion.
2. **FM `.rateLimited` policy (user-Q2)**: silently degrade to engineBest for the rest of the session; Settings toggle "限流时回落本地模型" **default OFF**. Never auto-load MLX because FM rate-limited unless the toggle is ON.
3. **Inline preedit (user-Q3)**: **hybrid** — completed syllables render as converted hanzi, incomplete trailing syllable renders as raw 小鹤 letters. `EngineResult.preeditDisplay` implements exactly this.
4. **deactivateServer mid-composition (user-Q4)**: **commit engineBest** (RIME/Squirrel behavior — never lose typed input). NEVER commit an unaccepted async LLM correction on focus loss.

## Two early spikes (must de-risk in implementation, from EXPLORE §4)
1. Minimal `IMKInputController` + FM harness, multi-hour background `respond()` → does FM `.rateLimited` fire for a background app? (If yes, MLX-primary is already the right call — de-risked by Q2.)
2. Does an `imklaunchagent`-managed bundle in `~/Library/Input Methods` obtain AX/TCC permission? No reference IME verified this combo. Spike early; core typing must never depend on AX.
