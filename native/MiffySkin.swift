import AppKit

// Measured from the supplied image. The PNG itself stays unchanged.
struct MiffyContour: Decodable {
    let bounds: [Double]
    let ear: [[Double]]
    let body: [[Double]]
    let face: [Double]
    let earRootY: Double
    let strokeWidth: Double
}

enum MiffySkin {
    static var available: Bool { reference != nil && Bundle.main.url(forResource: "miffy-reference", withExtension: "png") != nil }
    static let compact = NSSize(width: 78, height: 112)
    static let earHeight = 66.0
    static var strokeWidth: Double { reference?.strokeWidth ?? 4.4 }
    static let reference: MiffyContour? = {
        guard let url = Bundle.main.url(forResource: "miffy-shape", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MiffyContour.self, from: data)
    }()

    static func path(size: NSSize, progress: Double, contour: MiffyContour? = reference) -> CGPath {
        guard let ref = contour else { return CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 28, cornerHeight: 28, transform: nil) }
        let p = min(1, max(0, progress))
        let fw = p > 0.0001 ? (size.width - compact.width * (1-p))/p : 480
        let fh = p > 0.0001 ? (size.height - compact.height * (1-p))/p : 306
        let scale = earHeight / (ref.earRootY - ref.bounds[1])
        let center = (ref.ear[0][0] + ref.ear.last![0])/2
        let targetEar = ref.ear.map { CGPoint(x: fw/2 + ($0[0]-center)*scale, y: ($0[1]-ref.bounds[1])*scale) }
        let w = max(160, fw), h = max(130, fh), r = min(42, w/5, (h-earHeight)/3)
        var points = [CGPoint(x: w/2 + (ref.ear.last![0]-center)*scale, y: earHeight)]
        func line(_ x: Double, _ y: Double) { points.append(CGPoint(x: x, y: y)) }
        func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
            let a = points.last!
            for i in 1...16 {
                let t = Double(i)/16, s = 1-t
                points.append(CGPoint(x: s*s*s*a.x + 3*s*s*t*x1 + 3*s*t*t*x2 + t*t*t*x3,
                                      y: s*s*s*a.y + 3*s*s*t*y1 + 3*s*t*t*y2 + t*t*t*y3))
            }
        }
        line(w-r,earHeight); curve(w-r/3,earHeight,w,earHeight+r/3,w,earHeight+r)
        line(w,h-r); curve(w,h-r/3,w-r/3,h,w-r,h)
        line(r,h); curve(r/3,h,0,h-r/3,0,h-r)
        line(0,earHeight+r); curve(0,earHeight+r/3,r/3,earHeight,r,earHeight)
        line(w/2+(ref.ear[0][0]-center)*scale,earHeight)
        var distances = [0.0]
        for i in 1..<points.count { distances.append(distances.last! + hypot(points[i].x-points[i-1].x, points[i].y-points[i-1].y)) }
        var j = 1
        let sampled = (0..<ref.body.count).map { i -> CGPoint in
            let distance = distances.last! * Double(i)/Double(ref.body.count-1)
            while j < distances.count-1 && distances[j] < distance { j += 1 }
            let t = (distance-distances[j-1])/max(0.0001,distances[j]-distances[j-1])
            return CGPoint(x: points[j-1].x+(points[j].x-points[j-1].x)*t, y: points[j-1].y+(points[j].y-points[j-1].y)*t)
        }
        var outline: [CGPoint] = []
        for pair in zip(ref.ear+ref.body, targetEar+sampled) {
            let (source, target) = pair
            let point = CGPoint(x: (source[0]-ref.bounds[0])/ref.bounds[2]*compact.width*(1-p)+target.x*p,
                                y: size.height-((source[1]-ref.bounds[1])/ref.bounds[3]*compact.height*(1-p)+target.y*p))
            outline.append(point)
        }
        let result = CGMutablePath()
        func midpoint(_ a: CGPoint,_ b: CGPoint) -> CGPoint { CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2) }
        result.move(to:midpoint(outline.last!,outline[0]))
        for i in outline.indices { result.addQuadCurve(to:midpoint(outline[i],outline[(i+1)%outline.count]),control:outline[i]) }
        result.closeSubpath()
        return result
    }
}

final class MiffyInkView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var progress = 0.0
    private let outline: NSImage?
    private let face: NSImage?

    override init(frame frameRect: NSRect) {
        // Extract only the original ink in memory, so paper opacity stays independent.
        let url = Bundle.main.url(forResource: "miffy-reference", withExtension: "png")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        var rect = NSRect.zero
        let cg = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        func ink(features: Bool) -> NSImage? {
            guard let cg else { return nil }
            let w = cg.width, h = cg.height
            var bytes = [UInt8](repeating: 0, count: w*h*4)
            return bytes.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            for y in 0..<h { for x in 0..<w {
                let i = (y*w+x)*4
                let isFeature = (145..<177).contains(x) && (426..<464).contains(y) || (322..<352).contains(x) && (426..<462).contains(y) || (222..<284).contains(x) && (491..<535).contains(y)
                let alpha = isFeature == features ? 255-(Int(pixels[i])+Int(pixels[i+1])+Int(pixels[i+2]))/3 : 0
                pixels[i] = 0; pixels[i+1] = 0; pixels[i+2] = 0; pixels[i+3] = UInt8(alpha)
            } }
            let crop = features ? CGRect(x:145,y:426,width:211,height:113) : CGRect(x:65,y:38,width:367,height:530)
            guard let result = context.makeImage()?.cropping(to: crop) else { return nil }
            return NSImage(cgImage: result, size: crop.size)
            }
        }
        outline = ink(features: false); face = ink(features: true)
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = min(1,max(0,progress))
        outline?.draw(in: NSRect(x:(bounds.width-78)/2,y:0,width:78,height:112), from:.zero, operation:.sourceOver, fraction:max(0,1-p/0.28), respectFlipped:true, hints:nil)
        let w = 211.0/367*78*(1-p)+56*p
        let h = 113.0/530*112*(1-p)+(113.0/211*56)*p
        // Keep the original expression at the same height throughout the morph.
        face?.draw(in:NSRect(x:bounds.midX-w/2,y:388.0/530*112,width:w,height:h),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}
