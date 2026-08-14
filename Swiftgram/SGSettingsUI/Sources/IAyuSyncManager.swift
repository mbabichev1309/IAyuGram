import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SGSimpleSettings

// Response of the companion server's REST /gap-sync (server models.py GapSyncResponse).
private struct IAyuGapSyncResponse: Codable {
    let events: [IAyuMessageEvent]
    let latestCursor: Int
    // Free space on the volume holding captured media. Optional because servers older
    // than the field simply omit it, and a missing figure must read as "unknown", never
    // as "empty disk". The threshold lives on this side (see IAyuCaptureHealth) so it
    // can change without redeploying the server.
    let storageFreeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case events
        case latestCursor = "latest_cursor"
        case storageFreeBytes = "storage_free_bytes"
    }
}

private let iAyuGapSyncPageLimit = 500

// Deleting a whole chat delivers one event per message — a few thousand of them, as
// fast as the socket can carry them. The three constants below are what keeps that
// from taking the app down:
//
// How long a batch is allowed to accumulate before it is written. One postbox
// transaction per message meant one history-view recomputation per message; short
// enough that a single ordinary delete still appears immediately.
private let iAyuMaterializeFlushDelay = 0.35
// Write early once this many are queued, so a very long burst is committed in
// steady-sized chunks instead of growing one enormous transaction.
private let iAyuMaterializeFlushThreshold = 200
// Preserved media is fetched over HTTP and then written into the media box; letting
// every delete in a mass deletion start its own download at once meant hundreds of
// concurrent transfers and, for a media-heavy chat, gigabytes in flight.
private let iAyuMaxConcurrentMediaFetches = 3

// A delete arriving within this long of the previous one in the same chat belongs to
// the same burst, and a burst quiet for this long is over. It is also how long a
// delete can be held back while we decide whether it is part of a mass deletion —
// the FIRST delete in a chat is always materialized immediately, so an ordinary one
// is never delayed; only the second and later ones wait for the verdict.
private let iAyuBurstIdleWindow = 1.5
// A collapsed batch is closed (and its summary posted) at this many messages even if
// deletes keep arriving, so a slow wipe shows something instead of nothing.
private let iAyuBurstBatchCap = 500

// A run of deletes in one chat, while we work out whether it is somebody clearing a
// message or somebody clearing the chat.
private struct IAyuDeleteBurst {
    let chatId: Int64
    var lastArrival: Double
    var lastEventDate: Int32?
    // Held back pending the verdict; empty once it is in.
    var held: [IAyuMessageEvent] = []
    // Set once the burst is judged a mass deletion. From then on its messages go
    // into the batch store instead of into the chat.
    var batch: IAyuDeletedBatchKey?
    var collapsedCount = 0
    // Milliseconds, only ever used to make the batch id unique within the chat.
    let startedAtMilliseconds: Int64
}

// How long the live socket may stay down before it is reported as an outage. Long
// enough to cover a reconnect (backoff caps at 60s) and a walk through a dead spot,
// short enough that a genuinely dead server is noticed the same day.
private let iAyuCaptureDegradeGracePeriod = 180.0

private func iAyuHealthzURL(serverURL: String) -> URL? {
    guard var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
        return nil
    }
    components.path = "/healthz"
    return components.url
}

