import Foundation

/// Watches the notes folder so a note edited in another app — or arriving from
/// iCloud — reaches the deck without a relaunch.
public final class FolderWatcher: @unchecked Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "com.lisandro.Ledge.watcher")
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable ([String]) -> Void

    public init(folder: URL, onChange: @escaping @Sendable ([String]) -> Void) {
        self.folder = folder
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info, count > 0 else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                // The stream is created with kFSEventStreamCreateFlagUseCFTypes,
                // so `paths` is a CFArray of CFStrings — never a C char**.
                guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                let changed = list
                    .map { ($0 as NSString).lastPathComponent }
                    .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
                guard !changed.isEmpty else { return }
                watcher.onChange(changed)
            }

            let s = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context,
                [folder.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.15,
                UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
            )
            guard let s else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }
}
