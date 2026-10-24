import MarmotKit
import SwiftUI

/// The conversation supplies its original account/chat factory, never archive permission.
struct SynchronizedHistoryConversationEntry: View {
    let makeModel: () throws -> SynchronizedHistoryViewModel
    let releaseModel: (SynchronizedHistoryViewModel) -> Void
    @State private var model: SynchronizedHistoryViewModel?
    @State private var failed = false
    @State private var isPresented = false

    private func acquire() {
        do {
            model = try makeModel()
            failed = false
        } catch {
            model = nil
            failed = true
        }
    }

    var body: some View {
        HStack {
            Spacer()
            if failed {
                Text("Could not load synchronized history.").font(.caption)
                Button("Try again") { acquire() }
            } else {
                Button("Synchronized history", systemImage: "clock.arrow.circlepath") { isPresented = true }
                    .disabled(model?.isCurrentOwner != true)
                    .accessibilityIdentifier("conversation.synchronizedHistory.open")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .task { acquire() }
        .onDisappear {
            if let model { releaseModel(model) }
            model = nil
        }
        .sheet(isPresented: $isPresented) {
            if let model { SynchronizedHistoryView(model: model) }
        }
    }
}

struct SynchronizedHistoryView: View {
    let model: SynchronizedHistoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "These records are attested by the source device and are separate from live authenticated messages."
                    )
                    .foregroundStyle(.secondary)
                }
                if model.readFailed {
                    Text("Could not load synchronized history.")
                } else if !model.isLoading && model.records.isEmpty {
                    Text("No messages").foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(model.records) { record in
                        SynchronizedHistoryRecordView(record: record, referenceDate: context.date)
                    }
                }
                .accessibilityIdentifier("conversation.synchronizedHistory.records")
                HStack {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        if model.readFailed { Text("Retry") } else { Text("Refresh") }
                    }
                    .disabled(model.isLoading || !model.isCurrentOwner)
                    if model.isLoading { ProgressView() }
                    Spacer()
                    Button("Next") { Task { await model.loadNextPage() } }
                        .disabled(model.isLoading || !model.hasMore || !model.isCurrentOwner || model.readFailed)
                }
            }
            .navigationTitle("Synchronized history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
            .task { await model.reload() }
        }
    }
}

private struct SynchronizedHistoryRecordView: View {
    let record: SynchronizedHistoryRecord
    let referenceDate: Date

    private func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: IdentityPresentation.text(accountIdHex: record.authorPubkey))
                    .font(.caption).lineLimit(1)
                Spacer()
                Text(Date(timeIntervalSince1970: Double(record.createdAt)), style: .date).font(.caption)
            }
            switch SynchronizedHistoryPresentation.contentState(record, referenceDate: referenceDate) {
            case .deleted: Text("Message deleted").foregroundStyle(.secondary)
            case .expired: Text("Message expired").foregroundStyle(.secondary)
            case .visible:
                Text(verbatim: record.content).textSelection(.enabled)
                ForEach(Array(record.mediaAttachments.enumerated()), id: \.offset) { _, attachment in
                    SynchronizedHistoryAttachmentView(attachment: attachment)
                }
            }
            DisclosureGroup("Source provenance") {
                LabeledContent("Source device key") { Text(verbatim: hex(record.sourceDevice)).textSelection(.enabled) }
                LabeledContent("History transfer") { Text(verbatim: hex(record.transferId)).textSelection(.enabled) }
                LabeledContent("Manifest digest") { Text(verbatim: hex(record.manifestDigest)).textSelection(.enabled) }
                Text(verbatim: record.id).textSelection(.enabled)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}

private struct SynchronizedHistoryAttachmentView: View {
    let attachment: MediaAttachmentOutcomeFfi

    var body: some View {
        switch attachment {
        case .accepted(_, let reference):
            VStack(alignment: .leading) {
                Label("Attachment", systemImage: "paperclip")
                Text(verbatim: ContentSanitizer.displayName(reference.fileName) ?? L10n.string("Attachment"))
                Text("Attachment availability has not been verified on this device.").foregroundStyle(.secondary)
            }.font(.caption)
        case .rejected:
            Label("Attachment unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview("History") {
    SynchronizedHistoryView(
        model: SynchronizedHistoryViewModel(accountRef: "preview", groupIdHex: "preview") { _, _, _, _ in
            .init(records: [], nextMessageId: nil)
        })
}
#Preview("Entry") {
    SynchronizedHistoryConversationEntry(
        makeModel: {
            SynchronizedHistoryViewModel(accountRef: "preview", groupIdHex: "preview") { _, _, _, _ in
                .init(records: [], nextMessageId: nil)
            }
        }, releaseModel: { $0.invalidate() })
}
#Preview("Record") {
    SynchronizedHistoryRecordView(
        record: .init(
            id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 1, expiresAt: nil, deleted: false, content: "Preview history", tags: [], mediaAttachments: [],
            transferId: Data(repeating: 3, count: 32), sourceDevice: Data(repeating: 4, count: 32),
            manifestDigest: Data(repeating: 5, count: 32)), referenceDate: .now)
}
#Preview("Attachment") {
    SynchronizedHistoryAttachmentView(
        attachment: .rejected(
            attachmentIndex: 0, rejection: .init(kind: .unsupportedFormat, detail: "")))
}
