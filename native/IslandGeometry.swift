import AppKit

// The top margin is deliberately smaller than the glow margins, so the actual island
// sits close to the menu bar without an invisible window covering menu items.
let islandTopPadding: CGFloat = 2
let islandGlowPadding: CGFloat = 20
enum IslandView: String {
    case notes, files, tools, settings

    var size: NSSize {
        NSSize(width: 480, height: self == .settings ? 300 : self == .tools ? 220 : 240)
    }
}
func islandCollapsedSize(edge: String) -> NSSize {
    edge == "top" ? NSSize(width: 128, height: 28) : NSSize(width: 26, height: 74)
}

func islandFittedSize(_ size: NSSize, visible: NSRect) -> NSSize {
    NSSize(width: min(size.width, max(1, visible.width - 8)), height: min(size.height, max(1, visible.height - islandTopPadding - 4)))
}

func islandFrame(anchor: NSPoint, edge: String, size: NSSize, visible: NSRect, collapsedSize: NSSize? = nil) -> NSRect {
    let collapsed = collapsedSize ?? islandCollapsedSize(edge: edge)
    let offset: CGFloat = edge == "top" ? (collapsed.width - size.width) / 2 : (edge == "right" ? collapsed.width - size.width : 0)
    var frame = NSRect(x: anchor.x + offset - islandGlowPadding,
                       y: anchor.y - size.height - islandGlowPadding,
                       width: size.width + islandGlowPadding * 2,
                       height: size.height + islandGlowPadding + islandTopPadding)
    frame.origin.x = min(max(frame.minX, visible.minX - islandGlowPadding + 4), visible.maxX - frame.width + islandGlowPadding - 4)
    frame.origin.y = min(max(frame.minY, visible.minY - islandGlowPadding + 4), visible.maxY - frame.height)
    return frame
}

final class IslandRootView: NSView {
    var hoverChanged: ((Bool) -> Void)?
    var surfaceRect = NSRect.zero
    var surfaceRadius: CGFloat = 14
    var surfacePath: CGPath?
    private var area: NSTrackingArea?
    private var inside = false
    private var lastPointer: NSPoint?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: surfaceRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        self.area = area
        addTrackingArea(area)
    }
    func reconcileHover() {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        var entered = surfacePath?.contains(NSPoint(x:point.x-surfaceRect.minX,y:point.y-surfaceRect.minY)) ?? NSBezierPath(roundedRect: surfaceRect, xRadius: surfaceRadius, yRadius: surfaceRadius).contains(point)
        // A morph can move an ear away from a stationary pointer. Retain the
        // hover intent until the pointer actually moves, avoiding a close loop.
        if inside && lastPointer == screenPoint { entered = true }
        lastPointer = screenPoint
        guard entered != inside else { return }
        inside = entered
        hoverChanged?(entered)
    }
    override func mouseEntered(with event: NSEvent) { reconcileHover() }
    override func mouseMoved(with event: NSEvent) { reconcileHover() }
    override func mouseExited(with event: NSEvent) { reconcileHover() }
}
