import AppKit
import WebKit
import QuartzCore

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var mouseEvent: ((NSEvent) -> Void)?
    var contentVisible = false
    var headerInset = 0.0
    var indicatorRect = NSRect.zero
    var activateGhost: (() -> Void)?
    private var ghostPressed = false
    var dragBegan: (() -> Void)?
    var dragEnded: (() -> Void)?
    private var dragStart: NSPoint?
    private var startOrigin = NSPoint.zero
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseDragged].contains(event.type) { mouseEvent?(event) }
        switch event.type {
        case .leftMouseDown:
            let point = event.locationInWindow
            let fromTop = frame.height - point.y
            let inHeader = fromTop >= islandTopPadding + headerInset + 5 && fromTop <= islandTopPadding + headerInset + 43 && point.x >= 160 && point.x <= frame.width - 180
            let inGhost = !contentVisible && point.x >= 20 && point.x <= frame.width - 20 && fromTop >= islandTopPadding && fromTop <= frame.height - islandGlowPadding
            ghostPressed = inGhost && !indicatorRect.contains(point)
            let inEars = headerInset > 0 && fromTop < islandTopPadding + headerInset && abs(point.x-frame.width/2) < 60
            if (contentVisible && (inHeader || inEars)) || inGhost {
                dragStart = convertPoint(toScreen: point)
                startOrigin = frame.origin
            } else { dragStart = nil }
        case .leftMouseDragged:
            if let start = dragStart {
                let current = convertPoint(toScreen: event.locationInWindow)
                let dx = current.x - start.x, dy = current.y - start.y
                if dragging || hypot(dx, dy) >= 4 {
                    if !dragging { dragging = true; dragBegan?(); startOrigin = frame.origin }
                    setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
                    return
                }
            }
        case .leftMouseUp:
            dragStart = nil
            if dragging {
                dragging = false
                ghostPressed = false
                dragEnded?()
                return
            }
            if ghostPressed { ghostPressed = false; activateGhost?(); return }
        default: break
        }
        super.sendEvent(event)
    }

}

