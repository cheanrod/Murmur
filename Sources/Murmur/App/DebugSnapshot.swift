#if DEBUG
import AppKit

/// Development aid: `MURMUR_SNAPSHOT=/path/prefix` makes a debug build write PNGs of its own windows
/// every few seconds (no screen-recording permission needed since the app renders itself).
enum DebugSnapshot {
    @MainActor static func startIfRequested() {
        guard let prefix = ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT"] else { return }
        var counter = 0
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                counter += 1
                for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: "\(prefix)-\(counter)-\(i).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}
#endif
