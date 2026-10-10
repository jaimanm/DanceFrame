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
    /// Returns decimated, smoothed `TrackingPoint`s ready to be added to the timeline.
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

        // Sequence request handler for temporal object tracking fallback
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

            // Step 1: Detect humans in the frame
            let humanObservations = detectHumans(in: pixelBuffer)

            if trackedState == nil {
                // Initialize tracking: search for the target person
                if let bestCandidate = selectInitialSubject(
                    observations: humanObservations,
                    targetCenterHintX: initialPersonCenterHint
                ) {
                    let center = CGPoint(x: bestCandidate.midX, y: bestCandidate.midY)
                    trackedState = TrackedSubjectState(
                        center: center,
                        box: bestCandidate,
                        velocityX: 0.0,
                        consecutiveLostFrames: 0,
                        isOutOfFrame: false,
                        lastTime: currentTime
                    )
                    lastObservation = VNDetectedObjectObservation(boundingBox: bestCandidate)

                    // Record initial sample
                    let normX = calculateCropNormX(
                        personCenterNormX: Double(center.x),
                        meta: metadata,
                        availableW: availableW
                    )
                    rawSamples.append((t: currentTime, normX: normX))
                } else {
                    // If no person detected within first 45 processed frames (~1.5s), fail early
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

                // Predict expected position based on velocity
                let predictedX = state.center.x + CGFloat(state.velocityX * dt)

                // Find best matching human observation
                let matchedCandidate = matchCandidate(
                    observations: humanObservations,
                    predictedX: predictedX,
                    state: state,
                    dt: dt
                )

                if let matchedBox = matchedCandidate {
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

                    lastObservation = VNDetectedObjectObservation(boundingBox: matchedBox)

                    let normX = calculateCropNormX(
                        personCenterNormX: Double(newCenterX),
                        meta: metadata,
                        availableW: availableW
                    )
                    rawSamples.append((t: currentTime, normX: normX))
                } else {
                    // Detection did not match or person is occluded / out of frame
                    // Try VNTrackObjectRequest as short-term bridge if available
                    var trackedViaVision = false
                    if let prevObs = lastObservation, state.consecutiveLostFrames < 4 {
                        let trackReq = VNTrackObjectRequest(detectedObjectObservation: prevObs)
                        trackReq.trackingLevel = .fast
                        try? sequenceHandler.perform([trackReq], on: pixelBuffer)
                        if let res = trackReq.results?.first as? VNDetectedObjectObservation,
                           res.confidence > 0.25 {
                            let trackBox = res.boundingBox
                            // Verify that tracking didn't wildly jump to a passerby
                            if abs(trackBox.midX - predictedX) < 0.15 {
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

                    if !trackedViaVision {
                        // Coasting / Handling occlusion or out-of-frame
                        state.consecutiveLostFrames += 1

                        // Check if near edge of screen
                        if state.center.x <= 0.08 || state.center.x >= 0.92 {
                            state.isOutOfFrame = true
                            state.velocityX = 0
                        } else {
                            // Decaying coast velocity during occlusion
                            state.velocityX *= 0.80
                            state.center.x = max(0.02, min(0.98, state.center.x + CGFloat(state.velocityX * dt)))
                        }

                        state.lastTime = currentTime

                        // Keep holding or coasting position so camera stays steady
                        let normX = calculateCropNormX(
                            personCenterNormX: Double(state.center.x),
                            meta: metadata,
                            availableW: availableW
                        )
                        rawSamples.append((t: currentTime, normX: normX))
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
                        // If not already covered by a rectangle observation, add it
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

    // MARK: - Matching & Association

    private func selectInitialSubject(
        observations: [CGRect],
        targetCenterHintX: Double
    ) -> CGRect? {
        guard !observations.isEmpty else { return nil }

        // Pick observation whose midX is closest to targetCenterHintX
        return observations.min { a, b in
            let distA = abs(Double(a.midX) - targetCenterHintX)
            let distB = abs(Double(b.midX) - targetCenterHintX)
            // If distances are close, prefer the larger (closer/clearer) subject
            if abs(distA - distB) < 0.08 {
                return a.area > b.area
            }
            return distA < distB
        }
    }

    private func matchCandidate(
        observations: [CGRect],
        predictedX: CGFloat,
        state: TrackedSubjectState,
        dt: Double
    ) -> CGRect? {
        guard !observations.isEmpty else { return nil }

        // Maximum allowed distance from predicted position (normalized)
        // Dancers can move briskly, but ~25% of the frame per 0.2s is maximum physically reasonable
        let maxAllowedJump: CGFloat = max(0.12, CGFloat(0.40 * dt))

        var bestMatch: CGRect? = nil
        var bestScore: CGFloat = CGFloat.greatestFiniteMagnitude

        for obs in observations {
            let distX = abs(obs.midX - predictedX)
            let distY = abs(obs.midY - state.center.y)
            let sizeDiff = abs(obs.width - state.box.width) / max(0.01, state.box.width)

            // Gate: discard detections that jumped unrealistically far
            if distX > maxAllowedJump {
                continue
            }

            // Weighted score: horizontal position consistency is primary
            let score = distX * 2.0 + distY * 0.8 + sizeDiff * 0.4
            if score < bestScore {
                bestScore = score
                bestMatch = obs
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
        var smoothed: [(t: Double, normX: Double)] = []
        for i in 0..<rawSamples.count {
            let prev = rawSamples[max(0, i - 1)].normX
            let curr = rawSamples[i].normX
            let next = rawSamples[min(rawSamples.count - 1, i + 1)].normX
            let avg = (prev * 0.25) + (curr * 0.50) + (next * 0.25)
            smoothed.append((t: rawSamples[i].t, normX: avg))
        }

        // Step 2: Adaptive decimation
        // Keep keyframes when:
        // - Start & End frames
        // - Movement exceeds sensitivity threshold
        // - Direction change (local extremum in movement)
        // - Max time gap elapsed (~2.5s) to ensure responsiveness
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

            // Check if local extremum (direction reversal)
            let d1 = curr.normX - prev.normX
            let d2 = next.normX - curr.normX
            let isExtremum = (d1 * d2 < 0) && abs(d1) > 0.005

            if dxFromLast >= threshold || isExtremum || dtFromLast >= 2.5 {
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

private struct TrackedSubjectState {
    var center: CGPoint
    var box: CGRect
    var velocityX: Double
    var consecutiveLostFrames: Int
    var isOutOfFrame: Bool
    var lastTime: Double
}

private extension CGRect {
    var area: CGFloat {
        return max(0, width) * max(0, height)
    }
}
