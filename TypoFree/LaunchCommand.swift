import Foundation

// The argv dispatch table (DESIGN §1). Pure + `Equatable` so it is unit-tested
// in `TypoFreeTests` without launching the app or touching TIS. Mirrors the
// squirrel/Fire installer argument shape (mechanism only — no GPL code copied).
enum LaunchCommand: Equatable {
    case run                    // no args → launch the IME server + menu bar app
    case quit                   // --quit → terminate any running instance (dev loop)
    case register               // --register-input-source / --install → TISRegister
    case enable                 // --enable-input-source → TISEnable
    case select                 // --select-input-source → TISSelect (dev only; never on normal launch)
    case verify                 // --verify / --status → print + exit-code the registration state
    case help                   // --help / -h
    case unknown(String)

    static func parse(_ arguments: [String]) -> LaunchCommand {
        guard arguments.count > 1 else { return .run }
        switch arguments[1] {
        case "--quit": return .quit
        case "--register-input-source", "--install": return .register
        case "--enable-input-source": return .enable
        case "--select-input-source": return .select
        case "--verify", "--status": return .verify
        case "--help", "-h": return .help
        default: return .unknown(arguments[1])
        }
    }
}
