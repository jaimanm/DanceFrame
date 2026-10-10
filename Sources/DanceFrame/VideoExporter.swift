import Foundation
import AppKit

@MainActor
public final class VideoExporter: ObservableObject {
    @Published public var isExporting: Bool = false
    @Published public var progress: Double = 0
    @Published public var statusMessage: String = ""
    @Published public var errorMessage: String?
    @Published public var completedURL: URL?

    private var currentProcess: Process?
    private var isCancelled: Bool = false

    public init() {}

    private static func findFFmpegBinary() -> String? {
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/binaries/ffmpeg" },
            Bundle.main.bundlePath + "/Contents/Resources/binaries/ffmpeg",
            FileManager.default.currentDirectoryPath + "/build-resources/binaries/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try 'which ffmpeg'
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ffmpeg"]
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !str.isEmpty, FileManager.default.isExecutableFile(atPath: str) {
                return str
            }
        }

        return nil
    }

    public func export(
        meta: VideoMetadata,
        points: [TrackingPoint],
        trim: TrimRange,
        mode: MotionMode,
        resolution: String, // "1080" or "720"
        destinationURL: URL
    ) async {
        guard let ffmpegPath = Self.findFFmpegBinary() else {
            self.errorMessage = "FFmpeg binary not found. Please install FFmpeg (brew install ffmpeg)."
            return
        }

        guard !points.isEmpty else {
            self.errorMessage = "Please add at least one tracking point."
            return
        }

        let sortedPoints = points.sorted(by: { $0.t < $1.t })
        let trimStart = max(0, trim.start)
        let trimEnd = min(meta.duration, trim.end)
        let length = max(1.0 / meta.fps, trimEnd - trimStart)

        self.isExporting = true
        self.progress = 0
        self.statusMessage = "Preparing export..."
        self.errorMessage = nil
        self.completedURL = nil
        self.isCancelled = false

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("danceframe-export-\(UUID().uuidString)")
        let partialOutput = destinationURL.deletingLastPathComponent().appendingPathComponent(".danceframe-tmp-\(UUID().uuidString).mp4")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
                if self.isCancelled {
                    try? FileManager.default.removeItem(at: partialOutput)
                }
            }

            let motionText = MotionInterpolator.generateCommands(
                points: sortedPoints,
                availableWidth: Double(meta.width - meta.cropWidth),
                mode: mode
            )
            let motionFile = tempDir.appendingPathComponent("motion.txt")
            try motionText.write(to: motionFile, atomically: true, encoding: .utf8)

            let scale = (resolution == "1080") ? "1080:1920" : "720:1280"
            let vf = "setpts=PTS-STARTPTS,sendcmd=f=\(motionFile.path),crop@follow=\(meta.cropWidth):\(meta.cropHeight):0:0:exact=1,trim=start=\(trimStart):end=\(trimEnd),setpts=PTS-STARTPTS,scale=\(scale):flags=lanczos,setsar=1"
            let af = "atrim=start=\(trimStart):end=\(trimEnd),asetpts=PTS-STARTPTS"

            let args = [
                "-hide_banner",
                "-y",
                "-i", meta.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-vf", vf,
                "-c:v", "libx264",
                "-preset", "fast",
                "-crf", "18",
                "-pix_fmt", "yuv420p",
                "-af", af,
                "-t", String(format: "%.6f", length),
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart",
                "-progress", "pipe:1",
                "-nostats",
                partialOutput.path
            ]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = args
            process.currentDirectoryURL = tempDir

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            self.currentProcess = process

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                for line in output.components(separatedBy: .newlines) {
                    if line.hasPrefix("out_time_us=") {
                        let valStr = line.replacingOccurrences(of: "out_time_us=", with: "")
                        if let us = Double(valStr) {
                            let prog = min(0.99, max(0.0, (us / 1_000_000.0) / length))
                            Task { @MainActor [weak self] in
                                self?.progress = prog
                                self?.statusMessage = String(format: "Rendering... %d%%", Int(prog * 100))
                            }
                        }
                    }
                }
            }

            try process.run()

            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil

            if self.isCancelled {
                self.statusMessage = "Export cancelled."
                return
            }

            if process.terminationStatus == 0 {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: partialOutput, to: destinationURL)
                self.progress = 1.0
                self.statusMessage = "Export complete: \(destinationURL.lastPathComponent)"
                self.completedURL = destinationURL
            } else {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "FFmpeg process failed."
                self.errorMessage = String(errStr.suffix(1000))
                self.statusMessage = "Export failed."
            }

        } catch {
            self.errorMessage = error.localizedDescription
            self.statusMessage = "Export failed."
        }

        self.isExporting = false
        self.currentProcess = nil
    }

    public func cancel() {
        guard isExporting, let proc = currentProcess else { return }
        self.isCancelled = true
        proc.terminate()
        self.isExporting = false
        self.statusMessage = "Export cancelled."
    }
}
