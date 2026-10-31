import Foundation

public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case same, added, removed }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
}

public enum TextDiff {
    /// Line based diff using longest-common-subsequence. Large inputs fall back to a trimmed comparison.
    public static func diff(old: String, new: String, maxCells: Int = 4_000_000) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")

        // Trim common prefix / suffix to keep the LCS table small.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let am = Array(a[prefix..<(a.count - suffix)])
        let bm = Array(b[prefix..<(b.count - suffix)])

        var ops: [(DiffLine.Kind, String)] = []
        for i in 0..<prefix { ops.append((.same, a[i])) }

        if am.count * bm.count <= maxCells {
            let n = am.count, m = bm.count
            var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i][j] = am[i] == bm[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if am[i] == bm[j] {
                    ops.append((.same, am[i])); i += 1; j += 1
                } else if table[i + 1][j] >= table[i][j + 1] {
                    ops.append((.removed, am[i])); i += 1
                } else {
                    ops.append((.added, bm[j])); j += 1
                }
            }
            while i < n { ops.append((.removed, am[i])); i += 1 }
            while j < m { ops.append((.added, bm[j])); j += 1 }
        } else {
            for line in am { ops.append((.removed, line)) }
            for line in bm { ops.append((.added, line)) }
        }

        for i in (a.count - suffix)..<a.count { ops.append((.same, a[i])) }

        var result: [DiffLine] = []
        var oldNo = 1, newNo = 1
        for (index, (kind, text)) in ops.enumerated() {
            switch kind {
            case .same:
                result.append(DiffLine(id: index, kind: kind, text: text, oldLine: oldNo, newLine: newNo))
                oldNo += 1; newNo += 1
            case .removed:
                result.append(DiffLine(id: index, kind: kind, text: text, oldLine: oldNo, newLine: nil))
                oldNo += 1
            case .added:
                result.append(DiffLine(id: index, kind: kind, text: text, oldLine: nil, newLine: newNo))
                newNo += 1
            }
        }
        return result
    }
}
