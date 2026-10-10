#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    struct HistoryConsentReviewEntryView: View {
        @State private var model: HistoryConsentReviewModel?
        @State private var failed = false
        let acquire: @MainActor () throws -> HistoryConsentReviewModel
        init(model: HistoryConsentReviewModel?, acquire: @escaping @MainActor () throws -> HistoryConsentReviewModel) {
            _model = State(initialValue: model)
            self.acquire = acquire
        }
        var body: some View {
            Group {
                if let model, model.isActive {
                    HistoryConsentReviewView(model: model)
                } else {
                    Form {
                        if failed { Text("History request unavailable. Retry or cancel.").foregroundStyle(.red) }
                        WNButton(title: "Try again", emphasis: .secondary, size: .standard) { attach() }
                    }.task { attach() }
                }
            }.localizedNavigationTitle("History transfer")
        }
        private func attach() {
            do {
                model = try acquire()
                failed = false
            } catch { failed = true }
        }
    }

    struct HistoryConsentReviewView: View {
        let model: HistoryConsentReviewModel
        @State private var action: Task<Void, Never>?
        @State private var failed = false
        var body: some View {
            Form {
                if model.isActive {
                    Section {
                        if model.scopes.isEmpty, !model.isWorking, !model.failed {
                            Text("No pending history requests.")
                        }
                        ForEach(model.scopes) { scope in
                            Button {
                                let id = scope.id
                                perform { try await model.select(id: id) }
                            } label: {
                                if let review = scope.review {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Source device key").font(.caption).foregroundStyle(.secondary)
                                        Text(
                                            verbatim: HistoryConsentReviewPresentation.fingerprint(review.sourceDevice)
                                        )
                                        .font(.system(.caption, design: .monospaced))
                                        Text(
                                            HistoryConsentReviewPresentation.date(review.snapshotTimestampCeiling),
                                            format: .dateTime.year().month().day())
                                        LabeledContent("Records", value: review.recordCount.formatted())
                                    }
                                } else {
                                    Text("History request unavailable. Retry or cancel.")
                                }
                            }.disabled(model.isWorking || !scope.isActive)
                        }
                        WNButton(title: "Refresh", emphasis: .secondary, size: .standard, isLoading: model.isWorking) {
                            perform { try await model.loadPending() }
                        }.disabled(model.isWorking)
                    }
                    if let selected = model.selected {
                        if let review = model.review {
                            HistoryConsentReviewDetails(review: review)
                            Section {
                                WNButton(title: "Approve", size: .standard, isLoading: model.isWorking) {
                                    let revision = review.revision
                                    perform { try await model.approve(displayedRevision: revision) }
                                }.disabled(model.isWorking || !selected.isActive || review.complete)
                            }
                        }
                        Section {
                            WNButton(title: "Cancel", emphasis: .secondary, size: .standard) {
                                action?.cancel()
                                model.cancelSelected()
                            }.disabled(!selected.isActive)
                        }
                    }
                    if model.failed || failed {
                        Text("History request unavailable. Retry or cancel.").foregroundStyle(.red)
                    }
                } else {
                    Text("History request unavailable. Retry or cancel.")
                }
            }
            .task { perform { try await model.loadPending() } }
            .onDisappear { action?.cancel() }
            .onChange(of: model.isActive) { _, active in if !active { action?.cancel() } }
        }
        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            guard model.isActive, !model.isWorking else { return }
            failed = false
            action = Task {
                do { try await operation() } catch {
                    if model.isActive, !Task.isCancelled { failed = true }
                }
            }
        }
    }

    struct HistoryConsentReviewDetails: View {
        let review: HistoryTransferSnapshotFfi
        var body: some View {
            Section {
                key("Source device key", value: review.sourceDevice)
                key("Receiving device key", value: review.recipientDevice)
                LabeledContent("Chat ID") { Text(verbatim: review.groupIdHex).font(.caption.monospaced()) }
                LabeledContent("Snapshot through") {
                    Text(
                        HistoryConsentReviewPresentation.date(review.snapshotTimestampCeiling),
                        format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent("Records", value: review.recordCount.formatted())
                LabeledContent("Imported records", value: review.importedRecords.formatted())
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(review.encodedBytes), countStyle: .file))
            } footer: {
                Text(
                    "These records are attested by the source device and are separate from live authenticated messages."
                )
            }
        }
        private func key(_ title: LocalizedStringKey, value: Data) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: HistoryConsentReviewPresentation.fingerprint(value))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    enum HistoryConsentReviewPresentation {
        static func fingerprint(_ key: Data) -> String {
            key.enumerated().map { index, byte in
                (index > 0 && index % 4 == 0 ? " " : "") + String(format: "%02x", byte)
            }.joined()
        }
        static func date(_ ceiling: UInt64) -> Date { Date(timeIntervalSince1970: TimeInterval(ceiling)) }
    }

    #Preview("Incoming history") {
        HistoryConsentReviewView(model: .init(loadOriginals: { [] }, isCurrent: { true }))
    }
    #Preview("History entry") {
        HistoryConsentReviewEntryView(
            model: nil,
            acquire: {
                .init(loadOriginals: { [] }, isCurrent: { true })
            })
    }
    #Preview("History review") {
        Form {
            HistoryConsentReviewDetails(
                review: .init(
                    revision: 1, importedRecords: 0, complete: false,
                    groupIdHex: "0102", sourceDevice: Data(repeating: 1, count: 32),
                    recipientDevice: Data(repeating: 2, count: 32),
                    snapshotTimestampCeiling: 1_760_000_000, recordCount: 3, encodedBytes: 8192, fragmentCount: 2))
        }
    }
#endif
