/// Per-test Boolean storage shared only by MainActor fixture callbacks and transitions.
@MainActor
final class MainActorTestFlag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}
