import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_ios

@MainActor final class SynchronizedHistoryPaneTests: XCTestCase {
    func testOriginalReaderLoadsVisiblePaneWithoutCreatingTransferOrMediaAction() async throws {
        let record = SynchronizedHistoryRecord(
            id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 1_760_000_000, expiresAt: nil, deleted: false, content: "Source-attested preview record",
            tags: [],
            mediaAttachments: [.rejected(attachmentIndex: 0, rejection: .init(kind: .unsupportedFormat, detail: ""))],
            transferId: Data(repeating: 3, count: 32), sourceDevice: Data(repeating: 4, count: 32),
            manifestDigest: Data(repeating: 5, count: 32))
        let model = SynchronizedHistoryViewModel(accountRef: "isolated", groupIdHex: "chat") {
            account, group, cursor, limit in
            XCTAssertEqual(account, "isolated")
            XCTAssertEqual(group, "chat")
            XCTAssertNil(cursor)
            XCTAssertEqual(limit, 200)
            return .init(records: [record], nextMessageId: nil)
        }
        let host = UIHostingController(rootView: SynchronizedHistoryView(model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.invalidate()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        host.view.layoutIfNeeded()
        for _ in 0..<50 where model.records.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.records.map(\.id), [record.id])
        XCTAssertFalse(model.readFailed)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "source-attested-history-pane"
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("source-attested-history-pane.png")
        try XCTUnwrap(image.pngData()).write(to: output)
    }
}
