import Foundation
import ClaudeLightsCore

final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var errorText: String?
}
