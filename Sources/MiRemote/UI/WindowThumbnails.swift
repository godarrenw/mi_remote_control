import AppKit
import ScreenCaptureKit

/// 窗口缩略图（ScreenCaptureKit）：选择器打开时异步抓，抓到一张刷一张；按 CGWindowID 缓存，
/// 最小化窗口抓不到时沿用上次缓存，从未抓到过就由视图退回 App 图标。
/// 需要「屏幕录制」权限；`CGWindowListCreateImage` 在 macOS 14+ 已废弃，不用。
@MainActor
final class WindowThumbnailCache {

    /// 目标宽度（点）；高度按窗口宽高比缩放。
    nonisolated static let targetWidth: CGFloat = 320
    /// 缓存新鲜期：短于此不重抓（连续开关选择器不反复截图）。
    nonisolated static let freshness: TimeInterval = 2

    private struct Entry { let image: NSImage; let at: Date }
    private var cache: [CGWindowID: Entry] = [:]
    private var generation = 0

    /// 已有的缓存图（不论新旧），供视图首帧直接显示。
    func images(for ids: [CGWindowID]) -> [CGWindowID: NSImage] {
        var out: [CGWindowID: NSImage] = [:]
        for id in ids { if let e = cache[id] { out[id] = e.image } }
        return out
    }

    /// 按缓存新鲜度筛出需要抓的 ID（纯逻辑，自测覆盖）。
    nonisolated static func stale(_ ids: [CGWindowID], cachedAt: [CGWindowID: Date], now: Date,
                      freshness: TimeInterval = freshness) -> [CGWindowID] {
        ids.filter { id in
            guard let at = cachedAt[id] else { return true }
            return now.timeIntervalSince(at) > freshness
        }
    }

    /// 输出尺寸纯逻辑：宽固定，高按比例，至少 1px。
    nonisolated static func outputSize(for frame: CGRect, width: CGFloat = targetWidth) -> (Int, Int) {
        guard frame.width > 0, frame.height > 0 else { return (Int(width), Int(width * 0.625)) }
        let h = max(1, (width * frame.height / frame.width).rounded())
        return (Int(width), Int(h))
    }

    nonisolated static func selfCheck() -> Bool {
        let now = Date()
        let cachedAt: [CGWindowID: Date] = [1: now, 2: now.addingTimeInterval(-10)]
        let s = stale([1, 2, 3], cachedAt: cachedAt, now: now)
        let (w, h) = outputSize(for: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        return s == [2, 3] && w == 320 && h == 200
            && outputSize(for: .zero).0 == 320
    }

    /// 异步抓取；每抓到一张回调一次（主线程）。再次调用会让上一轮的迟到结果作废。
    func capture(_ ids: [CGWindowID], onImage: @escaping (CGWindowID, NSImage) -> Void) {
        generation += 1
        let gen = generation
        let cachedAt = cache.mapValues { $0.at }
        let wanted = Self.stale(ids, cachedAt: cachedAt, now: Date())
        guard !wanted.isEmpty else { return }
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            else { log("缩略图：SCShareableContent 不可用（屏幕录制权限？）"); return }
            let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in wanted {
                    guard let scWindow = byID[id] else { continue }
                    let (w, h) = Self.outputSize(for: scWindow.frame)
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                        let cfg = SCStreamConfiguration()
                        cfg.width = w
                        cfg.height = h
                        cfg.showsCursor = false
                        cfg.scalesToFit = true
                        cfg.ignoreShadowsSingleWindow = true
                        cfg.ignoreGlobalClipSingleWindow = true
                        let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                        return (id, img)
                    }
                }
                for await (id, cg) in group {
                    guard gen == self.generation, let cg else { continue }
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache[id] = Entry(image: image, at: Date())
                    onImage(id, image)
                }
            }
        }
    }
}
