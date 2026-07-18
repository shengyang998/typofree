import Foundation
import AppKit
import InputMethodKit
import Carbon

// TypoFreeInstaller — TIS registration/enable/select for the per-user install at
// ~/Library/Input Methods/TypoFree.app (DESIGN §7). Standard `TIS*` API only; the
// mechanism mirrors squirrel/Fire but no GPL code is copied. `dev.sh` drives
// these via argv. NOTE: normal app launch NEVER calls `select` — we do not hijack
// the user's active input source (they are typing on this machine).
struct TypoFreeInstaller {
    /// The single input-source id (DECISIONS.md: `com.soleilyu.typofree.mode.shuangpin`).
    static let modeID = "com.soleilyu.typofree.mode.shuangpin"

    /// The installed bundle location (per-user, no sudo needed).
    static var installedAppURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/TypoFree.app")
    }

    // MARK: - argv actions

    func quitRunningInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.terminate()
        }
    }

    /// Register the installed bundle with Text Input Sources.
    func register() {
        let url = Self.installedAppURL
        let status = TISRegisterInputSource(url as CFURL)
        FileHandle.standardError.write(Data("TypoFree: register \(url.path) → \(status)\n".utf8))
    }

    /// Enable the shuangpin mode (idempotent — skips if already enabled).
    func enable() {
        guard let source = inputSource(id: Self.modeID) else {
            FileHandle.standardError.write(Data("TypoFree: input source not found (register first?)\n".utf8))
            return
        }
        if boolProperty(source, kTISPropertyInputSourceIsEnabled) != true {
            let status = TISEnableInputSource(source)
            FileHandle.standardError.write(Data("TypoFree: enable → \(status)\n".utf8))
        }
    }

    /// Select (make active) — dev-only; never called on normal launch.
    func select() {
        guard let source = inputSource(id: Self.modeID) else { return }
        if boolProperty(source, kTISPropertyInputSourceIsEnabled) != true { enable() }
        if boolProperty(source, kTISPropertyInputSourceIsSelectCapable) == true,
           boolProperty(source, kTISPropertyInputSourceIsSelected) != true {
            let status = TISSelectInputSource(source)
            FileHandle.standardError.write(Data("TypoFree: select → \(status)\n".utf8))
        }
    }

    /// Print + return the input source's registration/enable state (dev.sh reads
    /// the exit code). 0 = registered + enabled; 2 = registered, not enabled;
    /// 1 = not registered (may need a logout/login on first install so the input
    /// method server rescans ~/Library/Input Methods).
    func verify() -> Int32 {
        guard let source = inputSource(id: Self.modeID) else {
            FileHandle.standardError.write(Data("TypoFree: NOT registered — \(Self.modeID) absent from TISCreateInputSourceList\n".utf8))
            return 1
        }
        let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
        let selected = boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
        print("TypoFree: registered=YES enabled=\(enabled) selected=\(selected) id=\(Self.modeID)")
        return enabled ? 0 : 2
    }

    static let helpText = """
    TypoFree — 小鹤双拼 IME with an LLM-corrected Candidate #1.
    Usage:
      TypoFree                         launch the IME server + menu bar app
      TypoFree --register-input-source register the input source (dev install)
      TypoFree --enable-input-source   enable the shuangpin mode
      TypoFree --select-input-source   select it active (dev only)
      TypoFree --verify                print registration state (exit 0=enabled)
      TypoFree --quit                  quit any running instance
      TypoFree --help                  this help
    """

    // MARK: - TIS lookup helpers

    private func inputSource(id: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in list where sourceID(source) == id { return source }
        return nil
    }

    private func sourceID(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }
}
