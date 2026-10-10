import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppViewModel: ObservableObject {
    public let engine = VideoPlayerEngine()
    public let exporter = VideoExporter()

    @Published public var points: [TrackingPoint] = []
    @Published public var undoHistory: [[TrackingPoint]] = []
    @Published public var trim = TrimRange()
    @Published public var mode: MotionMode = .smooth
    @Published public var selectedPointId: UUID?
    @Published public var exportSize: String = "1080"
    @Published public var noticeText: String = "Open a landscape video to get started. Everything stays local on this Mac."
    @Published public var isNoticeError: Bool = false

    private var loopTimer: Timer?

    public init() {
        // Observe playback to loop/pause at trim.end and update live portrait preview
        loopTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.tick()
            }
        }
    }

    private func tick() {
        guard engine.metadata != nil else { return }

        // Loop / pause at trim.end
        if engine.isPlaying && engine.currentTime >= trim.end {
            engine.pause()
            engine.seek(to: trim.end)
        }

        // Live crop position
        let effectiveTime = engine.isScrubbing ? engine.scrubTime : engine.currentTime
        let normX = MotionInterpolator.position(at: effectiveTime, points: points, mode: mode)
        engine.updateCroppedPreview(cropNormX: normX)
    }

    public func setNotice(_ text: String, isError: Bool = false) {
        self.noticeText = text
        self.isNoticeError = isError
    }

    public func openVideoDialog() {
        guard !exporter.isExporting else {
            setNotice("Finish or cancel the current export before opening another video.", isError: true)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Open a landscape video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.movie,
            UTType.quickTimeMovie,
            UTType.mpeg4Movie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie
        ]

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await engine.loadVideo(from: url)
                    if let meta = engine.metadata {
                        self.trim = TrimRange(start: 0, end: meta.duration)
                        self.points = []
                        self.undoHistory = []
                        self.selectedPointId = nil
                        self.setNotice("Video loaded: \(meta.name). Scrub to a moment, then click on yourself to place a tracking point.")
                    }
                } catch {
                    self.setNotice(error.localizedDescription, isError: true)
                }
            }
        }
    }

    public func recordUndo() {
        undoHistory.append(points)
        if undoHistory.count > 100 {
            undoHistory.removeFirst()
        }
    }

    public func undo() {
        guard !undoHistory.isEmpty else { return }
        self.points = undoHistory.removeLast()
        self.selectedPointId = nil
    }

    public func addOrUpdatePoint(x: Double, at time: Double? = nil) {
        guard let meta = engine.metadata else { return }
        recordUndo()

        let t = max(0, min(meta.duration, time ?? (engine.isScrubbing ? engine.scrubTime : engine.currentTime)))
        let clampedX = max(0, min(1, x))

        // Check if there is an existing point within 0.5 frames
        let tolerance = 0.5 / meta.fps
        if let idx = points.firstIndex(where: { abs($0.t - t) < tolerance }) {
            points[idx].x = clampedX
            selectedPointId = points[idx].id
        } else {
            let newPoint = TrackingPoint(t: t, x: clampedX)
            points.append(newPoint)
            points.sort(by: { $0.t < $1.t })
            selectedPointId = newPoint.id
        }
    }

    public func deletePoint(id: UUID) {
        recordUndo()
        points.removeAll(where: { $0.id == id })
        if selectedPointId == id {
            selectedPointId = nil
        }
    }

    public func seekToPoint(_ point: TrackingPoint) {
        engine.pause()
        engine.seek(to: point.t)
        selectedPointId = point.id
    }

    public func setTrimStartHere() {
        guard let meta = engine.metadata else { return }
        let t = engine.isScrubbing ? engine.scrubTime : engine.currentTime
        if t < trim.end - (1.0 / meta.fps) {
            trim.start = max(0, t)
            setNotice("Trim start set to \(MotionInterpolator.formatTime(trim.start))")
        }
    }

    public func setTrimEndHere() {
        guard let meta = engine.metadata else { return }
        let t = engine.isScrubbing ? engine.scrubTime : engine.currentTime
        if t > trim.start + (1.0 / meta.fps) {
            trim.end = min(meta.duration, t)
            setNotice("Trim end set to \(MotionInterpolator.formatTime(trim.end))")
        }
    }

    public func resetTrim() {
        guard let meta = engine.metadata else { return }
        trim = TrimRange(start: 0, end: meta.duration)
        setNotice("Trim reset to full duration.")
    }

    public func saveProjectDialog() {
        guard let meta = engine.metadata else { return }

        let panel = NSSavePanel()
        panel.title = "Save Tracking Project"
        panel.nameFieldStringValue = (meta.name as NSString).deletingPathExtension + ".danceframe.json"
        panel.allowedContentTypes = [UTType.json]

        if panel.runModal() == .OK, let url = panel.url {
            let proj = DanceFrameProject(
                video: VideoProjectInfo(name: meta.name, width: meta.width, height: meta.height, duration: meta.duration),
                mode: mode,
                points: points,
                trim: trim
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(proj)
                try data.write(to: url, options: .atomic)
                setNotice("Tracking project saved successfully.")
            } catch {
                setNotice("Failed to save project: \(error.localizedDescription)", isError: true)
            }
        }
    }

    public func loadProjectDialog() {
        guard let meta = engine.metadata else {
            setNotice("Open the original video first before loading a project.", isError: true)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Load Tracking Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.json]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let proj = try JSONDecoder().decode(DanceFrameProject.self, from: data)

                // Validate matching video
                if abs(proj.video.duration - meta.duration) > 0.1 ||
                    proj.video.width != meta.width ||
                    proj.video.height != meta.height {
                    setNotice("This project belongs to a different video dimensions/duration. Open the matching original first.", isError: true)
                    return
                }

                recordUndo()
                self.points = proj.points.sorted(by: { $0.t < $1.t })
                self.mode = proj.mode
                self.trim = TrimRange(
                    start: max(0, min(meta.duration, proj.trim.start)),
                    end: max(proj.trim.start + 1.0 / meta.fps, min(meta.duration, proj.trim.end))
                )
                self.selectedPointId = nil
                setNotice("Tracking project loaded successfully.")
            } catch {
                setNotice("Failed to load project: \(error.localizedDescription)", isError: true)
            }
        }
    }

    public func exportDialog() {
        guard let meta = engine.metadata else { return }
        guard !points.isEmpty else {
            setNotice("Add at least one tracking point before exporting.", isError: true)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Vertical Video"
        let defaultName = (meta.name as NSString).deletingPathExtension + "-vertical.mp4"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType.mpeg4Movie]

        if panel.runModal() == .OK, let destURL = panel.url {
            if destURL.path == meta.path {
                setNotice("Choose a different filename so your original video is preserved.", isError: true)
                return
            }

            engine.pause()
            Task {
                await exporter.export(
                    meta: meta,
                    points: points,
                    trim: trim,
                    mode: mode,
                    resolution: exportSize,
                    destinationURL: destURL
                )
            }
        }
    }
}
