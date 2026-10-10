import Foundation
import Vision
import AVFoundation
import CoreMedia
import CoreVideo

public enum TrackingSensitivity: String, Codable, CaseIterable, Sendable {
    case fine = "Fine"
    case medium = "Medium"
    case coarse = "Coarse"

    public var displayName: String {
        switch self {
        case .fine: return "Fine"
        case .medium: return "Medium"
        case .coarse: return "Coarse"
        }
    }

    public func frameStride(for fps: Double) -> Int {
        let baseFps = max(15.0, fps)
        switch self {
        case .fine:
            // ~10-12 samples/sec
            return max(1, Int(round(baseFps / 12.0)))
        case .medium:
            // ~5-6 samples/sec
            return max(1, Int(round(baseFps / 6.0)))
        case .coarse:
            // ~2.5-3 samples/sec
            return max(1, Int(round(baseFps / 3.0)))
        }
    }

    public var changeThreshold: Double {
        switch self {
        case .fine: return 0.015
        case .medium: return 0.035
        case .coarse: return 0.065
        }
    }
}

public enum PersonTrackerError: LocalizedError, Sendable {
    case noVideoTrack
    case readerFailedToStart
    case noPersonFound(startTime: Double)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in the file."
        case .readerFailedToStart:
            return "Could not decode video frames for analysis."
        case .noPersonFound(let t):
            return "No person detected near \(MotionInterpolator.formatTime(t)). Try scrubbing to a frame where the person is clearly visible."
        case .cancelled:
            return "Auto-tracking cancelled."
        }
    }
}

