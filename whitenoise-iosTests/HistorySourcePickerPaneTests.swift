import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_ios

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor final class HistorySourcePickerPaneTests: XCTestCase {
        func testHostedPickerReadsActualObservedChoiceWithoutBeginningTransfer() async throws {
            var reads = 0
            var begins = 0
            let device = Data(repeating: 2, count: 32)
            let model = HistorySourcePickerModel(
                groupIdHex: "ab",
                readRecipients: {
                    reads += 1
                    return [.init(leafIndex: 3, device: device)]
                },
                beginOriginal: { _ in
                    begins += 1
                    throw MarmotKitError.HistoryTransferNotReady
                }, isCurrent: { true })
            try await host(model: model) {
                XCTAssertEqual(reads, 1)
                XCTAssertEqual(model.recipients.map(\.device), [device])
                XCTAssertNil(model.selectedDevice)
                XCTAssertNil(model.review)
                XCTAssertEqual(begins, 0)
                XCTAssertFalse(model.failed)
            }
        }
        func testHostedFailedReadKeepsChoicesEmptyAndCannotBegin() async throws {
            var begins = 0
            let model = HistorySourcePickerModel(
                groupIdHex: "ab", readRecipients: { throw MarmotKitError.HistoryTransferRuntimeUnavailable },
                beginOriginal: { _ in
                    begins += 1
                    throw MarmotKitError.HistoryTransferNotReady
                }, isCurrent: { true })
            try await host(model: model) {
                XCTAssertTrue(model.failed)
                XCTAssertTrue(model.recipients.isEmpty)
                XCTAssertNil(model.selectedDevice)
                XCTAssertEqual(begins, 0)
            }
        }
        private func host(model: HistorySourcePickerModel, check: () -> Void) async throws {
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(HistorySourcePickerView(model: model)))
            weak var retiredHost = host
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host?.view.layoutIfNeeded()
            for _ in 0..<50 where !model.failed && model.recipients.isEmpty || model.isWorking {
                try await Task.sleep(for: .milliseconds(20))
            }
            check()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "history-source-picker"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["WN_SELECTED_CHAT_VISUAL_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try XCTUnwrap(image.pngData()).write(
                    to: URL(fileURLWithPath: directory)
                        .appendingPathComponent(model.failed ? "failed.png" : "choices.png"))
            }
            model.cancel()
            host?.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            host = nil
            previous?.makeKey()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while retiredHost != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(retiredHost)
            withExtendedLifetime(model) {}
        }
    }
#endif
