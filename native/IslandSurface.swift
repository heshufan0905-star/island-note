import AppKit
import QuartzCore

private final class IslandEyeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// The material, clip and eyes live in one native surface. WebKit only supplies
// content, so a cross-process layout cannot split the silhouette during a morph.
final class IslandSurface: NSView {
    let clip = NSView()
    let indicator = NSButton()
    private var hasIndicator = false
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private let halo = CALayer()
    private let eyeView = IslandEyeView()
    private let eyes = CALayer()
    private let miffyInk = MiffyInkView()
    private let miffyMask = CAShapeLayer()
    private let miffyBorder = CAShapeLayer()
    private let miffyBorderMask = CAShapeLayer()
    private(set) var silhouette: CGPath?
    private let leftEye = CALayer()
    private let rightEye = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(halo)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        addSubview(clip)
        material.blendingMode = .behindWindow
        material.material = .hudWindow
        material.state = .active
        clip.addSubview(material)
        tint.wantsLayer = true
        clip.addSubview(tint)
        eyeView.wantsLayer = true
        addSubview(eyeView)
        eyeView.layer?.addSublayer(eyes)
        eyes.addSublayer(leftEye); eyes.addSublayer(rightEye)
        leftEye.cornerRadius = 2; rightEye.cornerRadius = 2
        addSubview(miffyInk)
        layer?.addSublayer(miffyBorder)
        miffyBorder.fillColor = NSColor.clear.cgColor
        miffyBorder.strokeColor = NSColor(calibratedWhite: 0.125, alpha: 1).cgColor
        // Match the demo's 4.4-point stroke, clipped to the inside. A half-width
        // stroke on the view edge gets clipped again and looks much thinner.
        miffyBorder.lineWidth = MiffySkin.strokeWidth
        miffyBorder.lineJoin = .round
        // AppKit can reorder its backing layers as subviews are laid out.
        // Keep the outline above the opaque paper so its inner half stays visible.
        miffyBorder.zPosition = 2
        miffyBorderMask.fillColor = NSColor.black.cgColor
        miffyBorder.mask = miffyBorderMask
        configureBlink()
    }

    required init?(coder: NSCoder) { nil }

    func installIndicator(target: AnyObject, action: Selector) {
        indicator.isBordered = false
        indicator.title = ""
        indicator.imageScaling = .scaleProportionallyDown
        indicator.target = target; indicator.action = action
        indicator.isHidden = true
        clip.addSubview(indicator)
    }

    func setIndicator(image: NSImage?, label: String) {
        hasIndicator = image != nil
        indicator.image = image
        indicator.setAccessibilityLabel(label)
    }

    func configureBlink() {
        eyes.removeAnimation(forKey: "blink")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.12, 1, 1]
        blink.keyTimes = [0, 0.70, 0.715, 0.73, 1]
        blink.duration = 7.5
        blink.repeatCount = .infinity
        eyes.add(blink, forKey: "blink")
    }

    func update(size: NSSize, progress: Double, edge: String, theme: String, paper: NSColor, opacity: Double) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha = reduceTransparency || contrast ? 1 : opacity * (theme == "glass" ? 0.66 : 1)
        let compactRadius = edge == "top" ? 14.0 : 13.0
        let radius = compactRadius + (28 - compactRadius) * progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        eyeView.frame = bounds
        eyeView.isHidden = theme == "miffy" || progress >= 0.25
        miffyInk.frame = bounds
        miffyInk.isHidden = theme != "miffy"
        miffyInk.progress = progress
        miffyInk.needsDisplay = true
        miffyBorder.isHidden = theme != "miffy"
        if theme == "miffy" {
            let path = MiffySkin.path(size: size, progress: progress)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            for shape in [miffyMask, miffyBorder, miffyBorderMask] { shape.contentsScale = scale }
            silhouette = path
            miffyMask.frame = clip.bounds; miffyMask.path = path
            clip.layer?.mask = miffyMask
            miffyBorder.frame = bounds; miffyBorder.path = path
            miffyBorderMask.frame = bounds; miffyBorderMask.path = path
            miffyBorder.opacity = Float(min(1,progress/0.28))
        } else { silhouette = nil; clip.layer?.mask = nil }
        clip.layer?.cornerRadius = theme == "miffy" ? 0 : radius
        clip.layer?.borderWidth = contrast ? 1 : 0
        clip.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
        material.frame = clip.bounds
        material.isHidden = alpha >= 1 && theme != "glass" || reduceTransparency || contrast
        material.appearance = NSAppearance(named: theme == "ink" ? .darkAqua : .aqua)
        tint.frame = clip.bounds
        tint.layer?.backgroundColor = paper.withAlphaComponent(alpha).cgColor
        let eyeColor: NSColor = switch theme {
        case "ink": NSColor(calibratedWhite: 0.92, alpha: 1)
        case "pink": NSColor(red: 0.48, green: 0.34, blue: 0.40, alpha: 1)
        default: NSColor(red: 0.31, green: 0.37, blue: 0.33, alpha: 1)
        }
        halo.frame = bounds
        halo.cornerRadius = radius
        halo.shadowColor = (theme == "pink" ? NSColor(red: 0.89, green: 0.69, blue: 0.77, alpha: 1) : NSColor.white).cgColor
        halo.shadowRadius = 5
        halo.shadowOpacity = theme == "miffy" ? 0 : Float(0.10 * (1 - progress))
        halo.shadowOffset = .zero
        halo.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The halo never supplies an opaque backing to the opacity setting.
        halo.backgroundColor = NSColor.clear.cgColor
        eyes.bounds = NSRect(x: 0, y: 0, width: 25, height: 7)
        eyes.position = NSPoint(x: bounds.midX, y: bounds.midY)
        eyes.opacity = Float(max(0, 1 - progress / 0.25))
        indicator.frame = NSRect(x: edge == "top" ? size.width - 22 : (size.width - 14) / 2, y: edge == "top" ? (size.height - 14) / 2 : 9, width: 14, height: 14)
        indicator.isHidden = !hasIndicator || progress > 0.01
        if hasIndicator && edge == "top" { eyes.position.x -= 6 }
        leftEye.frame = NSRect(x: edge == "top" ? 0 : 4, y: 0, width: 3.5, height: 7)
        rightEye.frame = NSRect(x: edge == "top" ? 21.5 : 17.5, y: 0, width: 3.5, height: 7)
        leftEye.backgroundColor = eyeColor.cgColor; rightEye.backgroundColor = eyeColor.cgColor
        CATransaction.commit()
    }
}
