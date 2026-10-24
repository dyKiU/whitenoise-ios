import Foundation
import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // The original-call counters are the only state crossing SDK protocol actor boundaries.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class PaneConsentOriginal: HistoryConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var approvals = 0
        var approvalCount: Int { lock.withLock { approvals } }
        func snapshot() async throws -> HistoryTransferSnapshotFfi {
            .init(
                revision: 19, importedRecords: 0, complete: false, groupIdHex: "0102",
                sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
                snapshotTimestampCeiling: 1_760_000_000, recordCount: 3, encodedBytes: 8192, fragmentCount: 2)
        }
        func approve(revision: UInt64) async throws { lock.withLock { approvals += 1 } }
        func cancel() {}
    }
    @MainActor final class HistoryConsentReviewPaneTests: XCTestCase {
        func testVisibleReviewLoadsExactOriginalMetadataWithoutApproving() async throws {
            let original = PaneConsentOriginal()
            let scope = NativeHistoryConsentScope(original: original)
            let model = HistoryConsentReviewModel(loadOriginals: { [scope] }, isCurrent: { true })
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(NavigationStack { HistoryConsentReviewView(model: model) }))
            weak let retiredHost = host
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                model.invalidate()
                scope.cancel()
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            host?.view.layoutIfNeeded()
            for _ in 0..<50 where model.scopes.isEmpty || model.isWorking {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.scopes.count, 1)
            XCTAssertFalse(model.failed)
            try await model.select(id: scope.id)
            XCTAssertEqual(model.review?.revision, 19)
            XCTAssertEqual(model.review?.sourceDevice, Data(repeating: 1, count: 32))
            XCTAssertEqual(model.review?.recordCount, 3)
            XCTAssertEqual(original.approvalCount, 0)
            host?.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "original-history-recipient-review"
            attachment.lifetime = .keepAlways
            add(attachment)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(
                "original-history-recipient-review.png")
            try XCTUnwrap(image.pngData()).write(to: output)
            // Retire the complete host before its injected MainActor owners leave this task.
            host?.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            host = nil
            previous?.makeKey()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while retiredHost != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(retiredHost, "The retired pane must release its hosted graph before the next test")
            withExtendedLifetime((model, scope)) {}
        }
        func testFingerprintAndCutoffFormattingDoNotAlterAuthenticatedValues() {
            let fingerprint = HistoryConsentReviewPresentation.fingerprint(Data(repeating: 1, count: 32))
            XCTAssertEqual(fingerprint.replacingOccurrences(of: " ", with: ""), String(repeating: "01", count: 32))
            XCTAssertEqual(fingerprint.split(separator: " ").count, 8)
            XCTAssertEqual(HistoryConsentReviewPresentation.date(1_760_000_000).timeIntervalSince1970, 1_760_000_000)
        }
    }
#endif
