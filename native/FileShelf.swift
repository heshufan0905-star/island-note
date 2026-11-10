import AppKit
import WebKit

struct ShelfEntry: Codable {
    var id: String
    var bookmark: Data
    var lastPath: String
}

final class FileShelf {
    private(set) var entries: [ShelfEntry] = []
    private(set) var touchedIDs: [String] = []
    private let storageURL: URL
    var changed: (() -> Void)?
    var failure: ((String) -> Void)?
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "IslandNote")) {
        storageURL = directory.appending(path: "files-v2.json")
        if let data = try? Data(contentsOf: storageURL), let saved = try? JSONDecoder().decode([ShelfEntry].self, from: data) { entries = saved }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: storageURL, options: .atomic)
    }
    func resolve(_ entry: ShelfEntry) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path) {
            if stale, let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].bookmark = bookmark; entries[index].lastPath = url.path; try? persist()
            }
            return url
        }
        // Do not silently reattach to a different file created at the old path.
        return nil
    }
    func add(_ urls: [URL]) {
        let before = entries
        touchedIDs = []
        do {
            for url in urls where url.isFileURL {
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: canonical.path) else { continue }
                if let existing = entries.first(where: { resolve($0)?.standardizedFileURL.resolvingSymlinksInPath() == canonical }) { touchedIDs.append(existing.id); continue }
                let bookmark = try canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                let id = UUID().uuidString
                entries.append(ShelfEntry(id: id, bookmark: bookmark, lastPath: canonical.path))
                touchedIDs.append(id)
            }
            try persist(); changed?()
        } catch { entries = before; touchedIDs = []; failure?("未能保存文件入口，请重试") }
    }
    func remove(_ id: String?) {
        let before = entries
        if let id { entries.removeAll { $0.id == id } } else { entries.removeAll() }
        do { try persist(); changed?() } catch { entries = before; failure?("未能保存更改，请重试") }
    }
    func relink(_ id: String, to url: URL) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries
        do {
            entries[index].bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            entries[index].lastPath = url.path
            try persist(); changed?()
        } catch { entries = before; failure?("无法关联此文件") }
    }
    func url(for id: String) -> URL? { entries.first(where: { $0.id == id }).flatMap { resolve($0) } }
    func payload() -> [[String: Any]] {
        entries.map { entry in
            let url = resolve(entry)
            let icon = NSWorkspace.shared.icon(forFile: url?.path ?? entry.lastPath)
            return ["id": entry.id, "name": (url?.lastPathComponent ?? URL(fileURLWithPath: entry.lastPath).lastPathComponent), "path": url?.path ?? entry.lastPath, "available": url != nil, "icon": pngDataURL(icon)]
        }
    }
}

func pngDataURL(_ image: NSImage) -> String {
    let small = NSImage(size: NSSize(width: 32, height: 32))
    small.lockFocus(); image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32)); small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return "" }
    return "data:image/png;base64," + png.base64EncodedString()
}

final class IslandWebView: WKWebView, NSDraggingSource {
    var dropped: (([URL]) -> Void)?
    var dropHover: ((Bool) -> Void)?
    var lastMouseEvent: NSEvent?
    private var draggingFiles = false
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? IslandWebView !== self,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        draggingFiles = true; dropHover?(true); return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingFiles ? .copy : [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { draggingFiles = false; dropHover?(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { draggingFiles }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { dropHover?(false); return false }
        dropped?(urls); draggingFiles = false; dropHover?(false); return true
    }
    func dragFile(_ url: URL) {
        guard let event = lastMouseEvent, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        evaluateJavaScript("window.islandHost.fileDragEnded()", completionHandler: nil)
    }
}
