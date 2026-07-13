import Foundation

/// Extracts a one-line human description of what a session is doing/waiting for
/// from the tail of its transcript at ~/.claude/projects/<slug>/<sessionId>.jsonl.
public enum TranscriptReader {
    public static func transcriptURL(cwd: String, sessionId: String,
                                     home: String = NSHomeDirectory()) -> URL {
        let slug = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
            .appendingPathComponent(sessionId + ".jsonl")
    }

    /// Reads at most maxBytes from the end of the file, split into whole lines.
    public static func tailLines(of url: URL, maxBytes: Int = 64 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n").map(String.init)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // drop partial first line
        return lines
    }

    /// Walks lines backwards for the newest assistant entry; returns its last
    /// text block, or the tool names it tried to use.
    public static func waitingDescription(fromJSONLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            var toolNames: [String] = []
            var lastText: String?
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = t }
                case "tool_use":
                    if let n = block["name"] as? String { toolNames.append(n) }
                default: break
                }
            }
            if let t = lastText { return truncate(t) }
            if !toolNames.isEmpty { return "Wants to run: " + toolNames.joined(separator: ", ") }
        }
        return nil
    }

    /// The AI-generated session title (the one `/resume` and `/status` show).
    /// Stored as {"type":"ai-title","aiTitle":"..."} lines appended to the
    /// transcript; the newest occurrence wins.
    public static func aiTitle(fromJSONLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard line.contains("\"ai-title\""),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let title = obj["aiTitle"] as? String, !title.isEmpty else { continue }
            return title
        }
        return nil
    }

    public static func truncate(_ s: String, max: Int = 100) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }
}