// Phase 2b step 5: the always-on sync engine. Instantiated once per authorized
// account at app launch (from AuthorizedApplicationContext), independent of the
// settings screen. It opens the /live WebSocket for real-time events and runs REST
// /gap-sync from the last persisted cursor to catch up on anything missed while the
// app was closed, materializing each event into Postbox. The cursor is persisted so
// we never re-scan already-applied events.
public final class IAyuSyncManager {
    private let context: AccountContext
    private var liveSession: IAyuLiveSession?
    private var active = true
    // Events are handled here rather than on the main queue: a mass deletion is
    // thousands of events, and the work (dedup bookkeeping, deciding what to fetch,
    // opening transactions) has no reason to compete with the UI. Everything below
    // marked "sync queue" is touched only from here. Capture health, the reconnect
    // backoff and the degrade timer stay on main.
    private let queue = Queue(name: "org.iayugram.sync", qos: .utility)
    // Cursors fully dealt with, so an event that arrives on both /live and the
    // gap-sync backfill isn't processed twice, and so the persisted cursor can be
    // advanced only along a contiguous prefix (no gaps → no missed events on crash).
    // Sync queue.
    private var processedCursors = Set<Int>()
    // Cursors accepted but not yet committed — buffered for the next batch write, or
    // waiting on a media download. They are deliberately NOT in processedCursors, so
    // the persisted cursor stalls behind them and a kill mid-batch re-delivers them
    // next launch instead of losing them. Sync queue.
    private var pendingCursors = Set<Int>()
    // (peerId, messageId) of the buffered events, for the same reason the persistent
    // dedup store exists — the two paths can offer the same delete inside one window,
    // before it has been recorded as materialized. Sync queue.
    private var pendingKeys = Set<String>()
    private var pendingItems: [IAyuPendingDelete] = []
    private var pendingMediaFetches: [IAyuMessageEvent] = []
    private var activeMediaFetches = 0
    private var flushScheduled = false
    // Per-chat delete bursts, and which of them already have an idle check pending.
    // Sync queue.
    private var bursts: [Int64: IAyuDeleteBurst] = [:]
    private var burstChecksScheduled = Set<Int64>()
    // Deletes accepted while any burst is open, across ALL chats, and whether that total
    // has already tripped the global rule. Reset once every burst has closed, so the
    // count measures one storm rather than the lifetime of the app. Sync queue.
    private var runDeleteCount = 0
    private var globalCollapseArmed = false
    // The persisted cursor, in memory. Writing it to UserDefaults per event was one
    // more per-message cost on a path that gets thousands of messages at once; it is
    // written once per flush now.
    private var cursor = 0
    private var cursorDirty = false
    private var serverURL = ""
    private var token = ""
    private var reconnectDelay = 5.0
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    // Capture-health tracking (see IAyuCaptureHealth). The socket dropping is not by
    // itself worth a warning — reconnects are routine, and iOS kills the socket on every
    // backgrounding. Only a drop that outlives the grace period means something is wrong.
    private var isLiveConnected = false
    private var degradeCheckPending = false
    // A socket is mid-handshake — see connectLive.
    private var isConnecting = false
    private var lastForegroundAt = 0.0

