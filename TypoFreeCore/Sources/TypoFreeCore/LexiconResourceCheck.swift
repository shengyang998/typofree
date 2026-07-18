import Foundation

/// M0 scaffold: proves the `Resources/lexicon.bin` SwiftPM resource actually
/// loads real bytes through `Bundle.module` at runtime — not just that a
/// symlink resolves when read directly from the source tree.
///
/// Landmine this guards against: the source tree originally bridged
/// `Resources/lexicon.bin` to `../../../../data/lexicon.bin` via a *relative*
/// symlink (as DESIGN.md §1 first specified). SwiftPM's resource-copy step
/// preserves symlinks as symlinks with the same relative target string
/// instead of dereferencing them — so once copied into a `.build/<triple>/
/// <config>/TypoFreeCore_TypoFreeCore.bundle/` (a different nesting depth
/// than the source tree, and a *different depth again* once embedded in an
/// Xcode app target in M5), the same `../../../../` no longer reaches
/// `data/`, producing a dangling symlink that fails at `open()`. Confirmed
/// empirically: `realpath`/`head` on the copied symlink both returned
/// "No such file or directory" even though `swift build` reported success.
///
/// Fix: the relationship was inverted. `TypoFreeCore/Sources/TypoFreeCore/
/// Resources/lexicon.bin` is now the real, git-tracked binary (so any copy
/// mechanism — clonefile, cp -a, Xcode's resource-copy build phase — just
/// works, at any nesting depth). `data/lexicon.bin` is now the symlink
/// (`-> ../TypoFreeCore/Sources/TypoFreeCore/Resources/lexicon.bin`),
/// preserving `data/` as the documented canonical build-output path.
/// `build_lexicon.py`'s `out_path.open("wb")` follows symlinks on write, so
/// rebuilding via its unchanged `--out-bin` default keeps writing straight
/// into the real file — no manual re-sync step needed.
enum LexiconResourceCheck {
    enum CheckError: Error, Equatable { case resourceNotFound }

    /// Loads the bundled `lexicon.bin` and returns its byte count + first 4
    /// bytes (expected to be the TFX1 magic once M2 lands the real parser).
    static func loadBundledLexiconHeaderProbe() throws -> (byteCount: Int, first4: [UInt8]) {
        guard let url = Bundle.module.url(forResource: "lexicon", withExtension: "bin") else {
            throw CheckError.resourceNotFound
        }
        let data = try Data(contentsOf: url)
        return (data.count, Array(data.prefix(4)))
    }
}
