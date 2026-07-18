// M0 scaffold placeholder.
//
// The real `SchemeDefinition` (DESIGN.md §2.1) carries the full flypy
// Appendix-A data: 21-key `keyToInitial`, `InitialClass` 5-way split, the
// joint `(initialClass, finalKey) -> final` table, the 35-entry zero-initial
// table, and the precondition-checked reverse tables for `encode`. That is
// M1's job (tasks.md §M1), together with `FlypyScheme.flypy` and
// `ShuangpinDecoder`.
//
// This stub exists only so the `Scheme/` module location + a `Sendable`
// value type compile and are exercised by a green swift test before M1
// replaces this file wholesale. Nothing else in M0 depends on its shape.
public struct SchemeDefinition: Sendable, Equatable {
    /// Must equal the TFX1 lexicon blob header's `schemeId` for the base
    /// lexicon to be usable with this scheme (flypy = 1, DESIGN.md §2.2).
    public let schemeId: UInt16
    public let displayName: String

    public init(schemeId: UInt16, displayName: String) {
        self.schemeId = schemeId
        self.displayName = displayName
    }
}
