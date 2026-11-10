import AppKit
import ApplicationServices

struct MessageApp {
    let id: String
    let name: String
}
final class UnreadMonitor {
    static let apps = [MessageApp(id: "com.tencent.xinWeChat", name: "微信"), MessageApp(id: "com.tencent.qq", name: "QQ"), MessageApp(id: "com.electron.lark", name: "飞书")]
    var changed: (([[String: Any]]) -> Void)?
    var alert: ((String) -> Void)?
    private var timer: Timer?
    private var enabled: Set<String> = []
    private var baseline: [String: String] = [:]
    private var supported: Set<String> = []
    private var lastPayload = Data()
    private var rows: [[String: Any]] = []
    init() { enabled = Set(UserDefaults.standard.stringArray(forKey: "unreadApps") ?? []) }
    private func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }; return value
    }
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        scan()
    }
    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.scan() } }
    }
    func setEnabled(_ id: String, _ value: Bool) {
        guard Self.apps.contains(where: { $0.id == id }), !value || supported.contains(id) else { return }
        if value { enabled.insert(id); baseline.removeValue(forKey: id) } else { enabled.remove(id); baseline.removeValue(forKey: id) }
        UserDefaults.standard.set(Array(enabled), forKey: "unreadApps"); scan()
    }
    func scan() {
        let trusted = AXIsProcessTrusted()
        var tiles: [AXUIElement] = []
        if trusted, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let root = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            // Only inspect Dock item metadata, never notification bodies or chat windows.
            let roots = attr(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for list in roots { tiles += attr(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        }
        supported.removeAll()
        rows = Self.apps.map { app in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty
            let tile = tiles.first { tile in
                if let tileURL = attr(tile, kAXURLAttribute) as? URL { return tileURL.standardizedFileURL == url?.standardizedFileURL }
                return (attr(tile, kAXTitleAttribute) as? String) == app.name
            }
            var names: CFArray?
            if let tile { _ = AXUIElementCopyAttributeNames(tile, &names) }
            let readable = (names as? [String] ?? []).contains("AXStatusLabel")
            if readable { supported.insert(app.id) }
            let badge = tile.flatMap { attr($0, "AXStatusLabel") as? String } ?? ""
            let active = enabled.contains(app.id) && trusted && readable && running
            if active {
                if let previous = baseline[app.id], previous != badge, !badge.isEmpty {
                    let increased: Bool
                    if let old = Int(previous), let new = Int(badge) { increased = new > old }
                    else { increased = previous.isEmpty }
                    if increased { alert?(app.name + "有未读提醒") }
                }
                baseline[app.id] = badge
            } else { baseline.removeValue(forKey: app.id) }
            let reason = url == nil ? "未安装" : !running ? "未运行" : !trusted ? "需要授权" : !readable ? "暂不支持" : "可用"
            return ["id": app.id, "name": app.name, "supported": trusted && readable && running, "enabled": enabled.contains(app.id), "badge": active ? badge : "", "reason": reason, "icon": url.map { pngDataURL(NSWorkspace.shared.icon(forFile: $0.path)) } ?? ""]
        }
        if let payload = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys), payload != lastPayload { lastPayload = payload; changed?(rows) }
    }
    func open(_ id: String) {
        guard Self.apps.contains(where: { $0.id == id }), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
