import Foundation
import Observation

/// A device-local display choice. Changing it never changes chat sharing or membership.
@MainActor
@Observable
final class ConversationSourcePreference {
    static let shared = ConversationSourcePreference()
    static let storageKey = "chats.showSharedConversations"
    private let defaults: UserDefaults
    private(set) var showsSharedChats: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsSharedChats = defaults.bool(forKey: Self.storageKey)
    }

    func setShowsSharedChats(_ enabled: Bool) {
        guard showsSharedChats != enabled else { return }
        defaults.set(enabled, forKey: Self.storageKey)
        showsSharedChats = enabled
    }
}
