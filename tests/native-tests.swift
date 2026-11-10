import AppKit
import Foundation

@main
struct NativeTests {
    static func sameFile(_ a: URL?, _ b: URL) -> Bool {
        guard let a, let lhs = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
              let rhs = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "island-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "原文件.txt")
        try Data("do not delete me".utf8).write(to: original)
        let folder = root.appending(path: "文件夹")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shelf = FileShelf(directory: root.appending(path: "state"))
        shelf.add([original, folder, original])
        precondition(shelf.entries.count == 2, "Duplicate files must not create extra entries")
        let id = shelf.entries[0].id
        let restored = FileShelf(directory: root.appending(path: "state"))
        precondition(restored.entries.count == 2 && sameFile(restored.url(for: id), original), "References must survive restart")
        let moved = root.appending(path: "移动后的原文件.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        precondition(sameFile(shelf.url(for: id), moved), "Bookmark must follow a moved file")
        shelf.add([moved])
        precondition(shelf.entries.count == 2, "Moved file must still deduplicate")
        shelf.remove(id)
        precondition(FileManager.default.fileExists(atPath: moved.path), "Removing references must preserve originals")
        shelf.add([moved])
        let movedID = shelf.entries.last!.id
        try FileManager.default.removeItem(at: moved)
        precondition(shelf.url(for: movedID) == nil, "Deleted file must become unavailable")
        shelf.relink(movedID, to: original) // nonexistent target must fail and preserve the original entry
        precondition(shelf.entries.last?.id == movedID)
        let replacement = root.appending(path: "replacement.txt")
        try Data("replacement".utf8).write(to: replacement)
        shelf.relink(movedID, to: replacement)
        precondition(sameFile(shelf.url(for: movedID), replacement))
        shelf.remove(nil)
        precondition(FileManager.default.fileExists(atPath: replacement.path) && FileManager.default.fileExists(atPath: folder.path))
        let badState = FileShelf(directory: replacement)
        var reportedFailure = false
        badState.failure = { _ in reportedFailure = true }
        badState.add([replacement])
        precondition(reportedFailure && badState.entries.isEmpty, "Failed persistence must roll back")
        let single: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 80.0, "windowDurationMins": 300, "resetsAt": 2_000_000_000.0]]]
        let windows = quotaWindows(single)
        precondition(windows.count == 1 && windows[0].remaining == 20 && windows[0].name == "5 小时额度")
        precondition(quotaWindows(["rateLimits": ["primary": ["usedPercent": -1.0]]]).isEmpty)
        precondition(quotaWindows(["rateLimits": ["primary": NSNull()]]).isEmpty)
        precondition(quotaWindows([:]).isEmpty, "Missing data must not fabricate zero quota")
        let multi: [String: Any] = ["rateLimitsByLimitId": ["a": ["primary": ["usedPercent": 25.0]], "b": ["secondary": ["usedPercent": 95.0, "windowDurationMins": 10080]]]]
        precondition(quotaWindows(multi).count == 2, "Distinct quota buckets must stay distinct")
        var seen = Set<String>()
        let low = QuotaWindow(id: "a", name: "周额度", used: 81, resetsAt: 200)
        precondition(quotaAlerts([low], now: 100, seen: &seen).count == 1)
        precondition(quotaAlerts([low], now: 100, seen: &seen).isEmpty)
        let critical = QuotaWindow(id: "a", name: "周额度", used: 96, resetsAt: 200)
        precondition(quotaAlerts([critical], now: 100, seen: &seen).count == 1)
        precondition(quotaAlerts([critical], now: 100, seen: &seen).isEmpty)
        let reset = QuotaWindow(id: "a", name: "周额度", used: 96, resetsAt: 400)
        precondition(quotaAlerts([reset], now: 300, seen: &seen).count == 1, "A new period must allow one alert, not two")
        precondition(quotaAlerts([low], now: 300, seen: &seen).isEmpty, "Expired windows must not alert")
        precondition(IslandView.notes.size == NSSize(width: 480, height: 240))
        precondition(IslandView.files.size == IslandView.notes.size)
        precondition(IslandView.tools.size == NSSize(width: 480, height: 220))
        precondition(IslandView.settings.size == NSSize(width: 480, height: 300))
        let smallScreen = NSRect(x: -400, y: 0, width: 320, height: 200)
        let fitted = islandFittedSize(IslandView.settings.size, visible: smallScreen)
        precondition(fitted.width <= 312 && fitted.height <= 194)
        // Both high-refresh and 60 Hz displays must follow the same spring path.
        var slow = IslandSpring(128), fast = IslandSpring(128)
        slow.target = 480; fast.target = 480
        for _ in 0..<12 { slow.step(seconds: 1.0 / 60, frequency: 32) }
        for _ in 0..<24 { fast.step(seconds: 1.0 / 120, frequency: 32) }
        precondition(abs(slow.value - fast.value) < 0.0001)
        precondition(slow.value > 475 && slow.value < 480)
        let position = slow.value, velocity = slow.velocity
        slow.target = 128
        precondition(slow.value == position && slow.velocity == velocity, "Reversal must preserve presentation and velocity")
        for _ in 0..<120 { slow.step(seconds: 1.0 / 120, frequency: 40) }
        precondition(abs(slow.value - 128) < 0.001 && slow.settled)
        precondition(islandContentOpacity(0.85) == 0 && islandContentOpacity(1) == 1)
        precondition(islandContentOpacity(0.95) > 0 && islandContentOpacity(0.95) < 1)
        precondition(islandCollapsedSize(edge: "top") == NSSize(width: 128, height: 28))
        let visible = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let anchor = NSPoint(x: 666, y: visible.maxY - islandTopPadding)
        let closed = islandFrame(anchor: anchor, edge: "top", size: islandCollapsedSize(edge: "top"), visible: visible)
        let opened = islandFrame(anchor: anchor, edge: "top", size: IslandView.notes.size, visible: visible)
        precondition(closed.maxY == visible.maxY && opened.maxY == visible.maxY, "No invisible window may cover the menu bar")
        precondition(closed.maxY - islandTopPadding == anchor.y && opened.maxY - islandTopPadding == anchor.y, "Opening must preserve the island's top anchor")
        precondition(closed.midX == opened.midX, "Opening must stay centered on the ghost")
        for edge in ["top", "left", "right"] {
            for size in [islandCollapsedSize(edge: edge), IslandView.notes.size, IslandView.tools.size, IslandView.settings.size] {
                let frame = islandFrame(anchor: NSPoint(x: -200, y: 4000), edge: edge, size: size, visible: visible)
                precondition(frame.minX + islandGlowPadding >= visible.minX + 4)
                precondition(frame.maxX - islandGlowPadding <= visible.maxX - 4)
                precondition(frame.maxY <= visible.maxY)
                let bottom = islandFrame(anchor: NSPoint(x: 4000, y: -200), edge: edge, size: size, visible: visible)
                precondition(bottom.minY + islandGlowPadding >= visible.minY + 4)
                // Every intermediate frame shares its expanded destination's anchor.
                for step in 0...20 {
                    let fraction = Double(step) / 20
                    let compact = islandCollapsedSize(edge: edge)
                    let intermediate = NSSize(width: compact.width + (size.width - compact.width) * fraction,
                                              height: compact.height + (size.height - compact.height) * fraction)
                    let morph = islandFrame(anchor: anchor, edge: edge, size: intermediate, visible: visible)
                    precondition(morph.maxY == visible.maxY)
                    if edge == "top" { precondition(abs(morph.midX - closed.midX) < 0.001) }
                }
            }
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contourURL = sourceRoot.appending(path: "native/assets/miffy-shape.json")
        if FileManager.default.fileExists(atPath: contourURL.path) {
        let contour = try JSONDecoder().decode(MiffyContour.self, from: Data(contentsOf: sourceRoot.appending(path: "native/assets/miffy-shape.json")))
        let demoURL = sourceRoot.appending(path: "prototypes/miffy-demo/index.html")
        if FileManager.default.fileExists(atPath: demoURL.path) {
        let demoHTML = try String(contentsOf: demoURL, encoding: .utf8)
        precondition(demoHTML.contains("stroke=\"#202020\" stroke-width=\"\(contour.strokeWidth)\""), "Native outline width must match the approved demo")
        }
        for step in 0...30 {
            let p = Double(step)/30
            let size = NSSize(width:78+(480-78)*p,height:112+(306-112)*p)
            let path = MiffySkin.path(size:size,progress:p,contour:contour)
            precondition(path.boundingBox.minX >= -0.01 && path.boundingBox.maxX <= size.width+0.01)
            precondition(path.boundingBox.minY >= -0.01 && path.boundingBox.maxY <= size.height+0.01)
        }
        let head = MiffySkin.path(size:MiffySkin.compact,progress:0,contour:contour)
        precondition(head.contains(CGPoint(x:39,y:20)))
        precondition(!head.contains(CGPoint(x:(244.0-65)/367*78,y:112-(180.0-38)/530*112)), "Ear gap must stay transparent")
        let miffyClosed = islandFrame(anchor:anchor,edge:"top",size:MiffySkin.compact,visible:visible,collapsedSize:MiffySkin.compact)
        let miffyOpen = islandFrame(anchor:anchor,edge:"top",size:NSSize(width:480,height:306),visible:visible,collapsedSize:MiffySkin.compact)
        precondition(miffyClosed.midX == miffyOpen.midX && miffyClosed.maxY == miffyOpen.maxY)
        } else {
            let fallback = MiffySkin.path(size: IslandView.notes.size, progress: 1, contour: nil)
            precondition(fallback.boundingBox == NSRect(origin: .zero, size: IslandView.notes.size))
        }
        print("PASS: file references, folders, deduplication, rename, persistence, deletion, relink, removal safety, rollback, quota parsing, alerts, view sizes, reversible springs, refresh-rate independence, top alignment and frame boundaries")
    }
}
