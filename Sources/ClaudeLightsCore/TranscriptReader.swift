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
        guard let data = try? handle.readToEnd() else { return [] }
        // Lossy: transcripts carry binary bytes, which must not hide every line.
        let text = String(decoding: data, as: UTF8.self)
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

    /// The newest recap Claude Code wrote (`away_summary`), else the newest
    /// last prompt. Recaps are stripped of the trailing config hint and date
    /// stamp; one that is empty afterwards does not count.
    public static func sessionSummary(fromJSONLines lines: [String]) -> SessionSummary? {
        var prompt: String?
        for line in lines.reversed() {
            let isRecap = line.contains("\"away_summary\"")
            guard isRecap || (prompt == nil && line.contains("\"last-prompt\"")),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if isRecap, obj["type"] as? String == "system",
               obj["subtype"] as? String == "away_summary",
               let content = obj["content"] as? String {
                let text = stripRecap(content)
                guard !text.isEmpty else { continue }
                let date = (obj["timestamp"] as? String).flatMap(ISO8601DateFormatter.fractional.date(from:))
                return SessionSummary(kind: .recap, text: text, date: date)
            }
            if obj["type"] as? String == "last-prompt",
               let text = (obj["lastPrompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                prompt = text
            }
        }
        return prompt.map { SessionSummary(kind: .lastPrompt, text: $0, date: nil) }
    }

    /// Drops " (disable recaps in /config)" and a trailing "[2026-10-15]" or
    /// "`2026-10-17`" date stamp.
    static func stripRecap(_ content: String) -> String {
        var text = content.replacingOccurrences(of: "(disable recaps in /config)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"[\[`]\d{4}-\d{2}-\d{2}[\]`]$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Word-wraps to at most `maxLines` lines of `width` characters; words
    /// longer than a line (e.g. CJK text without spaces) are hard-split. A
    /// cut-off last line ends in "…".
    public static func wrap(_ s: String, width: Int = 50, maxLines: Int = 6) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in s.split(whereSeparator: \.isWhitespace).map(String.init) {
            var rest = word
            while !rest.isEmpty {
                let room = current.isEmpty ? width : width - current.count - 1
                if rest.count <= room {
                    current += (current.isEmpty ? "" : " ") + rest
                    rest = ""
                } else if current.isEmpty {
                    lines.append(String(rest.prefix(width)))
                    rest = String(rest.dropFirst(width))
                } else {
                    lines.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { lines.append(current) }
        guard lines.count > maxLines else { return lines }
        var kept = Array(lines.prefix(maxLines))
        kept[maxLines - 1] = String(kept[maxLines - 1].prefix(width - 1)) + "…"
        return kept
    }

    public static func truncate(_ s: String, max: Int = 100) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }
}

/// What a session is about, for the bar's context menu.
public struct SessionSummary: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case recap, lastPrompt }
    public let kind: Kind
    public let text: String
    /// When the recap was written; last-prompt lines carry no timestamp.
    public let date: Date?

    public init(kind: Kind, text: String, date: Date?) {
        self.kind = kind; self.text = text; self.date = date
    }
}

extension ISO8601DateFormatter {
    /// Transcript timestamps, e.g. "2026-10-15T16:50:23.935Z".
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
