import MarmotKit

/// Keep the same missing-publication fixture across published and private SDK cohorts.
nonisolated func missingKeyPackageNotFound(account: String) -> MarmotKitError {
    #if WN_EXPERIMENTAL_DEVICE_SYNC
    return .MissingKeyPackage(account: account, reason: .notFound)
    #else
    return .MissingKeyPackage(account: account)
    #endif
}
