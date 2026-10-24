import Foundation
import Testing

@testable import whitenoise_ios

@MainActor
@Suite struct ConversationSourcePreferenceTests {
    @Test func defaultsToNativeChats() throws {
        let suite = "ConversationSourcePreferenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ConversationSourcePreference(defaults: defaults).showsSharedChats)
    }

    @Test func selectionSurvivesReopeningSettingsAndCanReturnToNative() throws {
        let suite = "ConversationSourcePreferenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = ConversationSourcePreference(defaults: defaults)
        preference.setShowsSharedChats(true)
        #expect(preference.showsSharedChats)
        let reopened = ConversationSourcePreference(defaults: defaults)
        #expect(reopened.showsSharedChats)
        reopened.setShowsSharedChats(false)
        #expect(!ConversationSourcePreference(defaults: defaults).showsSharedChats)
    }

    @Test func displayChoicePreservesOtherPreferences() throws {
        let suite = "ConversationSourcePreferenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unchanged", forKey: "test.accountSentinel")
        let preference = ConversationSourcePreference(defaults: defaults)
        preference.setShowsSharedChats(true)
        preference.setShowsSharedChats(true)
        preference.setShowsSharedChats(false)
        #expect(defaults.string(forKey: "test.accountSentinel") == "unchanged")
    }
}
