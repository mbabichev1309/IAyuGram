# AyuGram feature port — design & implementation notes

Design notes for porting AyuGram-style features (Ghost Mode + message
preservation) onto this Swiftgram / telegram-ios fork. This documents
**what to change, where, and why**, with concrete code seams. It is a
living design doc, not a spec — verify each seam on device.

> Architectural principle: telegram-ios `Postbox` is already a durable,
> SQLite-backed store of every message. Unlike AyuGram Desktop (tdesktop
> keeps messages in memory and therefore needs its own `ayudata.db`), we
> should **reuse Postbox** — preserve messages by *not deleting them*, and
> attach local-only `MessageAttribute`s. No shadow database.
>
> AyuGram Desktop/Android are GPLv3: borrow **ideas and data models**,
> reimplement in Swift — do not copy code verbatim.

---

## 1. Ghost Mode

All gates read `SGSimpleSettings.shared.ghostMode`. The flag lives in
`Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift`
(`Keys.ghostMode`, default `false`, `@UserDefault` property) and the UI
toggle in `Swiftgram/SGSettingsUI/Sources/SGSettingsController.swift`
(section `.ghostMode`, `SGBoolSetting.ghostMode`, handled in the
`updateBoolSetting` switch).

### 1.1 Currently gated (verified in code)

| Signal | Sole network sender | Seam | Status |
|---|---|---|---|
| Online status (`account.updateStatus`) | `ManagedAccountPresence.swift:48` | `effectiveIsOnline = isOnline && !ghostMode` | OK — single choke point |
| Typing (`messages.setTyping`) | `ManagedLocalInputActivities.swift:147` | early `return .complete()` | OK — single choke point |
| Voice/video/view-once "seen" (`readMessageContents`) | `MarkMessageContentAsConsumedInteractively.swift:42` | skip `addSynchronizeConsumeMessageContentsOperation` | OK — single choke point |
| Read receipts (in-chat) | `ChatHistoryListNode.swift:4542` | skip `installInteractiveReadMessagesAction` | Partial — see 1.2 |

Note: the gate at `ApplyMaxReadIndexInteractively.swift:68` only guards a
**local** notification (`notifyAppliedIncomingReadMessages`), not a network
send. It is effectively cosmetic; the real in-chat read suppression is the
`ChatHistoryListNode` gate.

### 1.2 Read receipts — hardening TODO

The read protection is **shallow**: it works only because
`ChatHistoryListNode` does not *trigger* auto-read while viewing. The actual
network read (`messages.readHistory` / `channels.readHistory`) is sent from
`SynchronizePeerReadState.swift` (and directly from a few others) and is
**not** gated. Secondary triggers therefore still leak a read receipt:

- Mark-as-read from a **push notification** — `AppDelegate.swift:2960`
- **Apple Watch** — `WatchRequestHandlers.swift:125`
- **Siri** — `SiriIntents/IntentHandler.swift:632`
- **"Mark all as read"** — `MarkAllChatsAsRead.swift`
- Reply threads — `ReplyThreadHistory.swift:370`

**Fix:** add a `ghostMode` gate at the network choke point in
`SynchronizePeerReadState.swift` (skip the `readHistory` request). One place
closes all callers.
**Caveat:** if you suppress the network read but still zero the local unread
counter, the server disagrees and the badge may reappear on next resync.
Decide whether to also keep the local unread state untouched.

### 1.3 Other ghost gaps

- **Reactions / poll votes "seen"** — `installInteractiveReadReactionsAction`
  (`InstallInteractiveReadMessagesAction.swift:222`) is not gated. Minor leak.
- **Story views** — not gated. Deprioritized: Premium Stealth Mode covers it.
  If ever added: gate `readStories` / `incrementStoryViews`
  (`ManagedSynchronizeViewStoriesOperations.swift`, `Stories.swift`).
  Server limitation: reacting/replying to a story still registers the view.

### 1.4 Granularity TODO

