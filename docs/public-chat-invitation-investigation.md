# Public chat invitation investigation

Branch: `codex/ios-public-chat-invitation`, based on iOS `32ab4a0`.
This investigation is separate from history transfer and device pairing.

The reported exchange is TestFlight ↔ WN Personal Dev, using a pasted public
key, with no recipient chat request. Sender direction, actual TestFlight version,
foreground state and selected recipient KeyPackage remain unobserved. No cause
has been established for that exchange.

## Code findings

- `Recipients/DirectChatStarter.swift` calls the ordinary
  `createGroupWithOptionsDetailed` API. It does not require device pairing.
  A returned group becomes an opened local chat.
- MarmotKit's `createGroup` contract explicitly distinguishes local canonical
  creation from Welcome delivery. A failed invitation can leave a valid local
  group and emit `welcomeDeliveryPending`. `CreatedGroupFfi` contains only the
  group ID and chat-list row; it has no delivery acknowledgment.
- `Core/AppState.swift` observes runtime events but does not handle that pending
  delivery event. Only `Diagnostics/DiagnosticsView.swift` renders it. The
  ordinary sender flow therefore has no explicit pending-invitation indication.
  This is a concrete visibility gap; it does not prove this event occurred in
  the reported exchange.
- The inspected generated Swift API documents the native durable pending-Welcome
  query but does not expose `pendingWelcomeDeliveries` or `redeliverWelcome`.
  Native `AppClient` has both operations. A restart-safe host status/retry flow
  needs an SDK boundary change; do not patch generated bindings or manufacture
  delivery success from a local group row.
- `Chats/ChatsListViewModel.swift` retains unarchived pending invitations. The
  pending-invitation exclusion in `allUnreadItems` applies to unread bulk actions,
  not the normal Chats list. Subscription failures have bounded retry.
- `Chats/ChatsListView.swift` rebinds on account/runtime/scene changes;
  `Core/RuntimeLifecycle.swift` rebuilds after background suspension and schedules
  catch-up. No confirmed lost-invitation race was found in this review.

Other candidates remain relay discovery/publication/receipt and use of a public
KeyPackage owned by another unpaired installation of the same identity. Neither
is an observed cause. Personal Team foreground receipt must be assessed separately
from its unavailable remote APNS wake-up.

## Isolated verification

M5 simulator: `White Noise Public Chat Bug`,
`D1F0BC76-3F4F-4705-8B20-21F843781250`, iOS 26.2.
The existing history simulator is untouched. Source is a separate Git worktree;
published-core DerivedData is `/Users/pj/project/build/iOSPublicChatBugPublished`.
Dependency downloads are reused, but native module caches and simulator account
storage are separate. No existing identities or databases are copied.

Focused baseline checks cover `DirectChatStarterTests`,
`ChatListPreviewCacheTests`, and `AccountUnreadSummaryProjectionTests`.
Results are pending; these checks do not establish relay delivery or installed
TestFlight interoperability.

## Next regression boundary

Use two fresh accounts with a real isolated relay. Force Welcome publication
failure while retaining the sender's canonical group; assert the pending native
record/event, no recipient invitation, and recovery by re-delivering the same
Welcome without creating a second group. Repeat with separately pinned published
and experimental SDK workers, in both sponsor directions, then receiver restart.
Only after reproducing a behavioral failure should a focused fix be selected.
Preserve authentication and ordinary public protocol compatibility throughout.