public actor PersonTracker {
    private var isCancelled: Bool = false

    public init() {}

    public func cancel() {
        self.isCancelled = true
    }

    /// Analyzes the video starting from `startTime` up to `endTime`, tracking the selected person.
    /// Incorporates clothing/color appearance modeling to prevent latching onto other people,
    /// and pauses keyframe generation when the subject is out of frame until they re-enter.
    public func track(
        videoURL: URL,
        metadata: VideoMetadata,
        startTime: Double,
        endTime: Double,
        targetXHint: Double?, // Normalized crop position hint at startTime (0...1)
        sensitivity: TrackingSensitivity,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> [TrackingPoint] {
        self.isCancelled = false

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw PersonTrackerError.noVideoTrack
        }

        let effectiveStart = max(0, min(metadata.duration, startTime))
        let effectiveEnd = max(effectiveStart + 0.1, min(metadata.duration, endTime))
        let totalDuration = effectiveEnd - effectiveStart

        let reader = try AVAssetReader(asset: asset)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: effectiveStart, preferredTimescale: 600),
            end: CMTime(seconds: effectiveEnd, preferredTimescale: 600)
        )
        reader.timeRange = timeRange

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw PersonTrackerError.readerFailedToStart
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw PersonTrackerError.readerFailedToStart
        }

        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        let stride = sensitivity.frameStride(for: metadata.fps)
        let availableW = Double(max(1, metadata.width - metadata.cropWidth))

        // Convert targetXHint (crop position 0...1) to normalized source person center (0...1)
        let initialPersonCenterHint: Double = {
            if let hint = targetXHint {
                let cropLeftPixel = hint * availableW
                let cropCenterPixel = cropLeftPixel + Double(metadata.cropWidth) / 2.0
                return max(0.0, min(1.0, cropCenterPixel / Double(metadata.width)))
            } else {
                return 0.5
            }
        }()

        var frameCounter = 0
        var trackedState: TrackedSubjectState? = nil
        var rawSamples: [(t: Double, normX: Double)] = []

        // Sequence request handler for temporal tracking assistance during small gaps
        let sequenceHandler = VNSequenceRequestHandler()
        var lastObservation: VNDetectedObjectObservation? = nil

        while reader.status == .reading {
            if Task.isCancelled || self.isCancelled {
                reader.cancelReading()
                throw PersonTrackerError.cancelled
            }

            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }

            frameCounter += 1
            if frameCounter % stride != 0 && trackedState != nil {
                continue
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let currentTime = CMTimeGetSeconds(pts)
            if currentTime > effectiveEnd {
                break
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // Report progress
            let progress = max(0.0, min(1.0, (currentTime - effectiveStart) / max(0.001, totalDuration)))
            progressHandler(progress)

            // Detect humans in current frame
            let humanObservations = detectHumans(in: pixelBuffer)

            if trackedState == nil {
                // Initialize tracking: search for the target person
                if let bestCandidate = selectInitialSubject(
                    observations: humanObservations,
                    targetCenterHintX: initialPersonCenterHint
                ) {
                    let center = CGPoint(x: bestCandidate.midX, y: bestCandidate.midY)
                    let initialSignature = ColorSignature.extract(from: pixelBuffer, box: bestCandidate)
                        ?? ColorSignature.empty()

                    trackedState = TrackedSubjectState(
                        center: center,
                        box: bestCandidate,
                        velocityX: 0.0,
                        consecutiveLostFrames: 0,
                        isOutOfFrame: false,
                        lastTime: currentTime,
                        initialSignature: initialSignature,
                        currentSignature: initialSignature
                    )
                    lastObservation = VNDetectedObjectObservation(boundingBox: bestCandidate)

                    // Record initial keyframe sample
                    let normX = calculateCropNormX(
                        personCenterNormX: Double(center.x),
                        meta: metadata,
                        availableW: availableW
                    )
                    rawSamples.append((t: currentTime, normX: normX))
                } else {
                    // Fail early if no person detected within first 45 processed frames (~1.5s)
                    if frameCounter > max(45, stride * 15) {
                        reader.cancelReading()
                        throw PersonTrackerError.noPersonFound(startTime: effectiveStart)
                    }
                    continue
                }
            } else {
                // Ongoing tracking
                guard var state = trackedState else { continue }
                let dt = max(0.001, currentTime - state.lastTime)

                if state.isOutOfFrame {
                    // SUBJECT IS CURRENTLY OUT OF FRAME:
                    // Do NOT add keyframes! Scan for candidate that matches subject's color signature
                    var reacquiredMatch: (box: CGRect, signature: ColorSignature)? = nil
                    var bestReacquireSim = 0.0

                    for obs in humanObservations {
                        if let sig = ColorSignature.extract(from: pixelBuffer, box: obs) {
                            let sim = sig.similarity(to: state.currentSignature) * 0.5
                                    + sig.similarity(to: state.initialSignature) * 0.5
                            // Require solid color similarity to confirm it's our dancer
                            if sim >= 0.50 && sim > bestReacquireSim {
                                bestReacquireSim = sim
                                reacquiredMatch = (obs, sig)
                            }
                        }
                    }

                    if let match = reacquiredMatch {
                        // Dancer has re-entered the frame!
                        let newCenterX = match.box.midX
                        state.center = CGPoint(x: newCenterX, y: match.box.midY)
                        state.box = match.box
                        state.velocityX = 0.0
                        state.consecutiveLostFrames = 0
                        state.isOutOfFrame = false
                        state.lastTime = currentTime
                        state.currentSignature = state.currentSignature.blended(with: match.signature, weight: 0.20)
                        lastObservation = VNDetectedObjectObservation(boundingBox: match.box)

                        // Resume adding keyframe samples now that dancer is back
                        let normX = calculateCropNormX(
                            personCenterNormX: Double(newCenterX),
                            meta: metadata,
                            availableW: availableW
                        )
                        rawSamples.append((t: currentTime, normX: normX))
                    } else {
                        // Still out of frame: update timestamp, but DO NOT add any sample
                        state.lastTime = currentTime
                    }
                } else {
                    // SUBJECT IS IN FRAME:
                    // Predict expected position based on velocity
                    let predictedX = state.center.x + CGFloat(state.velocityX * dt)

                    // Find best matching human observation with color verification
                    let matchedResult = matchCandidateWithColor(
                        observations: humanObservations,
                        predictedX: predictedX,
                        state: state,
                        dt: dt,
                        pixelBuffer: pixelBuffer
                    )

                    if let (matchedBox, matchedSignature) = matchedResult {
                        // Update state with matched detection
                        let newCenterX = matchedBox.midX
                        let measuredVelocity = Double(newCenterX - state.center.x) / dt

                        // Exponential smoothing for velocity
                        let smoothVelocity = (state.velocityX * 0.6) + (measuredVelocity * 0.4)

                        state.center = CGPoint(x: newCenterX, y: matchedBox.midY)
                        state.box = matchedBox
                        state.velocityX = smoothVelocity
                        state.consecutiveLostFrames = 0
                        state.isOutOfFrame = false
                        state.lastTime = currentTime
                        state.currentSignature = state.currentSignature.blended(with: matchedSignature, weight: 0.15)

                        lastObservation = VNDetectedObjectObservation(boundingBox: matchedBox)

                        let normX = calculateCropNormX(
                            personCenterNormX: Double(newCenterX),
                            meta: metadata,
                            availableW: availableW
                        )
                        rawSamples.append((t: currentTime, normX: normX))
                    } else {
                        // Detection did not match or person is occluded / exiting frame
                        var trackedViaVision = false

                        // Try VNTrackObjectRequest as short-term bridge only if person was NOT near edge
                        let nearEdge = (state.center.x <= 0.09 || state.center.x >= 0.91)
                        if let prevObs = lastObservation, state.consecutiveLostFrames < 3, !nearEdge {
                            let trackReq = VNTrackObjectRequest(detectedObjectObservation: prevObs)
                            trackReq.trackingLevel = .fast
                            try? sequenceHandler.perform([trackReq], on: pixelBuffer)
                            if let res = trackReq.results?.first as? VNDetectedObjectObservation,
                               res.confidence > 0.30 {
                                let trackBox = res.boundingBox
                                if abs(trackBox.midX - predictedX) < 0.12 {
                                    // Check color of tracked box to make sure it didn't drift to someone else
                                    if let boxSig = ColorSignature.extract(from: pixelBuffer, box: trackBox) {
                                        let sim = boxSig.similarity(to: state.currentSignature) * 0.5
                                                + boxSig.similarity(to: state.initialSignature) * 0.5
                                        if sim >= 0.40 {
                                            state.center = CGPoint(x: trackBox.midX, y: trackBox.midY)
                                            state.box = trackBox
                                            state.lastTime = currentTime
                                            lastObservation = res
                                            trackedViaVision = true

                                            let normX = calculateCropNormX(
                                                personCenterNormX: Double(trackBox.midX),
                                                meta: metadata,
                                                availableW: availableW
                                            )
                                            rawSamples.append((t: currentTime, normX: normX))
                                        }
                                    }
                                }
                            }
                        }

                        if !trackedViaVision {
                            state.consecutiveLostFrames += 1

                            // Check if person exited the frame boundary
                            if nearEdge || state.consecutiveLostFrames >= 4 {
                                // Subject went out of frame! Pause tracking keyframes until they return
                                state.isOutOfFrame = true
                                state.velocityX = 0.0
                                state.lastTime = currentTime
                                // Do not append sample while out of frame!
                            } else {
                                // Brief mid-frame occlusion: coast velocity gently for up to ~0.5s
                                state.velocityX *= 0.75
                                state.center.x = max(0.02, min(0.98, state.center.x + CGFloat(state.velocityX * dt)))
                                state.lastTime = currentTime

                                let normX = calculateCropNormX(
                                    personCenterNormX: Double(state.center.x),
                                    meta: metadata,
                                    availableW: availableW
                                )
                                rawSamples.append((t: currentTime, normX: normX))
                            }
                        }
                    }
                }

                trackedState = state
            }
        }

        progressHandler(1.0)

        guard !rawSamples.isEmpty else {
            throw PersonTrackerError.noPersonFound(startTime: effectiveStart)
        }

        // Decimate and smooth into clean keyframes
        return decimateAndSmoothSamples(
            rawSamples: rawSamples,
            sensitivity: sensitivity,
            startTime: effectiveStart,
            endTime: effectiveEnd
        )
    }

    // MARK: - Human Detection

    private func detectHumans(in pixelBuffer: CVPixelBuffer) -> [CGRect] {
        var boxes: [CGRect] = []

        // Primary: Human rectangles detection
        let rectRequest = VNDetectHumanRectanglesRequest()
        rectRequest.upperBodyOnly = false

        // Secondary: Human body pose detection for joints/torso
        let poseRequest = VNDetectHumanBodyPoseRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([rectRequest, poseRequest])

        if let rectResults = rectRequest.results {
            for obs in rectResults where obs.confidence > 0.20 {
                boxes.append(obs.boundingBox)
            }
        }

        // If rectangle detector missed someone or for partial occlusion, use body pose joints
        if let poseResults = poseRequest.results {
            for pose in poseResults {
                if let points = try? pose.recognizedPoints(forGroupKey: .all) {
                    let validPoints = points.values.filter { $0.confidence > 0.25 }
                    if validPoints.count >= 3 {
                        var minX: CGFloat = 1.0, maxX: CGFloat = 0.0
                        var minY: CGFloat = 1.0, maxY: CGFloat = 0.0
                        for pt in validPoints {
                            minX = min(minX, pt.location.x)
                            maxX = max(maxX, pt.location.x)
                            minY = min(minY, pt.location.y)
                            maxY = max(maxY, pt.location.y)
                        }
                        let poseBox = CGRect(
                            x: max(0, minX - 0.05),
                            y: max(0, minY - 0.05),
                            width: min(1, (maxX - minX) + 0.10),
                            height: min(1, (maxY - minY) + 0.10)
                        )
                        let isCovered = boxes.contains { existing in
                            existing.intersection(poseBox).area / max(0.001, poseBox.area) > 0.5
                        }
                        if !isCovered {
                            boxes.append(poseBox)
                        }
                    }
                }
            }
        }

        return boxes
    }

    // MARK: - Matching & Association with Color Verification

    private func selectInitialSubject(
        observations: [CGRect],
        targetCenterHintX: Double
    ) -> CGRect? {
        guard !observations.isEmpty else { return nil }

        // Pick observation whose midX is closest to targetCenterHintX
        return observations.min { a, b in
            let distA = abs(Double(a.midX) - targetCenterHintX)
            let distB = abs(Double(b.midX) - targetCenterHintX)
            if abs(distA - distB) < 0.08 {
                return a.area > b.area
            }
            return distA < distB
        }
    }

    private func matchCandidateWithColor(
        observations: [CGRect],
        predictedX: CGFloat,
        state: TrackedSubjectState,
        dt: Double,
        pixelBuffer: CVPixelBuffer
    ) -> (box: CGRect, signature: ColorSignature)? {
        guard !observations.isEmpty else { return nil }

        let maxAllowedJump: CGFloat = max(0.12, CGFloat(0.40 * dt))

        var bestMatch: (box: CGRect, signature: ColorSignature)? = nil
        var bestScore: Double = Double.greatestFiniteMagnitude

        for obs in observations {
            let distX = Double(abs(obs.midX - predictedX))
            let distY = Double(abs(obs.midY - state.center.y))
            let sizeDiff = Double(abs(obs.width - state.box.width) / max(0.01, state.box.width))

            // Gate 1: discard detections that jumped unrealistically far
            if CGFloat(distX) > maxAllowedJump {
                continue
            }

            // Gate 2: verify clothing color appearance
            guard let candSig = ColorSignature.extract(from: pixelBuffer, box: obs) else {
                continue
            }

            let sim = candSig.similarity(to: state.currentSignature) * 0.5
                    + candSig.similarity(to: state.initialSignature) * 0.5

            // Reject anyone whose clothing color signature is incompatible (< 0.38)
            if sim < 0.38 {
                continue
            }

            // Weighted cost: lower is better (penalizes distance and rewards color similarity)
            let cost = (distX * 2.0) + (distY * 0.6) + (sizeDiff * 0.3) - (sim * 0.8)
            if cost < bestScore {
                bestScore = cost
                bestMatch = (obs, candSig)
            }
        }

        return bestMatch
    }

    // MARK: - Coordinate Conversion

    private func calculateCropNormX(
        personCenterNormX: Double,
        meta: VideoMetadata,
        availableW: Double
    ) -> Double {
        let personPixelX = personCenterNormX * Double(meta.width)
        let cropLeftPixel = personPixelX - Double(meta.cropWidth) / 2.0
        return max(0.0, min(1.0, cropLeftPixel / availableW))
    }

    // MARK: - Post-processing & Decimation

    private func decimateAndSmoothSamples(
        rawSamples: [(t: Double, normX: Double)],
        sensitivity: TrackingSensitivity,
        startTime: Double,
        endTime: Double
    ) -> [TrackingPoint] {
        guard !rawSamples.isEmpty else { return [] }

        // Step 1: 3-point moving average to filter sensor noise
        // Note: Do not smooth across large time gaps where subject was out of frame
        var smoothed: [(t: Double, normX: Double)] = []
        for i in 0..<rawSamples.count {
            let curr = rawSamples[i]
            let prev = rawSamples[max(0, i - 1)]
            let next = rawSamples[min(rawSamples.count - 1, i + 1)]

            // If neighbor is more than 0.8s away (out-of-frame gap), don't blend with it
            let usePrev = (curr.t - prev.t) < 0.8
            let useNext = (next.t - curr.t) < 0.8

            var sum = curr.normX * 0.5
            var weight = 0.5
            if usePrev {
                sum += prev.normX * 0.25
                weight += 0.25
            }
            if useNext {
                sum += next.normX * 0.25
                weight += 0.25
            }

            smoothed.append((t: curr.t, normX: sum / weight))
        }

        // Step 2: Adaptive decimation
        var kept: [TrackingPoint] = []
        guard let first = smoothed.first else { return [] }

        kept.append(TrackingPoint(t: first.t, x: first.normX))
        var lastKept = first
        let threshold = sensitivity.changeThreshold

        for i in 1..<(smoothed.count - 1) {
            let prev = smoothed[i - 1]
            let curr = smoothed[i]
            let next = smoothed[i + 1]

            let dxFromLast = abs(curr.normX - lastKept.normX)
            let dtFromLast = curr.t - lastKept.t

            // Detect out-of-frame re-entry (large gap in timestamp)
            let isReentry = (curr.t - prev.t) > 0.8

            // Detect direction change (local extremum)
            let d1 = curr.normX - prev.normX
            let d2 = next.normX - curr.normX
            let isExtremum = (d1 * d2 < 0) && abs(d1) > 0.005

            if isReentry || dxFromLast >= threshold || isExtremum || dtFromLast >= 2.5 {
                kept.append(TrackingPoint(t: curr.t, x: curr.normX))
                lastKept = curr
            }
        }

        if let last = smoothed.last, last.t > lastKept.t {
            kept.append(TrackingPoint(t: last.t, x: last.normX))
        }

        return kept
    }
}

