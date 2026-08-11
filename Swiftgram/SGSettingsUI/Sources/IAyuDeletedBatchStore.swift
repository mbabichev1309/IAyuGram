import Foundation

// IAyuGram: the messages of a mass deletion, kept aside instead of being brought back
// into the chat one by one. A chat being wiped is thousands of deletes; materializing
// each one costs a synthetic message forever and buries the chat under bubbles nobody
// asked for, so the chat gets a single summary message and the contents live here,
// listed on demand (and restorable one at a time).
//
// Outside Postbox for the same reason the edit history is (see IAyuEditHistoryStore),
// and on disk rather than in UserDefaults because a batch is hundreds of payloads.
// Each batch is one append-only JSONL file: appending a line is O(1), where rewriting
// a JSON array per event would put us back to the quadratic cost this whole change is
// about. Restored ids go in a small sidecar, rewritten as needed — that one is
// user-driven and rare.

// Identifies one collapsed batch. Stable across launches; it is what the summary
// message's link carries.
struct IAyuDeletedBatchKey: Equatable {
    let peerId: Int64
    let batchId: Int64

    var rawValue: String {
        return "\(self.peerId)_\(self.batchId)"
    }

    init(peerId: Int64, batchId: Int64) {
        self.peerId = peerId
        self.batchId = batchId
    }

    // Parsed back out of a link the user tapped, so it is validated rather than
    // trusted: only two integers, nothing that could reach outside the directory.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "_")
        guard parts.count == 2, let peerId = Int64(parts[0]), let batchId = Int64(parts[1]) else {
            return nil
        }
        self.peerId = peerId
        self.batchId = batchId
    }
}

final class IAyuDeletedBatchStore {
    static let shared = IAyuDeletedBatchStore()

    private let lock = NSLock()
    // Open append handles for the batches still being written. A mass deletion arrives
    // over seconds, so reopening the file per event would be the cost we are avoiding.
    private var handles: [String: FileHandle] = [:]
    private let encoder = JSONEncoder()

    private init() {
    }

    private var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("iayugram-deleted-batches", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }

    private func fileURL(_ key: IAyuDeletedBatchKey) -> URL? {
        return self.directory?.appendingPathComponent("\(key.rawValue).jsonl")
    }

    private func restoredURL(_ key: IAyuDeletedBatchKey) -> URL? {
        return self.directory?.appendingPathComponent("\(key.rawValue).restored")
    }

    // Add one event to a batch, opening the file if this is the first.
    func append(key: IAyuDeletedBatchKey, event: IAyuMessageEvent) {
        guard let url = self.fileURL(key), var line = try? self.encoder.encode(event) else {
            return
        }
        line.append(0x0a)  // newline: one event per line is what makes appending cheap
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.handles[key.rawValue] == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return
            }
            handle.seekToEndOfFile()
            self.handles[key.rawValue] = handle
        }
        self.handles[key.rawValue]?.write(line)
    }

    // The batch is complete (or the app is going away): let go of the handle.
    func close(key: IAyuDeletedBatchKey) {
        self.lock.lock()
        let handle = self.handles.removeValue(forKey: key.rawValue)
        self.lock.unlock()
        handle?.closeFile()
    }

    func closeAll() {
        self.lock.lock()
        let handles = self.handles
        self.handles = [:]
        self.lock.unlock()
        for handle in handles.values {
            handle.closeFile()
        }
    }

    // Everything recorded for a batch, oldest first. Reads the file whole: a batch is
    // opened by tapping its summary message, so this runs once per screen, not per
    // event, and the screen pages the result itself.
    func events(key: IAyuDeletedBatchKey) -> [IAyuMessageEvent] {
        // Any pending line has to be on disk before we read it back.
        self.lock.lock()
        self.handles[key.rawValue]?.synchronizeFile()
        self.lock.unlock()
        guard let url = self.fileURL(key), let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        var result: [IAyuMessageEvent] = []
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            if let event = try? decoder.decode(IAyuMessageEvent.self, from: line) {
                result.append(event)
            }
        }
        return result
    }

    func exists(key: IAyuDeletedBatchKey) -> Bool {
        guard let url = self.fileURL(key) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // Which entries of the batch the user has already brought back, so the list can say
    // so instead of offering to insert a second copy. Kept by POSITION in the file, not
    // by message id: entries archived from messages that were already in the chat have
    // no server id left, so they all carry 0 and one restore would mark every one of
    // them. The file is append-only, so a position never means something else later.
    func restoredIndices(key: IAyuDeletedBatchKey) -> Set<Int> {
        guard let url = self.restoredURL(key), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return Set(text.split(separator: "\n").compactMap { Int($0) })
    }

    func markRestored(key: IAyuDeletedBatchKey, index: Int) {
        guard let url = self.restoredURL(key) else {
            return
        }
        var indices = self.restoredIndices(key: key)
        indices.insert(index)
        let text = indices.map { "\($0)" }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
