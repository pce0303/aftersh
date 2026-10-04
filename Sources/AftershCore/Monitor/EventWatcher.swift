import CoreServices
import Foundation

/// Owns one FSEventStream for the child's run window.
///
/// Start: the stream replays from the event id captured just before it is created, so a slow
/// registration cannot open a gap at the start of the run.
/// Stop: a sentinel file is written in a private temp directory that the stream also watches.
/// fseventsd delivers events in id order, so once the sentinel arrives every event the child
/// caused has been delivered. If it does not arrive in time the run is recorded as gapped.
/// The aggregator is read only after the stream is released.
final class EventWatcher: @unchecked Sendable {
    static let latency: CFTimeInterval = 0.1
    static let barrierTimeout: TimeInterval = 2
    static let barrierGap = "event delivery not confirmed before stop; late events may be missing"

    private struct Sentinel {
        let directory: URL
        /// Resolved forms, as FSEvents reports them.
        let directoryPath: String
        let filePath: String
    }

    private let queue = DispatchQueue(label: "aftersh.fsevents")
    private let streamPaths: [String]
    private let barrier = DispatchSemaphore(value: 0)
    /// Mutated only on `queue`.
    private var aggregator: EventAggregator
    private var stream: FSEventStreamRef?
    private var sentinel: Sentinel?

    init(roots: [NormalizedPath], excludedCanonical: [String]) {
        streamPaths = EventAggregator.streamPaths(for: roots)
        aggregator = EventAggregator(roots: roots, excludedCanonical: excludedCanonical)
    }

    /// Returns false when the stream could not be created or started; the aggregator is then
    /// marked unavailable and `stop()` still returns it.
    @discardableResult
    func start() -> Bool {
        sentinel = Self.makeSentinel()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<EventWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                watcher.handle(path: path, flags: eventFlags[index])
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        let paths = streamPaths + (sentinel.map { [$0.directoryPath] } ?? [])
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventsGetCurrentEventId(),
            Self.latency,
            flags
        ) else {
            queue.sync { aggregator.markUnavailable("FSEvents stream could not be created") }
            removeSentinel()
            return false
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            queue.sync { aggregator.markUnavailable("FSEvents stream could not start") }
            removeSentinel()
            return false
        }
        stream = created
        return true
    }

    /// Drains pending events, tears the stream down, and returns the collected evidence.
    /// Safe to call when `start()` failed.
    func stop() -> EventAggregator {
        if let stream {
            if !awaitBarrier(stream) {
                queue.sync { aggregator.recordGap(Self.barrierGap) }
            }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        removeSentinel()
        return queue.sync { aggregator }
    }

    /// Runs on `queue`.
    private func handle(path: String, flags: UInt32) {
        if let sentinel, PathNormalizer.isEqualOrDescendant(of: sentinel.directoryPath, path: path) {
            if path == sentinel.filePath {
                barrier.signal()
            }
            return
        }
        aggregator.ingest(path: path, flags: flags)
    }

    private func awaitBarrier(_ stream: FSEventStreamRef) -> Bool {
        guard let sentinel,
              FileManager.default.createFile(atPath: sentinel.directory.appendingPathComponent("barrier").path, contents: nil)
        else {
            FSEventStreamFlushSync(stream)
            return false
        }
        let deadline = Date().addingTimeInterval(Self.barrierTimeout)
        while Date() < deadline {
            FSEventStreamFlushSync(stream)
            if barrier.wait(timeout: .now() + 0.05) == .success {
                return true
            }
        }
        return false
    }

    private static func makeSentinel() -> Sentinel? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("aftersh-events-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let resolved = EventAggregator.realPath(directory.path)
        else { return nil }
        return Sentinel(directory: directory, directoryPath: resolved, filePath: resolved + "/barrier")
    }

    private func removeSentinel() {
        if let sentinel {
            try? FileManager.default.removeItem(at: sentinel.directory)
        }
        sentinel = nil
    }
}
