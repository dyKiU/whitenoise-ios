import Testing

@testable import whitenoise_ios

@Suite struct SourceQualifiedTimelineUnionTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64)

    @Test func ordinaryCollisionKeepsExactOrdinaryPositionAndSuppressesSourceCopy() {
        let rows = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: a, timestamp: 20)],
            paired: [.init(canonicalId: a, timestamp: 1, expiresAt: nil, visible: true)], now: 30)
        #expect(rows == [.ordinary(index: 0)])
    }

    @Test func missingRecordAppearsBetweenOrdinaryRecordsInCanonicalTimeOrder() {
        let rows = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: a, timestamp: 10), .init(canonicalId: c, timestamp: 30)],
            paired: [.init(canonicalId: b, timestamp: 20, expiresAt: nil, visible: true)], now: 40)
        #expect(rows == [.ordinary(index: 0), .paired(index: 0, canonicalId: b), .ordinary(index: 1)])
    }

    @Test func equalTimesUseCanonicalEventIdAcrossBothSources() {
        let rows = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: b, timestamp: 20)],
            paired: [
                .init(canonicalId: c, timestamp: 20, expiresAt: nil, visible: true),
                .init(canonicalId: a, timestamp: 20, expiresAt: nil, visible: true),
            ], now: 30)
        #expect(rows == [.paired(index: 1, canonicalId: a), .ordinary(index: 0), .paired(index: 0, canonicalId: c)])
    }

    @Test func noncanonicalLocalIdsRetainEveryOriginalRow() {
        let rows = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: "pending", timestamp: 10), .init(canonicalId: "pending", timestamp: 10)],
            paired: [.init(canonicalId: "pending", timestamp: 10, expiresAt: nil, visible: true)], now: 30)
        #expect(rows == [.ordinary(index: 0), .ordinary(index: 1)])
    }

    @Test func expiryAtCutoffAndPersonalFilterRemoveOnlyPairedObservations() {
        let rows = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: c, timestamp: 10)],
            paired: [
                .init(canonicalId: a, timestamp: 10, expiresAt: 30, visible: true),
                .init(canonicalId: b, timestamp: 10, expiresAt: 31, visible: false),
            ], now: 30)
        #expect(rows == [.ordinary(index: 0)])
    }

    @Test func refusalClearsPairedLaneWithoutDiscardingOrdinaryRows() {
        let before = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: a, timestamp: 10)],
            paired: [.init(canonicalId: b, timestamp: 20, expiresAt: nil, visible: true)], now: 30)
        #expect(before.count == 2)
        let refused = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: a, timestamp: 10)], paired: [], now: 30)
        #expect(refused == [.ordinary(index: 0)])
    }

    @Test func oversizedPairedLaneCannotExpandOrdinaryWindow() {
        let paired = Array(
            repeating: SourceQualifiedTimelineUnion.PairedKey(
                canonicalId: b, timestamp: 20, expiresAt: nil, visible: true), count: 129)
        let rows = SourceQualifiedTimelineUnion.rows(
            ordinary: [.init(canonicalId: a, timestamp: 10)], paired: paired, now: 30)
        #expect(rows == [.ordinary(index: 0)])
    }
}
