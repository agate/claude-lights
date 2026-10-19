import Foundation

/// What closing a session removes besides its Claude process.
public enum CloseTarget: Equatable, Sendable {
    /// Claude's own tmux pane (`%N`); other panes of the window stay.
    case tmuxPane(id: String)
    /// Claude's own herdr pane.
    case herdrPane(id: String)
    /// The iTerm2 / Terminal tab whose tty is Claude's own (not in tmux).
    case terminalTab(tty: String)
    /// Nothing to remove (e.g. VS Code): only the process ends.
    case processOnly

    public static func `for`(_ session: Session) -> CloseTarget {
        if let pane = session.tmuxPane { return .tmuxPane(id: pane) }
        if let pane = session.herdrPane { return .herdrPane(id: pane) }
        if let tty = session.tty { return .terminalTab(tty: tty) }
        return .processOnly
    }

    /// Plain-words sentence for the confirmation alert and the ⌥ menu row.
    public func description(for session: Session) -> String {
        switch self {
        case .tmuxPane:
            let place = [session.tmuxSession, session.tmuxWindow].compactMap { $0 }.joined(separator: ":")
            let named = place.isEmpty ? "" : " (\(place))"
            return "Claude will be stopped and its tmux pane\(named) closed. Other panes in that window stay open."
        case .herdrPane:
            return "Claude will be stopped and its herdr pane closed."
        case .terminalTab:
            return "Claude will be stopped and its terminal tab closed."
        case .processOnly:
            return "Claude will be stopped. Its window is left open."
        }
    }
}

public extension Session {
    /// Where the session runs, for the bar's context menu.
    var locationLine: String {
        if let tmuxSession, let tmuxWindow {
            let index = tmuxPaneIndex.map { ".\($0)" } ?? ""
            return "tmux: \(tmuxSession):\(tmuxWindow)\(index)"
        }
        if let herdrPane { return "herdr: \(herdrPane)" }
        return tty == nil ? "No terminal" : "Terminal tab"
    }
}
