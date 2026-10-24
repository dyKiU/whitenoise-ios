import Foundation
@testable import whitenoise_ios

extension AppState {
    @MainActor static func test(
        client: MarmotClient? = nil,
        notifications: AppNotifications? = nil,
        conversationDraftStore: ConversationDraftStore? = nil,
        signUpDraftStore: SignUpDraftStore? = nil,
        accountDefaults: UserDefaults = .standard,
        erasureDefaults: UserDefaults? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = TelemetryBuildConfig.current(),
        runtimeClientFactory: @escaping RuntimeLifecycle.RuntimeClientFactory = RuntimeLifecycle.defaultRuntimeClientFactory,
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = { delay in try await Task.sleep(for: delay) },
        runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground
    ) -> AppState {
        let resolvedNotifications: AppNotifications
        if let notifications {
            resolvedNotifications = notifications
        } else {
            resolvedNotifications = .shared
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignUpDraftTests-\(UUID())", isDirectory: true)
        return AppState(
            client: client,
            notifications: resolvedNotifications,
            conversationDraftStore: conversationDraftStore,
            signUpDraftStore: signUpDraftStore ?? SignUpDraftStore(directory: directory),
            accountDefaults: accountDefaults,
            erasureDefaults: erasureDefaults,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig,
            runtimeClientFactory: runtimeClientFactory,
            runtimeRetrySleeper: runtimeRetrySleeper,
            runtimeConstructionRetryPolicy: runtimeConstructionRetryPolicy
        )
    }
}