    public init(context: AccountContext) {
        self.context = context
        self.start()
        // The iOS app is suspended in the background, killing the socket; reconnect
        // and catch up whenever it returns to the foreground.
        self.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onForeground()
        }
        // A buffered batch is normally committed within a fraction of a second, but
        // backgrounding is when the app is most likely to be killed outright — write
        // what is waiting rather than betting on the timer.
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                self.closeAllBursts()
                self.flush()
            }
        }
    }

    deinit {
        self.active = false
        self.liveSession?.stop()
        for observer in [self.foregroundObserver, self.backgroundObserver] {
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func start() {
        self.serverURL = SGSimpleSettings.shared.iaSyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = SGSimpleSettings.shared.iaSyncClientToken
        guard !self.serverURL.isEmpty, !self.token.isEmpty else {
            // Companion server not configured — nothing to sync, and nothing to warn about.
            IAyuCaptureHealth.shared.update(.notConfigured)
            return
        }
        // Assume healthy until something actually fails, so a cold launch never flashes
        // a warning before the first connection has had a chance to complete.
        IAyuCaptureHealth.shared.update(.healthy)
        let storedCursor = Int(SGSimpleSettings.shared.iaSyncCursor)
        self.queue.async {
            self.cursor = storedCursor
        }
        // Connect live first so events firing during the gap-sync fetch aren't lost;
        // the cursor dedup below drops any that both paths deliver.
        self.connectLive()
        self.gapSync(serverURL: self.serverURL, token: self.token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
    }

    private func connectLive() {
        // isLiveConnected only turns true once the confirming ping answers, so it reads
        // false for the whole handshake. Anything arriving in that window — a second
        // didBecomeActive, a reconnect timer — used to take that as "no socket" and build
        // another, tearing down the one still connecting. Measured on the server: 182
        // connections across 80 genuine wakes, with 51 wakes producing exactly two.
        guard !self.isConnecting else {
            return
        }
        self.isConnecting = true

        self.liveSession?.stop()
        self.liveSession = IAyuLiveSession(serverURL: self.serverURL, token: self.token, onEvent: { [weak self] event in
            self?.handle(event)
        }, onStatus: { _ in
        }, onConnected: { [weak self] connected in
            guard let self = self else { return }
            self.isConnecting = false
            self.isLiveConnected = connected
            if connected {
                // Reset the backoff once we're actually connected.
                self.reconnectDelay = 5.0
                IAyuCaptureHealth.shared.update(.healthy)
            } else {
                self.scheduleDegradeCheck()
            }
        }, onClosed: { [weak self] in
            guard let self = self else { return }
            self.isConnecting = false
            self.scheduleReconnect()
        })
        if self.liveSession == nil {
            // Bad URL: nothing will ever call back, so release the guard now.
            self.isConnecting = false
            return
        }
        // Safety net. If a handshake hangs with neither callback ever firing, the guard
        // above would latch and no reconnect would be attempted again for the lifetime
        // of the app — a far worse failure than the duplicate it exists to prevent.
        Queue.mainQueue().after(20.0, { [weak self] in
            self?.isConnecting = false
        })
    }

    // A dropped socket only counts as a real outage once it has stayed down past the
    // grace period, so ordinary reconnects and app backgrounding stay silent. When the
    // grace period is up, ask the server directly: it distinguishes "unreachable" from
    // "running but no longer authorized with Telegram", and the second is the one that
    // looks fine from outside while capturing nothing.
    private func scheduleDegradeCheck() {
        // Start the countdown on the transition into "down", NOT on every failure.
        // Reconnect attempts keep failing while the server is off and the backoff caps
        // at 60s, so re-arming the timer per failure meant a grace period longer than
        // the retry interval could never elapse — the check simply never ran.
        guard !self.degradeCheckPending else {
            return
        }
        self.degradeCheckPending = true
        Queue.mainQueue().after(iAyuCaptureDegradeGracePeriod, { [weak self] in
            guard let self = self, self.active else {
                return
            }
            self.degradeCheckPending = false
            guard !self.isLiveConnected else {
                return
            }
            self.probeHealth()
        })
    }

    private func probeHealth() {
        guard let url = iAyuHealthzURL(serverURL: self.serverURL) else {
            IAyuCaptureHealth.shared.update(.unreachable)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            Queue.mainQueue().async {
                guard let self = self, self.active, !self.isLiveConnected else {
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                    IAyuCaptureHealth.shared.update(.unreachable)
                    self.rearmDegradeCheck()
                    return
                }
                // Older server builds answer /healthz without the field; absence must not
                // read as "session lost", so only an explicit false counts.
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let authorized = json?["session_authorized"] as? Bool, !authorized {
                    IAyuCaptureHealth.shared.update(.sessionLost)
                    self.rearmDegradeCheck()
                } else {
                    // Server up and still authorized: capture is running and nothing is
                    // being lost, whatever our own socket is doing — gap-sync backfills
                    // it. Reporting this as degraded would light up after every return
                    // from the background, when the socket is briefly down by design.
                    IAyuCaptureHealth.shared.update(.healthy)
                }
            }
        }.resume()
    }

    // Keep probing while we stay down, so a server that later loses its session is
    // still noticed rather than being frozen at whatever the first probe found.
    private func rearmDegradeCheck() {
        guard self.active, !self.isLiveConnected else {
            return
        }
        self.scheduleDegradeCheck()
    }

    // Reconnect with exponential backoff (5s → 60s cap) after the socket drops, and
    // gap-sync to catch anything missed while disconnected (dedup guards duplicates).
    private func scheduleReconnect() {
        guard self.active, !self.serverURL.isEmpty else { return }
        let delay = self.reconnectDelay
        // Only count attempts that had a chance. iOS does not let a suspended app open a
        // socket, so growing the delay while we are not on screen walked the backoff to
        // its 60s cap on attempts that were doomed anyway — and then the app was opened
        // and had to wait out that cap before a live connection existed. Reached only
        // from a session's onClosed, which always runs on the main queue; applicationState
        // may not be read anywhere else.
        if UIApplication.shared.applicationState == .active {
            self.reconnectDelay = min(self.reconnectDelay * 2.0, 60.0)
        }
        Queue.mainQueue().after(delay, { [weak self] in
            guard let self = self, self.active else { return }
            self.connectLive()
            self.gapSync(serverURL: self.serverURL, token: self.token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
        })
    }

    // didBecomeActive is not "returned from the background". It also arrives after the
    // control centre, a notification banner, a screenshot, the app switcher and an
    // incoming call — so reconnecting unconditionally threw away a perfectly good socket
    // hundreds of times a day, and every teardown meant deletes arrived with the next
    // gap-sync instead of live. A socket we believe in is probed rather than replaced;
    // if the probe fails, its own onClosed brings us back here through the reconnect.
    private func onForeground() {
        guard self.active, !self.serverURL.isEmpty else { return }
        // didBecomeActive fires for banners, the control centre and screenshots, not just
        // for a real return — and often twice within seconds for one of them. Running the
        // whole probe-or-reconnect dance each time is the other half of the duplicate
        // connections; one wake should cost one socket.
        let now = CFAbsoluteTimeGetCurrent()
        if now - self.lastForegroundAt < 3.0 {
            return
        }
        self.lastForegroundAt = now
        self.reconnectDelay = 5.0
        if self.isLiveConnected {
            self.liveSession?.probeAlive()
        } else {
            self.connectLive()
        }
        // Unconditional: a gap-sync is cheap, and it is what covers whatever the socket
        // missed while we were away, however briefly.
        self.gapSync(serverURL: self.serverURL, token: self.token, since: Int(SGSimpleSettings.shared.iaSyncCursor))
    }

    private func handle(_ event: IAyuMessageEvent) {
        self.queue.async {
            guard self.active else { return }
            if self.processedCursors.contains(event.cursor) || self.pendingCursors.contains(event.cursor) {
                return
            }
            if event.kind == "deleted" {
                self.accept(delete: event)
            } else if event.kind == "edited" {
                self.applyEdit(event)  // IAyuEditHistoryStore dedups by cursor persistently
                self.settle(cursor: event.cursor)
            } else {
                self.settle(cursor: event.cursor)
            }
            self.scheduleFlush()
        }
    }

    // Take a delete into the buffer, or drop it if it has already been dealt with.
    // Sync queue.
    private func accept(delete event: IAyuMessageEvent) {
        // Persistent dedup by peerId+messageId: gap-sync can re-deliver an already-
        // applied delete across launches (when the cursor lags a gap), and this stops
        // it from inserting a second placeholder.
        let peerId = iAyuPeerId(fromServerChatId: event.chatId).toInt64()
        let key = "\(peerId):\(event.messageId)"
        if self.pendingKeys.contains(key) || IAyuMaterializedDeletesStore.shared.contains(peerId: peerId, messageId: event.messageId) {
            self.settle(cursor: event.cursor)
            return
        }
        guard self.shouldMaterialize(event: event, peerId: peerId) else {
            // Mark it seen even though we skip it. The dedup store's job is "this event
            // has been dealt with"; leaving it out would make every gap-sync re-offer
            // the same skipped delete forever, and turning an exception off later would
            // then dump a backlog of old messages into the chat.
            IAyuMaterializedDeletesStore.shared.insert(peerId: peerId, messageId: event.messageId)
            self.settle(cursor: event.cursor)
            return
        }
        // From here the event is ours to write. It is recorded as materialized only
        // once it actually has been (in flush), so a kill in between re-delivers it
        // rather than marking a message we never inserted as done.
        self.pendingKeys.insert(key)
        self.pendingCursors.insert(event.cursor)

        let threshold = Int(SGSimpleSettings.shared.iaMassDeleteCollapse)
        guard threshold > 0 else {
            self.materialize(event)
            return
        }
        // The per-chat verdict above cannot see a deletion that is spread thinly across
        // many chats: forty messages in each of a hundred chats trips nobody's threshold,
        // so nothing collapses and every one of those messages also queues a media
        // download. Count the whole run and arm collapsing everywhere once it is clearly
        // not an ordinary handful.
        self.runDeleteCount += 1
        let globalThreshold = Int(SGSimpleSettings.shared.iaMassDeleteGlobalCollapse)
        if !self.globalCollapseArmed, globalThreshold > 0, self.runDeleteCount >= globalThreshold {
            self.armGlobalCollapse()
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard var burst = self.bursts[peerId] else {
            // First delete in this chat for a while: it goes into the chat right away,
            // which is what makes an ordinary single deletion feel immediate. The burst
            // it opens is what makes the next one wait for a verdict.
            var burst = IAyuDeleteBurst(chatId: event.chatId, lastArrival: now, lastEventDate: event.date.map { Int32(clamping: $0) }, startedAtMilliseconds: Int64(now * 1000.0))
            if self.globalCollapseArmed {
                // Already in a storm: hold it instead. Letting the first delete through
                // per chat would leave a stray bubble in every chat touched, and holding
                // also downloads nothing. The verdict waits until the burst closes, so a
                // chat that turns out to have lost exactly one message still gets it back
                // as an ordinary bubble rather than a summary of one.
                burst.held.append(event)
            } else {
                self.materialize(event)
            }
            self.bursts[peerId] = burst
            self.scheduleBurstCheck(peerId: peerId)
            return
        }
        burst.lastArrival = now
        if let date = event.date.map({ Int32(clamping: $0) }) {
            burst.lastEventDate = max(burst.lastEventDate ?? date, date)
        }
        if let batch = burst.batch {
            self.collapse(event: event, peerId: peerId, key: key, batch: batch)
            burst.collapsedCount += 1
            if burst.collapsedCount >= iAyuBurstBatchCap {
                // Long wipe: post what we have and start a fresh batch, rather than
                // holding a summary back until the deleting finally stops.
                self.closeBurst(peerId: peerId, burst: burst)
                return
            }
            self.bursts[peerId] = burst
            self.scheduleBurstCheck(peerId: peerId)
            return
        }
        burst.held.append(event)
        // The already-materialized first delete of the burst counts towards the verdict
        // even though the summary can't cover it.
        if burst.held.count + 1 >= threshold {
            self.startCollapsing(peerId: peerId, burst: &burst)
        }
        self.bursts[peerId] = burst
        self.scheduleBurstCheck(peerId: peerId)
    }

    // Write this delete into the chat: straight away if there is nothing to download,
    // otherwise once its media has been fetched. Sync queue.
    private func materialize(_ event: IAyuMessageEvent) {
        switch iAyuMaterializePlan(event: event) {
        case let .ready(note):
            self.pendingItems.append(IAyuPendingDelete(event: event, appendedNote: note))
        case .needsMedia:
            self.pendingMediaFetches.append(event)
            self.pumpMediaFetches()
        }
    }

    // Put this delete in the batch store instead of the chat. Nothing is downloaded:
    // a wiped chat's media would be hundreds of megabytes nobody asked for, and the
    // bytes stay on the server, so restoring one message later still recovers it.
    private func collapse(event: IAyuMessageEvent, peerId: Int64, key: String, batch: IAyuDeletedBatchKey) {
        IAyuDeletedBatchStore.shared.append(key: batch, event: event)
        IAyuMaterializedDeletesStore.shared.insert(peerId: peerId, messageId: event.messageId)
        self.pendingKeys.remove(key)
        self.settle(cursor: event.cursor)
    }

    // The verdict came in: this is a mass deletion. Everything held goes into a batch
    // of its own, and the rest of the burst follows it. Sync queue.
    private func startCollapsing(peerId: Int64, burst: inout IAyuDeleteBurst) {
        let batch = IAyuDeletedBatchKey(peerId: peerId, batchId: burst.startedAtMilliseconds)
        burst.batch = batch
        for event in burst.held {
            self.collapse(event: event, peerId: peerId, key: "\(peerId):\(event.messageId)", batch: batch)
        }
        burst.collapsedCount = burst.held.count
        burst.held = []
    }

    // The run as a whole is a mass deletion, whatever any single chat's count says.
    // Every burst still waiting for its own verdict gets one now. Sync queue.
    private func armGlobalCollapse() {
        self.globalCollapseArmed = true
        for peerId in Array(self.bursts.keys) {
            guard var burst = self.bursts[peerId], burst.batch == nil else {
                continue
            }
            self.startCollapsing(peerId: peerId, burst: &burst)
            self.bursts[peerId] = burst
        }
    }

    // Sync queue. Re-arms itself while deletes keep arriving.
    private func scheduleBurstCheck(peerId: Int64) {
        guard !self.burstChecksScheduled.contains(peerId) else {
            return
        }
        self.burstChecksScheduled.insert(peerId)
        self.queue.after(iAyuBurstIdleWindow, { [weak self] in
            guard let self = self, self.active else { return }
            self.burstChecksScheduled.remove(peerId)
            guard let burst = self.bursts[peerId] else {
                return
            }
            if CFAbsoluteTimeGetCurrent() - burst.lastArrival >= iAyuBurstIdleWindow - 0.05 {
                self.closeBurst(peerId: peerId, burst: burst)
            } else {
                self.scheduleBurstCheck(peerId: peerId)
            }
        })
    }

    // The burst is over (or has hit the batch cap). Sync queue.
    private func closeBurst(peerId: Int64, burst: IAyuDeleteBurst) {
        var burst = burst
        self.bursts.removeValue(forKey: peerId)

        // The run as a whole was a mass deletion even though this chat never reached its
        // own threshold: collapse what it lost instead of restoring it one message at a
        // time. Only from two, because a summary standing in for a single message is
        // worse than the message — and it would read "1 messages were deleted".
        if burst.batch == nil, self.globalCollapseArmed, burst.held.count > 1 {
            self.startCollapsing(peerId: peerId, burst: &burst)
        }

        if let batch = burst.batch {
            IAyuDeletedBatchStore.shared.close(key: batch)
            if burst.collapsedCount > 0 {
                self.pendingItems.append(iAyuMassDeletePlaqueItem(
                    key: batch,
                    chatId: burst.chatId,
                    count: burst.collapsedCount,
                    timestamp: burst.lastEventDate
                ))
                self.scheduleFlush()
            }
        } else if !burst.held.isEmpty {
            // Not a mass deletion after all — an ordinary handful. Bring them back.
            for event in burst.held {
                self.materialize(event)
            }
            self.scheduleFlush()
        }

        // Last burst standing: nothing is being deleted anywhere any more, so the next
        // storm gets judged on its own size. Deliberately after the verdict above, which
        // still needs to know whether this one was armed.
        if self.bursts.isEmpty {
            self.runDeleteCount = 0
            self.globalCollapseArmed = false
        }
    }

    // Sync queue. Called when the app backgrounds: an open burst holds messages that
    // exist nowhere else yet, so decide it now rather than betting on coming back.
    private func closeAllBursts() {
        // closeBurst clears the armed flag as soon as the last burst goes, but every burst
        // in this sweep belongs to the same run and has to get the same verdict — so hold
        // the flag steady across the loop instead of letting iteration order decide which
        // chats collapse and which do not.
        let wasArmed = self.globalCollapseArmed
        for (peerId, burst) in self.bursts {
            self.globalCollapseArmed = wasArmed
            self.closeBurst(peerId: peerId, burst: burst)
        }
        self.runDeleteCount = 0
        self.globalCollapseArmed = false
        IAyuDeletedBatchStore.shared.closeAll()
    }

    // This cursor needs nothing further. Sync queue.
    private func settle(cursor: Int) {
        self.pendingCursors.remove(cursor)
        self.processedCursors.insert(cursor)
        self.advanceCursor()
    }

    private func scheduleFlush() {
        if self.pendingItems.count >= iAyuMaterializeFlushThreshold {
            self.flush()
            return
        }
        guard !self.flushScheduled else {
            return
        }
        self.flushScheduled = true
        self.queue.after(iAyuMaterializeFlushDelay, { [weak self] in
            guard let self = self, self.active else { return }
            self.flush()
        })
    }

    // Commit the buffer: one transaction for every message waiting, then the cursor.
    // Sync queue.
    private func flush() {
        self.flushScheduled = false
        if !self.pendingItems.isEmpty {
            let items = self.pendingItems
            self.pendingItems = []
            iAyuInsertDeleted(context: self.context, items: items)
            for item in items {
                let peerId = iAyuPeerId(fromServerChatId: item.event.chatId).toInt64()
                IAyuMaterializedDeletesStore.shared.insert(peerId: peerId, messageId: item.event.messageId)
                self.pendingKeys.remove("\(peerId):\(item.event.messageId)")
                self.pendingCursors.remove(item.event.cursor)
                self.processedCursors.insert(item.event.cursor)
            }
            self.advanceCursor()
        }
        if self.cursorDirty {
            self.cursorDirty = false
            SGSimpleSettings.shared.iaSyncCursor = Int32(clamping: self.cursor)
        }
    }

    // Start as many queued media downloads as the concurrency budget allows. Sync
    // queue; each completion comes back here to free its slot and take the next.
    private func pumpMediaFetches() {
        while self.activeMediaFetches < iAyuMaxConcurrentMediaFetches, !self.pendingMediaFetches.isEmpty {
            let event = self.pendingMediaFetches.removeFirst()
            self.activeMediaFetches += 1
            iAyuFetchAndBuildMedia(context: self.context, event: event) { [weak self] item in
                guard let self = self else { return }
                self.queue.async {
                    self.activeMediaFetches -= 1
                    guard self.active else { return }
                    self.pendingItems.append(item)
                    self.pumpMediaFetches()
                    self.scheduleFlush()
                }
            }
        }
    }

    // Whether this delete should be brought back into the chat. Both answers are
    // display-only: the companion server has already captured and stored the message
    // either way, so turning an exception off later shows nothing retroactively but the
    // content is still on the server and reachable through /gap-sync.
    private func shouldMaterialize(event: IAyuMessageEvent, peerId: Int64) -> Bool {
        guard IAyuPeerExceptions.preservationApplies(peerId: peerId) else {
            return false
        }
        // "When I delete my own message for everyone, restore it in the chat?" — off
        // means our own deletes stay deleted, which is what someone who deletes a
        // message on purpose usually wants; others' deletes are unaffected.
        if event.fromMe == true, !SGSimpleSettings.shared.iaRestoreOwnDeletes {
            return false
        }
        return true
    }

    // Advance the cursor only along the CONTIGUOUS processed prefix. If a later event
    // (e.g. live cursor 105) is processed while an earlier one (100) is still buffered
    // or waiting on its media, the cursor stays put until the gap fills — so a crash
    // never skips 100. On the next launch gap-sync re-fetches from the persisted point
    // and the dedup store/edit store drop anything already applied. The write itself
    // happens in flush(). Sync queue.
    private func advanceCursor() {
        var cursor = self.cursor
        while self.processedCursors.contains(cursor + 1) {
            cursor += 1
        }
        if cursor > self.cursor {
            self.cursor = cursor
            self.cursorDirty = true
            // Cursors at/below the settled point need no tracking — drop them to keep
            // the in-memory set bounded (re-delivery is caught by the persistent dedup).
            self.processedCursors = self.processedCursors.filter { $0 > cursor }
        }
    }

    // Record the pre-edit text in the side store (keyed by peerId+messageId) so it
    // can be shown later via the "Edit history" action. Kept out of Postbox on
    // purpose — Telegram's own edit/resync would wipe a message attribute. Deduped
    // by cursor inside the store, so replays never double-record an edit.
    private func applyEdit(_ event: IAyuMessageEvent) {
        guard let oldText = event.oldText, !oldText.isEmpty else {
            return
        }
        let peerId = iAyuPeerId(fromServerChatId: event.chatId)
        let version = IAyuEditVersion(cursor: event.cursor, date: Int32(clamping: event.date ?? 0), text: oldText)
        IAyuEditHistoryStore.shared.append(peerId: peerId.toInt64(), messageId: Int32(clamping: event.messageId), version: version)
    }

    private func gapSync(serverURL: String, token: String, since: Int) {
        guard self.active else { return }
        guard var components = URLComponents(string: serverURL.contains("://") ? serverURL : "https://\(serverURL)") else {
            return
        }
        components.path = "/gap-sync"
        components.queryItems = [
            URLQueryItem(name: "since", value: "\(since)"),
            URLQueryItem(name: "limit", value: "\(iAyuGapSyncPageLimit)")
        ]
        guard let url = components.url else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, self.active else { return }
            guard let data = data, let response = try? JSONDecoder().decode(IAyuGapSyncResponse.self, from: data) else {
                return
            }
            // Gap-sync is the one request the client makes unconditionally — at launch
            // and on every foreground — which is why the server's free-space figure
            // rides along here rather than on /healthz, a call that only happens while
            // the live socket is already down.
            IAyuCaptureHealth.shared.updateStorage(freeBytes: response.storageFreeBytes)

            for event in response.events {
                self.handle(event)
            }
            if response.events.count >= iAyuGapSyncPageLimit, let lastCursor = response.events.last?.cursor {
                // A full page — more may remain; keep paging from the last cursor.
                self.gapSync(serverURL: serverURL, token: token, since: lastCursor)
            } else if let maxReceived = response.events.map({ $0.cursor }).max() {
                // Fully caught up. Everything the server had up to maxReceived has now
                // been delivered, so advance the cursor to it — this closes PERMANENT
                // gaps in the historical cursor sequence (sqlite AUTOINCREMENT can skip
                // values, and a fresh client starts at 0 far below the first cursor)
                // that the contiguous advance would otherwise stall on forever. Only
                // up to maxReceived (not the server's latest) so a delete racing in
                // between the query's two statements isn't skipped — it re-syncs next
                // launch or arrives on /live.
                self.queue.async {
                    guard self.active else { return }
                    // Never past something still buffered or downloading, for the same
                    // reason the contiguous advance exists.
                    let firstPending = self.pendingCursors.min()
                    let ceiling = firstPending.map { $0 - 1 } ?? maxReceived
                    let target = min(maxReceived, ceiling)
                    if target > self.cursor {
                        self.cursor = target
                        self.cursorDirty = true
                        self.processedCursors = self.processedCursors.filter { $0 > target }
                    }
                    self.scheduleFlush()
                }
            }
        }
        task.resume()
    }
}
