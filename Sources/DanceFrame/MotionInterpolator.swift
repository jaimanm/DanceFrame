import Foundation

public struct MotionInterpolator {
    /// Calculate normalized crop position `x` (0.0 ... 1.0) at timestamp `t`
    public static func position(at t: Double, points: [TrackingPoint], mode: MotionMode) -> Double {
        if points.isEmpty { return 0.5 }
        if t <= points[0].t { return points[0].x }

        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            if t < b.t {
                let dt = b.t - a.t
                if dt <= 0.000001 { return a.x }
                var u = max(0.0, min(1.0, (t - a.t) / dt))
                if mode == .smooth {
                    u = u * u * (3.0 - 2.0 * u)
                }
                return a.x + (b.x - a.x) * u
            }
        }

        return points.last?.x ?? 0.5
    }

    /// Formats seconds to mm:ss.sss
    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "00:00.000" }
        let total = max(0, seconds)
        let mins = Int(total) / 60
        let secs = total.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%06.3f", mins, secs)
    }

    /// Generates FFmpeg crop@follow command script lines
    public static func generateCommands(points: [TrackingPoint], availableWidth: Double, mode: MotionMode) -> String {
        guard let first = points.first else { return "" }
        let f: (Double) -> String = { String(format: "%.9f", $0) }
        var rows: [String] = []

        rows.append("0 crop@follow x '\(f(first.x * availableWidth))';")

        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            let u = "((t-\(f(a.t)))/\(f(b.t - a.t)))"
            let curve = mode == .linear ? u : "(\(u)*\(u)*(3-2*\(u)))"
            let expr = "\(f(a.x * availableWidth))+(\(f((b.x - a.x) * availableWidth)))*\(curve)"
            rows.append("\(f(a.t)) crop@follow x '\(expr)';")
        }

        if let last = points.last {
            rows.append("\(f(last.t)) crop@follow x '\(f(last.x * availableWidth))';")
        }

        return rows.joined(separator: "\n")
    }
}
