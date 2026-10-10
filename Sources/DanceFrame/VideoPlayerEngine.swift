import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit

@MainActor
public final class VideoPlayerEngine: ObservableObject {
    public let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var timeObserverToken: Any?

    @Published public var metadata: VideoMetadata?
    @Published public var currentTime: Double = 0
    @Published public var isPlaying: Bool = false
    @Published public var isScrubbing: Bool = false
    @Published public var scrubTime: Double = 0
    @Published public var currentCroppedImage: NSImage?
    @Published public var playbackRate: Float = 1.0

    private var pendingSeekTime: Double?
    private var isSeekingInternal: Bool = false

    public init() {
        player.actionAtItemEnd = .pause
    }

    public func loadVideo(from url: URL) async throws {
        pause()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw NSError(domain: "DanceFrame", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found in this file."])
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        guard width >= height else {
            throw NSError(domain: "DanceFrame", code: 2, userInfo: [NSLocalizedDescriptionKey: "Please choose a landscape video."])
        }

        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let fps = (nominalFrameRate > 0 && nominalFrameRate.isFinite) ? nominalFrameRate : 30.0

        let meta = VideoMetadata(
            name: url.lastPathComponent,
            path: url.path,
            width: width,
            height: height,
            duration: durationSeconds,
            fps: fps
        )

        let item = AVPlayerItem(asset: asset)
        let settings: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        item.add(output)
        self.videoOutput = output

        self.metadata = meta
        self.currentTime = 0
        self.scrubTime = 0
        self.isScrubbing = false

        player.replaceCurrentItem(with: item)

        // Set up 60fps periodic observer on main queue
        let interval = CMTime(value: 1, timescale: 60)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, !self.isScrubbing else { return }
                self.currentTime = CMTimeGetSeconds(time)
                self.isPlaying = (self.player.rate != 0)
            }
        }
    }

    public func play() {
        guard metadata != nil else { return }
        player.rate = playbackRate
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func setRate(_ rate: Float) {
        self.playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    public func step(frames: Int) {
        guard let meta = metadata else { return }
        pause()
        let dt = Double(frames) / meta.fps
        seek(to: max(0, min(meta.duration, currentTime + dt)))
    }

    public func seek(to targetSeconds: Double) {
        guard let meta = metadata else { return }
        let clamped = max(0, min(meta.duration, targetSeconds))

        if isSeekingInternal {
            pendingSeekTime = clamped
            return
        }

        isSeekingInternal = true
        pendingSeekTime = nil

        let cmTime = CMTime(seconds: clamped, preferredTimescale: 60000)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isSeekingInternal = false
                if let next = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.seek(to: next)
                } else if !self.isScrubbing {
                    self.currentTime = clamped
                }
            }
        }
    }

    /// Extract and crop the current frame at normalized position `cropX`
    public func updateCroppedPreview(cropNormX: Double) {
        guard let meta = metadata, let output = videoOutput else { return }
        let effectiveTime = isScrubbing ? scrubTime : currentTime
        let itemTime = CMTime(seconds: effectiveTime, preferredTimescale: 60000)

        guard output.hasNewPixelBuffer(forItemTime: itemTime) || true,
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let bufWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: bufWidth,
            height: bufHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else {
            return
        }

        // Calculate crop rectangle (9:16)
        let availableW = Double(bufWidth - meta.cropWidth)
        let pixelX = max(0, min(availableW, cropNormX * availableW))
        let cropRect = CGRect(x: pixelX, y: 0, width: Double(meta.cropWidth), height: Double(meta.cropHeight))

        guard let cropped = cgImage.cropping(to: cropRect) else { return }
        self.currentCroppedImage = NSImage(cgImage: cropped, size: NSSize(width: meta.cropWidth, height: meta.cropHeight))
    }
}
