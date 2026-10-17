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
This published MarmotKit 0.12 baseline passes **50 tests / 56 parameterized
executions, zero failures or skips**. A separate `test-without-building` run of
`PresentedChatListTests`, `NotificationSubscriptionRetryTests`,
`AppStateBootstrapTests` and `ConversationInvitePresentationTests` passes
**106 tests / 119 parameterized executions, zero failures or skips**.
Both use the same unmodified product/test source and published SDK. Results:
`/Users/pj/project/build/results/ios-public-chat-published-focused-v1.xcresult`
and `ios-public-chat-published-lifecycle-v1.xcresult`, with matching `.log` files.
These checks do not establish real relay delivery, mixed-version SDK delivery,
or installed TestFlight interoperability. No product fix has been applied.

## Next regression boundary

Use two fresh accounts with a real isolated relay. Force Welcome publication
failure while retaining the sender's canonical group; assert the pending native
record/event, no recipient invitation, and recovery by re-delivering the same
Welcome without creating a second group. Repeat with separately pinned published
and experimental SDK workers, in both sponsor directions, then receiver restart.
Preserve authentication and ordinary public protocol compatibility throughout.

## Pending-delivery warning fix

The missing normal-UI warning reproduces through the actual runtime event route:
the new test fails 0/1 because `activeToast` is nil before the fix. The first
method-filter attempt executed zero tests and is excluded from that evidence.
The fixed event route presents an eight-second localized warning for the active
account only. Stale runtime, unrelated-account and suspended-runtime events are
ignored; no identifiers or peer-provided labels appear in the banner.
The message distinguishes an unconfirmed invitation from the locally created
chat. No retry, delivery acknowledgment, private-key transfer or protocol change
is synthesized. All ten supported languages have the two warning strings.

Affected published-core qualification passes 113/0/0, recorded in
`ios-invitation-warning-green-v2.xcresult` on M5. An initial compile failure from
a missing Foundation import is preserved separately as `green-v1`; it is not a
runtime failure. Changed-file strict lint passes. Full lint retains the two
existing unchecked-Sendable violations in `DeviceLinkingAccountLifetimeTests`.
Full published-core qualification passes 2718/0/3 and full experimental SDK987
qualification passes 2884/0/9 (passed/failed/skipped), with existing opt-in skips.
Results are `ios-invitation-warning-full-published-v1.xcresult` and
`ios-invitation-warning-full-experimental-v1.xcresult` under the same M5 results
directory. Both qualify product/test source `313f657`; four changed input hashes
match M1 and both isolated M5 worktrees. SDK987 uses a separate worktree,
DerivedData and simulator `78B7D41F-B87C-4597-91DE-55477D008938`; history work is
unchanged. The user authorized merging this warning fix into `develop_dy`.
Physical visibility and the original missing-request exchange remain unverified.