// MARK: - Color Signature Appearance Model

struct ColorSignature: Sendable {
    static let binCount = 40 // 4 grayscale bins + 12 hues * 3 saturations
    var bins: [Double]

    static func empty() -> ColorSignature {
        ColorSignature(bins: [Double](repeating: 0.0, count: binCount))
    }

    /// Extracts normalized HSV color histogram of the subject's torso from CVPixelBuffer
    static func extract(from pixelBuffer: CVPixelBuffer, box: CGRect) -> ColorSignature? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bufWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Vision coordinates: box.origin is bottom-left
        // Sample torso: width 20% to 80%, height 30% to 85%
        let xMin = max(0, min(bufWidth - 1, Int((box.origin.x + box.width * 0.20) * Double(bufWidth))))
        let xMax = max(xMin + 1, min(bufWidth - 1, Int((box.origin.x + box.width * 0.80) * Double(bufWidth))))

        let yBotNorm = box.origin.y + box.height * 0.30
        let yTopNorm = box.origin.y + box.height * 0.85
        let yMin = max(0, min(bufHeight - 1, Int((1.0 - yTopNorm) * Double(bufHeight))))
        let yMax = max(yMin + 1, min(bufHeight - 1, Int((1.0 - yBotNorm) * Double(bufHeight))))

