import Foundation

/// Small line-based edits to config.toml that keep your comments and layout.
/// Used by the bar's own controls (theme picker, icon style switch); the
/// config watcher then reloads the file as if you had edited it.
public enum ConfigEditor {
    /// Sets `key = value` in `[table]` (nil: the top level, before any table).
    /// `value` is a TOML literal, e.g. `"\"nord\""` or `"true"`.
    public static func set(_ key: String, _ value: String, table: String? = nil, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let line = "\(bareKey(key)) = \(value)"

        // The section's range: from after its header to the next header.
        var start = 0
        if let table {
            guard let header = lines.firstIndex(where: { tableName($0) == table }) else {
                if !lines.isEmpty && lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false { lines.append("") }
                lines += ["[\(table)]", line]
                return lines.joined(separator: "\n") + "\n"
            }
            start = header + 1
        }
        let end = lines[start...].firstIndex(where: { tableName($0) != nil }) ?? lines.count

        if let i = lines[start..<end].firstIndex(where: { keyName($0) == key }) {
            let comment = trailingComment(lines[i])
            lines[i] = line + (comment.map { "  \($0)" } ?? "")
        } else if table == nil {
            // Before the first table, after any leading comments.
            let at = lines[start..<end].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? end
            lines.insert(line, at: at)
        } else {
            lines.insert(line, at: start)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes `key` from `[table]` (nil: the top level). No-op when absent.
    public static func remove(_ key: String, table: String? = nil, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var start = 0
        if let table {
            guard let header = lines.firstIndex(where: { tableName($0) == table }) else { return text }
            start = header + 1
        }
        let end = lines[start...].firstIndex(where: { tableName($0) != nil }) ?? lines.count
        guard let i = lines[start..<end].firstIndex(where: { keyName($0) == key }) else { return text }
        lines.remove(at: i)
        return lines.joined(separator: "\n")
    }

    /// Edits the file in place (creating it when missing). A nil `value`
    /// removes the key.
    public static func update(_ key: String, _ value: String?, table: String? = nil, file: URL = GizmoPaths.configFile) throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = value.map { set(key, $0, table: table, in: text) } ?? remove(key, table: table, in: text)
        try out.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Quotes keys that aren't bare TOML keys, like bundle IDs with dots.
    static func bareKey(_ key: String) -> String {
        let bare = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return key.unicodeScalars.allSatisfy(bare.contains) ? key : string(key)
    }

    /// A quoted TOML string.
    public static func string(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func tableName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
    }

    private static func keyName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return String(t[..<eq]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// A `# comment` after the value, outside any quotes.
    private static func trailingComment(_ line: String) -> String? {
        var inString = false, escaped = false
        for i in line.indices {
            let c = line[i]
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString { return String(line[i...]) }
        }
        return nil
    }
}
