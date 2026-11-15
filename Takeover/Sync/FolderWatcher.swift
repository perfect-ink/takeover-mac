import CoreServices
import Foundation

/// Calls `onChange` (on the main queue, debounced) when any of `fileNames`
/// is created, written, renamed or removed in the watched folders. Uses
/// FSEvents, which also sees iCloud Drive and Dropbox replacing a file with
/// a newer copy synced from another Mac.
final class FolderWatcher {
    private let folders: [String]
    private let fileNames: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    /// Wait this long after the last event, so a burst (temp file + rename,
    /// two files saved together) fires once.
    static let debounce: TimeInterval = 1.0

    init(folders: [String], fileNames: [String], onChange: @escaping () -> Void) {
        self.folders = folders
        self.fileNames = fileNames
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.received(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Matches "mac-defaults.yaml" and iCloud's ".mac-defaults.yaml.icloud"
    /// placeholder alike.
    static func isRelevant(_ path: String, fileNames: [String]) -> Bool {
        let name = (path as NSString).lastPathComponent
        return fileNames.contains { name.contains($0) }
    }

    private func received(_ paths: [String]) {
        guard paths.contains(where: { Self.isRelevant($0, fileNames: fileNames) }) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}
