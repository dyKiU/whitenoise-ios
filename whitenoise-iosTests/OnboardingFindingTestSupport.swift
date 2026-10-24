import MarmotKit

/// Preserve fixture meaning across published and verified current SDK cohorts.
nonisolated func onboardingTestFinding(
    issue: OnboardingIssueFfi,
    endpoint: String?
) -> OnboardingFindingFfi {
    #if WN_CURRENT_SDK_API
        return OnboardingFindingFfi(
            issue: issue,
            endpoint: endpoint,
            context: .unknown,
            purpose: .unknown,
            outcome: .unknown,
            declaredCapability: .none,
            actions: [],
            observedRevision: nil
        )
    #else
        return OnboardingFindingFfi(issue: issue, endpoint: endpoint)
    #endif
}