AyuGram exposes ~9 independent toggles (Don't Read, Don't Send Online, Don't
Send Typing, Schedule Messages, Read on Interact, …). We currently have a
single `ghostMode` flag. Recommended: split into sub-settings in
`SGSimpleSettings` and present them under a `.disclosure` → dedicated screen
of toggles. The gating mechanics already exist; this is a settings refactor.

### 1.5 Invisible send (schedule)

Sending a message **forces you online server-side** — this cannot be gated
like read/typing. The only workaround is delayed delivery via `schedule_date`
(AyuGram uses ~12 s for text, dynamic for media). Implement in the send path
(`EnqueueMessage.swift` / TelegramCore pending-message pipeline): when ghost
"invisible send" is on, route the message through scheduled-messages
transparently so it does not bump presence. Expect a delay; buggy on poor
networks (AyuGram warns the same).

---

## 2. Message preservation (deleted / edited) — "class B"

The flagship feature. Preserve messages that the server deletes or edits by
**not applying the destructive operation** and instead attaching local-only
attributes, then rendering them specially.

### 2.1 Data model — two local `MessageAttribute`s

Model after existing attributes in
`submodules/TelegramCore/Sources/SyncCore/SyncCore_*MessageAttribute.swift`.

- `LocalMessageDeletedAttribute` — flag + deletion timestamp. Its presence
  means "server deleted this; we kept it."
- `LocalMessageEditHistoryAttribute` — array of prior versions
  `[{ text, date }]` (+ media ref later).

Both are **local-only** (never serialized to the network).
**Required:** register each new attribute type in the Postbox attribute
decoder, or decoding crashes at read time. This is not optional.

### 2.2 Seam 1 — deletion

Incoming server deletions are queued in `AccountStateManagementUtils.swift`
(`updateDeleteMessages` → `updatedState.deleteMessages(...)` at ~955/1045/3503)
as `.DeleteMessages([MessageId])` operations, then **replayed** into the
Postbox transaction at:

`AccountStateManagementUtils.swift:4421`
```swift
case let .DeleteMessages(ids):
    if SGSimpleSettings.shared.preserveDeleted {
        markMessagesDeletedLocally(transaction: transaction, ids: ids) // add attribute, keep row
    } else {
        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids, ...)
    }
```