@MainActor
final class IslandApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var panel: IslandPanel!
    private var webView: IslandWebView!
    private let shelf = FileShelf()
    private let agents = AgentUsage()
    private let unread = UnreadMonitor()
    private var surface: IslandSurface!
    private var root: IslandRootView!
    private var theme = "ink"
    private var paper = NSColor(calibratedWhite: 8.0 / 255, alpha: 1)
    private var view = IslandView.notes
    private var width = IslandSpring(128)
    private var height = IslandSpring(28)
    private var progress = IslandSpring(0)
    private var displayLink: CADisplayLink?
    private var lastFrameTime = 0.0
    private var closeReported = true
    private var unreadApp: String?
    private var quotaLow = false
    private var surfaceOpacity = 1.0
    private var filePicker: NSOpenPanel?
    private var statusItem: NSStatusItem!
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var dragging = false
    private var anchor = NSPoint.zero // top-left of the collapsed island, in screen coordinates
    private var expanded = false
    private var edge = "top"
    private let padding = islandGlowPadding
    private var positionURL: URL {
        URL.applicationSupportDirectory.appending(path: "IslandNote/position-v1.json")
    }
    private var dataURL: URL {
        URL.applicationSupportDirectory.appending(path: "IslandNote/note-v1.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "island")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__islandMiffyAvailable = \(MiffySkin.available);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // The JSON is encoded as a JS string, then parsed; note text never becomes executable code.
        if let data = try? Data(contentsOf: dataURL),
           let raw = String(data: data, encoding: .utf8),
           let literal = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
           let encoded = String(data: literal, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.__islandSaved = JSON.parse(\(encoded));",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = IslandWebView(frame: .zero, configuration: configuration)
        webView.registerForDraggedTypes([.fileURL])
        webView.dropHover = { [weak self] hover in self?.emit("dropHover", hover) }
        webView.dropped = { [weak self] urls in self?.shelf.add(urls); self?.emit("dropComplete", self?.shelf.touchedIDs ?? []) }
        shelf.changed = { [weak self] in self?.publishFiles() }
        shelf.failure = { [weak self] message in self?.emit("toast", message) }
        agents.changed = { [weak self] data in
            guard let self else { return }
            self.quotaLow = data["enabled"] as? Bool == true && (data["windows"] as? [[String: Any]] ?? []).contains {
                ($0["remaining"] as? Double ?? 100) < 20 && ($0["resetsAt"] as? Double ?? 0) > Date().timeIntervalSince1970
            }
            self.updateIndicator(); self.emit("agents", data)
        }
        agents.alert = { [weak self] message in self?.emit("alert", message) }
        unread.changed = { [weak self] rows in
            guard let self else { return }
            self.unreadApp = rows.first { $0["enabled"] as? Bool == true && $0["supported"] as? Bool == true && !($0["badge"] as? String ?? "").isEmpty }?["id"] as? String
            self.updateIndicator(); self.emit("unread", rows)
        }
        unread.alert = { [weak self] message in self?.emit("alert", message) }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.wantsLayer = true
        webView.autoresizingMask = []
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.dragBegan = { [weak self] in
            self?.dragging = true
            self?.stopMotion()
            self?.webView.evaluateJavaScript("window.islandHost.dragStarted()", completionHandler: nil)
        }
        panel.dragEnded = { [weak self] in
            guard let self else { return }
            self.dragging = false
            self.captureAnchor()
            self.layoutPanel(animated: true)
            self.webView.evaluateJavaScript("window.islandHost.dragEnded()", completionHandler: nil)
        }
        panel.activateGhost = { [weak self] in self?.showNote() }
        panel.mouseEvent = { [weak self] event in self?.webView.lastMouseEvent = event }
        panel.title = "随手记"
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        root = IslandRootView()
        root.wantsLayer = true
        root.hoverChanged = { [weak self] entered in self?.emit("hover", entered) }
        surface = IslandSurface()
        surface.clip.addSubview(webView)
        surface.installIndicator(target: self, action: #selector(openIndicator))
        root.addSubview(surface)
        panel.contentView = root
        restoreAnchor()
        layoutPanel()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        configureMenu()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.outsideClick() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.outsideClick() }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        guard let page = Bundle.main.url(forResource: "index", withExtension: "html") else {
            let alert = NSAlert(); alert.messageText = "缺少便签界面"; alert.informativeText = "请重新运行 build 脚本生成完整应用。"; alert.runModal(); NSApp.terminate(nil); return
        }
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    private var collapsedSize: NSSize { theme == "miffy" ? MiffySkin.compact : islandCollapsedSize(edge: edge) }
    private var currentScreen: NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func restoreAnchor() {
        let defaults = UserDefaults.standard
        var restored = false
        if let data = try? Data(contentsOf: positionURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let x = saved["x"] as? Double, let y = saved["y"] as? Double,
           let savedEdge = saved["edge"] as? String, ["top", "left", "right"].contains(savedEdge) {
            anchor = NSPoint(x: x, y: y); edge = savedEdge; restored = true
        } else if defaults.object(forKey: "anchorX") != nil {
            anchor = NSPoint(x: defaults.double(forKey: "anchorX"), y: defaults.double(forKey: "anchorY"))
            edge = defaults.string(forKey: "edge") ?? "top"
            restored = true
        } else { resetAnchor() }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(anchor) }) { resetAnchor(); restored = false }
        if !defaults.bool(forKey: "ghostSizeV23") {
            if restored && edge == "top" { anchor.x -= 10; storeAnchor() }
            defaults.set(true, forKey: "ghostSizeV23")
        }
        if !UserDefaults.standard.bool(forKey: "topAlignmentV21") {
            if edge == "top" { anchor.y = currentScreen.visibleFrame.maxY - islandTopPadding; storeAnchor() }
            UserDefaults.standard.set(true, forKey: "topAlignmentV21")
        }
    }

    private func resetAnchor() {
        let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        switch edge {
        case "left": anchor = NSPoint(x: visible.minX + 8, y: visible.midY + 37)
        case "right": anchor = NSPoint(x: visible.maxX - 34, y: visible.midY + 37)
        default: anchor = NSPoint(x: visible.midX - collapsedSize.width / 2, y: visible.maxY - 2)
        }
        storeAnchor()
    }

    private func storeAnchor() {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["x": anchor.x, "y": anchor.y, "edge": edge])
            try FileManager.default.createDirectory(at: positionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: positionURL, options: .atomic)
        } catch {
            // UserDefaults remains the fallback when the position file cannot be written.
        }
        UserDefaults.standard.set(anchor.x, forKey: "anchorX")
        UserDefaults.standard.set(anchor.y, forKey: "anchorY")
        UserDefaults.standard.set(edge, forKey: "edge")
    }

    private var presentedSize: NSSize { NSSize(width: width.value, height: height.value) }
    private var contentSize: NSSize { islandFittedSize(NSSize(width:view.size.width,height:view.size.height+(theme == "miffy" ? MiffySkin.earHeight : 0)), visible: currentScreen.visibleFrame) }

    private func layoutPanel(animated: Bool = false) {
        let target = expanded ? contentSize : collapsedSize
        width.target = target.width; height.target = target.height
        progress.target = expanded ? 1 : 0
        guard !dragging else { return }
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopMotion()
            width.finish(); height.finish(); progress.finish()
            renderSurface()
            reportMotionEnd()
        } else if displayLink == nil {
            lastFrameTime = CACurrentMediaTime()
            let link = panel.displayLink(target: self, selector: #selector(animateFrame(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func animateFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        lastFrameTime = now
        let frequency = expanded ? 32.0 : 40.0
        width.step(seconds: dt, frequency: frequency)
        height.step(seconds: dt, frequency: frequency)
        progress.step(seconds: dt, frequency: frequency)
        let finished = width.settled && height.settled && abs(progress.value - progress.target) < 0.002
        if finished { width.finish(); height.finish(); progress.finish(); stopMotion() }
        renderSurface()
        if finished { reportMotionEnd() }
    }

    private func stopMotion() { displayLink?.invalidate(); displayLink = nil }

    private func renderSurface() {
        let size = presentedSize
        let phase = min(1, max(0, progress.value))
        let frame = islandFrame(anchor: anchor, edge: edge, size: size, visible: currentScreen.visibleFrame, collapsedSize: collapsedSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        surface.frame = NSRect(x: padding, y: padding, width: size.width, height: size.height)
        surface.update(size: size, progress: phase, edge: edge, theme: theme, paper: paper, opacity: surfaceOpacity)
        let content = contentSize
        let inset = theme == "miffy" ? MiffySkin.earHeight : 0
        panel.headerInset = inset
        let x = edge == "top" ? (size.width - content.width) / 2 : edge == "right" ? size.width - content.width : 0
        webView.frame = NSRect(x: x, y: size.height - content.height, width: content.width, height: content.height)
        webView.layer?.opacity = Float(islandContentOpacity(phase))
        panel.contentVisible = phase > 0.95
        panel.indicatorRect = surface.indicator.isHidden ? .zero : surface.indicator.frame.offsetBy(dx: padding, dy: padding)
        CATransaction.commit()
        root.surfaceRect = surface.frame
        root.surfacePath = surface.silhouette
        let compactRadius = edge == "top" ? 14.0 : 13.0
        root.surfaceRadius = compactRadius + (28 - compactRadius) * phase
        root.updateTrackingAreas()
        root.reconcileHover()
    }

    private func updateIndicator() {
        let image: NSImage?
        if let id = unreadApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if quotaLow {
            image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                NSColor(red: 0.85, green: 0.65, blue: 0.34, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill(); return true
            }
        } else { image = nil }
        surface.setIndicator(image: image, label: unreadApp == nil ? "查看 Codex 额度" : "打开未读 App")
        renderSurface()
    }

    @objc private func openIndicator() {
        if let id = unreadApp { unread.open(id) }
        else { webView.evaluateJavaScript("open()", completionHandler: nil) }
    }

    private func reportMotionEnd() {
        if !expanded && !closeReported {
            closeReported = true
            emit("motionEnded", false)
        }
    }

    @objc private func accessibilityChanged() {
        surface.configureBlink()
        layoutPanel(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        panel.orderFrontRegardless()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let page = Bundle.main.url(forResource: "index", withExtension: "html")
        decisionHandler(navigationAction.request.url?.standardizedFileURL.path == page?.standardizedFileURL.path ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            if let value = body["edge"] as? String, ["top", "left", "right"].contains(value), value != edge { edge = value; resetAnchor() }
            layoutPanel()
            publishFiles(); agents.start(); unread.start()
        case "theme":
            let oldTheme = theme
            if let value = body["theme"] as? String, ["warm","glass","ink","pink","miffy"].contains(value) { theme = value == "miffy" && !MiffySkin.available ? "ink" : value }
            if let value = body["opacity"] as? Double { surfaceOpacity = min(1, max(0.35, value / 100)) }
            if let hex = body["paper"] as? String, hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) {
                paper = NSColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
            }
            if oldTheme != theme {
                let oldSize = oldTheme == "miffy" ? MiffySkin.compact : islandCollapsedSize(edge: edge)
                if edge == "top" { anchor.x += (oldSize.width-collapsedSize.width)/2 }
                else if edge == "right" { anchor.x += oldSize.width-collapsedSize.width }
                storeAnchor(); layoutPanel(animated: true)
            } else { renderSurface() }
        case "filesRefresh": publishFiles()
        case "filesChoose": chooseFile(relink: nil)
        case "fileRelink": if let id = body["id"] as? String { chooseFile(relink: id) }
        case "fileRemove": if let id = body["id"] as? String { shelf.remove(id) }
        case "filesClear": shelf.remove(nil)
        case "fileOpen", "fileReveal", "fileDrag":
            guard let id = body["id"] as? String, let url = shelf.url(for: id) else { publishFiles(); emit("toast", "原文件不可用，请重新定位"); return }
            if type == "fileOpen" { NSWorkspace.shared.open(url) }
            else if type == "fileReveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { webView.dragFile(url) }
        case "agentsEnable": if let enabled = body["enabled"] as? Bool { agents.setEnabled(enabled) }
        case "agentsRefresh": agents.refresh()
        case "unreadCheck": unread.scan()
        case "unreadPermission": unread.requestPermission()
        case "unreadEnable": if let id = body["id"] as? String, let enabled = body["enabled"] as? Bool { unread.setEnabled(id, enabled) }
        case "unreadOpen": if let id = body["id"] as? String { unread.open(id) }
        case "state":
            guard let value = body["expanded"] as? Bool else { return }
            let nextView = (body["view"] as? String).flatMap(IslandView.init(rawValue:)) ?? .notes
            guard value != expanded || nextView != view else { return }
            expanded = value; view = nextView
            if expanded { closeReported = false }
            layoutPanel(animated: true)
            if expanded { panel.orderFrontRegardless() }
        case "edge":
            guard let value = body["edge"] as? String, ["top", "left", "right"].contains(value) else { return }
            edge = value; resetAnchor(); layoutPanel()
        case "save":
            guard let value = body["value"], JSONSerialization.isValidJSONObject(value) else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dataURL, options: .atomic)
                webView.evaluateJavaScript("window.islandHost.saved(true)", completionHandler: nil)
                if body["quit"] as? Bool == true { NSApp.terminate(nil) }
            } catch {
                webView.evaluateJavaScript("window.islandHost.saved(false)", completionHandler: nil)
            }
        default: break
        }
    }

    private func emit(_ method: String, _ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.islandV2?.[\"\(method)\"](\(json))", completionHandler: nil)
    }
    private func publishFiles() { emit("files", shelf.payload()) }
    private func chooseFile(relink id: String?) {
        guard filePicker == nil else { filePicker?.makeKeyAndOrderFront(nil); return }
        let picker = NSOpenPanel()
        filePicker = picker
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = id == nil
        picker.prompt = id == nil ? "添加入口" : "重新定位"
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard let self else { return }
            self.filePicker = nil
            guard response == .OK else { return }
            if let id, let url = picker.url { self.shelf.relink(id, to: url) }
            else { self.shelf.add(picker.urls); self.emit("fileFocus", self.shelf.touchedIDs) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { stopMotion(); agents.stop() }

    private func captureAnchor() {
        let size = presentedSize
        let offset: CGFloat = edge == "top" ? (collapsedSize.width - size.width) / 2 : (edge == "right" ? collapsedSize.width - size.width : 0)
        anchor = NSPoint(x: panel.frame.minX + padding - offset, y: panel.frame.maxY - islandTopPadding)
        renderSurface()
        // Save the clamped position, rather than an unreachable off-screen position.
        anchor = NSPoint(x: panel.frame.minX + padding - offset, y: panel.frame.maxY - islandTopPadding)
        storeAnchor()
    }

    private func outsideClick() {
        guard expanded, !dragging, filePicker == nil else { return }
        webView.evaluateJavaScript("window.islandHost.outside()", completionHandler: nil)
    }

    @objc private func screenChanged() { captureAnchor(); layoutPanel(animated: true) }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 3, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 5, width: 3, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "随手记"
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "打开随手记", action: #selector(showNote), keyEquivalent: "")
        show.target = self
        let reset = menu.addItem(withTitle: "移回屏幕顶部", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出随手记", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let quitMain = appMenu.addItem(withTitle: "退出随手记", action: #selector(quitApp), keyEquivalent: "q")
        quitMain.target = self
        let appItem = NSMenuItem(); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showNote() {
        panel.makeKeyAndOrderFront(nil)
        webView.evaluateJavaScript("document.querySelector('.trigger').click()", completionHandler: nil)
    }
    @objc private func resetPosition() {
        edge = "top"; resetAnchor(); layoutPanel()
        webView.evaluateJavaScript("window.islandHost.resetPosition()", completionHandler: nil)
        panel.orderFrontRegardless()
    }
    @objc private func quitApp() {
        webView.evaluateJavaScript("window.islandHost.saveForQuit()") { _, error in
            // An uninitialized page cannot contain edits; normal quits wait for the atomic save above.
            if error != nil { NSApp.terminate(nil) }
        }
    }
}

#if !TESTING
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = IslandApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
