// MyersDiff — a deterministic, char-level shortest-edit-script diff.
// DESIGN.md §2.7 (diff→learn). The learning loop diffs what the IME committed
// against what the field ended up holding after the user's manual edits; the
// grouped edit script it produces is what `DiffLearner` classifies into
// homophone corrections and OOV insertions.
//
// This is Myers' O(ND) greedy algorithm ("An O(ND) Difference Algorithm and Its
// Variations", 1986): find the shortest edit script by advancing furthest-
// reaching D-paths, snapshot the search frontier at every D, then backtrack that
// trace to recover the concrete moves. The greedy k-loop tie-break (prefer a
// "down"/insert move when the neighbour below reaches at least as far) is fixed,
// so the same (old, new) pair always yields byte-identical output — the learning
// loop must be reproducible.
public enum MyersDiff {
    /// One run of the grouped edit script. `equal` chars appear in both inputs;
    /// `insert` chars are present only in `new` (`b`); `delete` chars are present
    /// only in `old` (`a`). Consecutive same-kind atoms are merged into one run,
    /// so a substitution surfaces as an adjacent delete-run / insert-run pair.
    public enum Operation: Sendable, Equatable {
        case equal([Character])
        case insert([Character])
        case delete([Character])
    }

    /// The grouped shortest edit script transforming `old` into `new`.
    public static func diff(_ old: [Character], _ new: [Character]) -> [Operation] {
        group(shortestEditScript(old, new))
    }

    /// Convenience for callers that hold strings.
    public static func diff(_ old: String, _ new: String) -> [Operation] {
        diff(Array(old), Array(new))
    }

    // MARK: - Shortest edit script (Myers O(ND))

    private enum Atom: Equatable {
        case equal(Character)
        case insert(Character)
        case delete(Character)
    }

    private static func shortestEditScript(_ a: [Character], _ b: [Character]) -> [Atom] {
        let n = a.count, m = b.count
        if n == 0 { return b.map { .insert($0) } }
        if m == 0 { return a.map { .delete($0) } }

        let maxD = n + m
        let offset = maxD                      // shift k (∈ [-maxD, maxD]) into [0, 2·maxD]
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        var trace: [[Int]] = []
        var foundD = -1

        search: for d in 0...maxD {
            trace.append(v)                    // frontier BEFORE extending to this D
            var k = -d
            while k <= d {
                // Choose the move that reaches furthest: down (insert, x carries
                // over) vs right (delete, x advances). At the k-band edges only one
                // is legal.
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]      // down → insert b[y]
                } else {
                    x = v[offset + k - 1] + 1  // right → delete a[x]
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {   // slide the diagonal (equal run)
                    x += 1; y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m { foundD = d; break search }
                k += 2
            }
        }

        // Backtrack the trace from (n, m) to (0, 0), recording moves in reverse.
        var edits: [Atom] = []
        var x = n, y = m
        var d = foundD
        while d > 0 {
            let vPrev = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vPrev[offset + k - 1] < vPrev[offset + k + 1]) {
                prevK = k + 1                  // came from a down move
            } else {
                prevK = k - 1                  // came from a right move
            }
            let prevX = vPrev[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {        // unwind the diagonal (equal chars)
                edits.append(.equal(a[x - 1])); x -= 1; y -= 1
            }
            if x == prevX {
                edits.append(.insert(b[y - 1]))   // down move consumed b[y-1]
            } else {
                edits.append(.delete(a[x - 1]))   // right move consumed a[x-1]
            }
            x = prevX; y = prevY
            d -= 1
        }
        while x > 0, y > 0 {                    // drain the initial (D=0) diagonal
            edits.append(.equal(a[x - 1])); x -= 1; y -= 1
        }
        return edits.reversed()
    }

    // MARK: - Grouping

    private static func group(_ atoms: [Atom]) -> [Operation] {
        var ops: [Operation] = []
        for atom in atoms {
            switch atom {
            case .equal(let c):  append(c, to: &ops, kind: .equalKind)
            case .insert(let c): append(c, to: &ops, kind: .insertKind)
            case .delete(let c): append(c, to: &ops, kind: .deleteKind)
            }
        }
        return ops
    }

    private enum Kind { case equalKind, insertKind, deleteKind }

    private static func append(_ c: Character, to ops: inout [Operation], kind: Kind) {
        // Extend the trailing run when it is the same kind, else open a new run.
        if let last = ops.last {
            switch (kind, last) {
            case (.equalKind, .equal(let cs)):   ops[ops.count - 1] = .equal(cs + [c]);  return
            case (.insertKind, .insert(let cs)): ops[ops.count - 1] = .insert(cs + [c]); return
            case (.deleteKind, .delete(let cs)): ops[ops.count - 1] = .delete(cs + [c]); return
            default: break
            }
        }
        switch kind {
        case .equalKind:  ops.append(.equal([c]))
        case .insertKind: ops.append(.insert([c]))
        case .deleteKind: ops.append(.delete([c]))
        }
    }
}