**Also gate the resync deletions** or preserved messages vanish on scroll /
gap-fill (this is the #1 bug of such features):
- `HistoryViewStateValidation.swift:987`
- `HistoryViewStateValidation.swift:1170`

Out of initial scope: `.DeleteMessagesWithGlobalIds` (`:4412`, secret/outgoing).

### 2.3 Seam 2 — edit

Edits arrive as `updateEditMessage` (`AccountStateManagementUtils.swift:1052`),
build a `StoreMessage`, and are queued via `updatedState.editMessage(...)`
(`:1069`) as `.EditMessage(MessageId, StoreMessage)`
(`AccountIntermediateState.swift:68`), replayed in the same switch.

Interception: in the replay of `.EditMessage`, **before overwriting**, read
the current message from the transaction; if the text changed, append the old
`{text, date}` to `LocalMessageEditHistoryAttribute` and carry the attribute
onto the new stored message. Gate behind `preserveEdits`.

### 2.4 Rendering / UI

- **Deleted:** message stays in the history view (we didn't delete it). In the
  bubble, detect `LocalMessageDeletedAttribute` and render a "deleted"
  label / tint. Nearly free.
- **Edit history:** add a "View edit history" action to the edited-message
  context menu, reading `LocalMessageEditHistoryAttribute`.
- **"Deleted" screen (per chat):** to avoid scanning the whole DB, attach a
  **custom Postbox tag** when marking deleted, then query by that tag.

### 2.5 Caveats (must handle)

1. **Own vs others' deletions.** The `.DeleteMessages` seam catches
   server-pushed deletions (mostly "someone else deleted"), but your own
   "delete for everyone" echoes back through the same update. Keep a set of
   recently locally-deleted IDs (from `DeleteMessagesInteractively.swift`) and
   skip preserving those.
2. **`_internal_deleteMessages` side effects.** It cleans unread counts, thread
   stats, reply refs, media. Skipping it keeps the message "live" in its slot —
   mostly fine, but verify counters on edge cases.
3. **Storage growth.** Preserved deletions accumulate — provide a cleanup UI /
   retention policy.
4. **Auto-delete / TTL messages** flow through
   `ManagedAutoremoveMessageOperations.swift` (a different path) — do NOT
   preserve those, or the "Deleted" list fills with expected auto-deletes
   (AyuGram issues #168/#300).

### 2.6 Suggested build order

1. `LocalMessageDeletedAttribute` + decoder registration (foundation).
2. Seam 1 + resync gates → messages stop disappearing. Verify on device.
3. "Deleted" bubble rendering.
4. Own-deletion dedup (ID set).
5. Custom tag + "Deleted" screen.
6. Edit history (Seam 2 + attribute + viewer) as a separate pass.

---

## 3. Media preservation

Media bytes live in `MediaBox` (on-disk cache keyed by resource id); a message
only holds a **reference** to the resource. Deleting a message removes the row,
not the cached bytes. Re-downloading after deletion often fails with
`FILE_REFERENCE_EXPIRED` (the reference can't be refreshed — the message is
gone).

### 3.1 Strategy 1 — best-effort (cheap)

Because mark-in-place keeps the message (with its media descriptor), any media
already cached (viewed / auto-downloaded) still displays. Zero extra work.

### 3.2 Strategy 2 — download-on-delete (recommended middle ground)

At the deletion seam, **before** marking, for messages with uncached media,
kick off a `fetch` using the resource reference still held in the message
object; keep the message so retries are possible. Wins the most common case
("sent then quickly deleted" — reference still fresh). Loses on old media
(reference already expired). This is AyuGram's documented behaviour
("tries to download files before they expire … or copies if downloaded
before"; saved to a protected folder).

### 3.3 Strategy 3 — proactive download (full guarantee)

With preservation on, proactively download all incoming media so bytes are on
disk before any deletion. Costs bandwidth/disk. Only needed for a 100%
guarantee including old media.

### 3.4 Protection from cache eviction (applies to 2 and 3)

`MediaBox` evicts old files. To truly preserve, **copy the bytes out of the
evictable cache into a protected store** and rewrite the message's resource to
point there — otherwise cache cleanup deletes them later. This is the fiddly
part.

---

## 4. View-once / self-destruct media

Easier and more reliable than saving normal deleted media, because
**destruction is client-driven, not server-driven** — you already hold the
bytes at view time, with no server-reference race.

Seam: the consume/expiry path in
`MarkMessageContentAsConsumedInteractively.swift` /
`markMessageContentAsConsumedRemotely`, where media is replaced with
`TelegramMediaExpiredContent` (see `viewOnceTimeout` handling, ~lines
213–226 and 239–250).

Strategy: **copy the media bytes to the protected store before the
expired-content conversion.**
- View-once you open → bytes guaranteed present (you're viewing them) →
  copy-on-open ≈ 100%.
- Timed self-destruct → copy before the timeout conversion.
- Secret-chat (E2E) media → hardest, out of initial scope.

Synergy with Ghost Mode: the consume receipt is already suppressed
(`:42` gate), so you view + save **without** notifying the sender.

---

## 5. Open questions / to verify on device

- Read-receipt secondary triggers (1.2) — do they actually fire in practice?
- Whether view-once has an extra server-side view registration beyond the
  consume path.
- Unread-counter behaviour when suppressing network reads (1.2 caveat).
- `_internal_deleteMessages` side-effects when skipped (2.5.2).

## References

- Ghost Mode — https://docs.ayugram.one/shared/ghost/
- Message Saving (Android) — https://docs.ayugram.one/android/saving/
- Message Saving (Desktop) — https://docs.ayugram.one/desktop/saving/
- AyuGram Desktop source (GPLv3) — https://github.com/AyuGram/AyuGramDesktop
