import Foundation
import MarmotKit
@testable import whitenoise_ios

/// Durable admission is not completion: dependent native actions need the same
/// worker to finish processing the exact token before using its message target.
@MainActor
enum MarmotLocalSendFixtureReadiness {
    enum Failure: Error { case missingSubmission, rejected, timedOut }

    static func waitForCompletion(client: MarmotClient, accountRef: String,
                                  groupIdHex: String, token: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            switch try await client.localSendStatus(accountRef: accountRef,
                groupIdHex: groupIdHex, clientToken: token) {
            case .completed?: return
            case .rejected?: throw Failure.rejected
            case nil: throw Failure.missingSubmission
            case .queued?, .engineOwned?:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw Failure.timedOut
    }
}
