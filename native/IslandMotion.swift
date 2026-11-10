import Foundation

// The exact critically damped solution keeps position and velocity continuous when
// a target changes. It is independent of the display's refresh rate.
struct IslandSpring {
    var value: Double
    var velocity = 0.0
    var target: Double

    init(_ value: Double) { self.value = value; target = value }

    mutating func step(seconds: Double, frequency: Double) {
        let dt = min(max(seconds, 0), 0.05)
        let error = value - target
        let coefficient = velocity + frequency * error
        let decay = exp(-frequency * dt)
        value = target + (error + coefficient * dt) * decay
        velocity = (velocity - frequency * coefficient * dt) * decay
    }

    mutating func finish() { value = target; velocity = 0 }
    var settled: Bool { abs(value - target) < 0.6 && abs(velocity) < 25 }
}

func islandContentOpacity(_ progress: Double) -> Double {
    let t = min(1, max(0, (progress - 0.90) / 0.10))
    return t * t * (3 - 2 * t)
}
