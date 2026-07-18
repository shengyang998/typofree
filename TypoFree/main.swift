import Foundation

// Entry point (DESIGN §1). A `main.swift` with top-level code IS the executable
// entry, so `TypoFreeApp` stays a plain (non-@main) `App` we invoke for the
// `.run` case. Installer sub-commands run TIS actions and exit without starting
// the app (that is how `scripts/dev.sh` registers/enables the input source).
switch LaunchCommand.parse(CommandLine.arguments) {
case .run:
    TypoFreeApp.main()
case .quit:
    TypoFreeInstaller().quitRunningInstances()
case .register:
    TypoFreeInstaller().register()
case .enable:
    TypoFreeInstaller().enable()
case .select:
    TypoFreeInstaller().select()
case .verify:
    exit(TypoFreeInstaller().verify())
case .help:
    print(TypoFreeInstaller.helpText)
case .unknown(let arg):
    FileHandle.standardError.write(Data("TypoFree: unknown argument \(arg)\n".utf8))
    exit(2)
}