        guard xMax > xMin, yMax > yMin else { return nil }

        var histogram = [Double](repeating: 0.0, count: binCount)
        var sampleCount = 0

        let stepX = max(1, (xMax - xMin) / 16)
        let stepY = max(1, (yMax - yMin) / 16)

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in stride(from: yMin, through: yMax, by: stepY) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: xMin, through: xMax, by: stepX) {
                let pixelOffset = rowOffset + x * 4
                let b = Double(buffer[pixelOffset]) / 255.0
                let g = Double(buffer[pixelOffset + 1]) / 255.0
                let r = Double(buffer[pixelOffset + 2]) / 255.0

                let maxVal = max(r, max(g, b))
                let minVal = min(r, min(g, b))
                let delta = maxVal - minVal
                let v = maxVal
                let s = maxVal == 0 ? 0 : delta / maxVal

                var binIndex = 0
                if s < 0.20 {
                    binIndex = min(3, max(0, Int(v * 4.0)))
                } else {
                    var h: Double = 0
                    if delta > 0.001 {
                        if maxVal == r {
                            h = (g - b) / delta
                        } else if maxVal == g {
                            h = 2.0 + (b - r) / delta
                        } else {
                            h = 4.0 + (r - g) / delta
                        }
                        h *= 60.0
                        if h < 0 { h += 360.0 }
                    }
                    let hBin = min(11, max(0, Int(h / 30.0)))
                    let sBin = min(2, max(0, Int(s * 3.0)))
                    binIndex = 4 + hBin * 3 + sBin
                }

                histogram[binIndex] += 1.0
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return nil }
        for i in 0..<binCount {
            histogram[i] /= Double(sampleCount)
        }

        return ColorSignature(bins: histogram)
    }

    /// Histogram intersection similarity in range [0.0, 1.0]
    func similarity(to other: ColorSignature) -> Double {
        var intersection = 0.0
        for i in 0..<min(bins.count, other.bins.count) {
            intersection += min(bins[i], other.bins[i])
        }
        return max(0.0, min(1.0, intersection))
    }

    /// Blends current signature with new observation
    func blended(with other: ColorSignature, weight: Double) -> ColorSignature {
        let w = max(0.0, min(1.0, weight))
        var newBins = [Double](repeating: 0.0, count: bins.count)
        for i in 0..<bins.count {
            newBins[i] = bins[i] * (1.0 - w) + other.bins[i] * w
        }
        return ColorSignature(bins: newBins)
    }
}

// MARK: - Internal State

private struct TrackedSubjectState {
    var center: CGPoint
    var box: CGRect
    var velocityX: Double
    var consecutiveLostFrames: Int
    var isOutOfFrame: Bool
    var lastTime: Double
    var initialSignature: ColorSignature
    var currentSignature: ColorSignature
}

private extension CGRect {
    var area: CGFloat {
        return max(0, width) * max(0, height)
    }
}
