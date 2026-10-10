import Foundation

public enum MotionMode: String, Codable, CaseIterable, Sendable {
    case smooth = "smooth"
    case linear = "linear"

    public var displayName: String {
        switch self {
        case .smooth: return "Smooth ease in / out"
        case .linear: return "Constant speed"
        }
    }
}

public struct TrackingPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var t: Double  // Timestamp in seconds
    public var x: Double  // Normalized position 0.0 ... 1.0

    public init(id: UUID = UUID(), t: Double, x: Double) {
        self.id = id
        self.t = max(0, t)
        self.x = max(0, min(1, x))
    }

    enum CodingKeys: String, CodingKey {
        case t, x
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.t = try container.decode(Double.self, forKey: .t)
        self.x = try container.decode(Double.self, forKey: .x)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(x, forKey: .x)
    }
}

public struct TrimRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double = 0, end: Double = 0) {
        self.start = max(0, start)
        self.end = max(start, end)
    }
}

public struct VideoMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var width: Int
    public var height: Int
    public var duration: Double
    public var fps: Double

    public var cropWidth: Int {
        // 9:16 aspect ratio rounded to even pixels
        Int(Double(height) * 9.0 / 16.0 / 2.0) * 2
    }

    public var cropHeight: Int {
        Int(height / 2) * 2
    }

    public init(name: String, path: String, width: Int, height: Int, duration: Double, fps: Double) {
        self.name = name
        self.path = path
        self.width = width
        self.height = height
        self.duration = duration
        self.fps = fps
    }
}

public struct VideoProjectInfo: Codable, Equatable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var duration: Double
}

public struct DanceFrameProject: Codable, Sendable {
    public var version: Int
    public var video: VideoProjectInfo
    public var mode: MotionMode
    public var points: [TrackingPoint]
    public var trim: TrimRange

    public init(video: VideoProjectInfo, mode: MotionMode, points: [TrackingPoint], trim: TrimRange) {
        self.version = 1
        self.video = video
        self.mode = mode
        self.points = points.sorted(by: { $0.t < $1.t })
        self.trim = trim
    }
}
