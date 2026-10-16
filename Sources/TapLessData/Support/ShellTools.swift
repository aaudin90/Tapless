import Foundation

enum ShellTools {
    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Экранирование для POSIX shell: 'a'\''b'
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lastLines(_ s: String, maxChars: Int = 400) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        return "…" + String(t.suffix(maxChars))
    }
}
