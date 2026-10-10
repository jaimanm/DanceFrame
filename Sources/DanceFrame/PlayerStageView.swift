import SwiftUI
import AVKit
import AppKit

struct NativeVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct PlayerStageView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var engine: VideoPlayerEngine

    init(vm: AppViewModel) {
        self.vm = vm
        self.engine = vm.engine
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stage Header
            HStack {
                Text("01 / SOURCE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#a8abb4"))
                Spacer()
                if let meta = vm.engine.metadata {
                    Text("\(meta.name) · \(meta.width) × \(meta.height) · \(String(format: "%.2f", meta.fps)) fps")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#a8abb4"))
                        .lineLimit(1)
                } else {
                    Text("16:9 → 9:16")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#a8abb4"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color(hex: "#1a1b1f"))

            // Video Stage with Crop Overlay
            GeometryReader { geo in
                ZStack {
                    Color(hex: "#08090b")

                    if vm.engine.metadata != nil {
                        NativeVideoPlayerView(player: vm.engine.player)
                            .allowsHitTesting(false)

                        CropOverlayCanvas(vm: vm, stageSize: geo.size)
                    } else {
                        // Empty placeholder
                        VStack(spacing: 12) {
                            Text("⌑")
                                .font(.system(size: 48))
                                .foregroundColor(Color(hex: "#ddff8f"))
                            Text("You lead. The frame follows.")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Open a landscape video, find yourself, and click to place\na tracking point. Add more wherever you move.")
                                .font(.system(size: 12))
                                .multilineTextAlignment(.center)
                                .foregroundColor(Color(hex: "#a1a3ad"))

                            Button(action: { vm.openVideoDialog() }) {
                                Text("＋ Open Video")
                                    .font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .background(Color(hex: "#ddff8f"))
                                    .foregroundColor(Color(hex: "#172011"))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                        }
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            // Transport Bar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button(action: { vm.engine.step(frames: -1) }) {
                        Text("│◀")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(vm.engine.metadata == nil)
                    .buttonStyle(.plain)

                    Button(action: { vm.engine.togglePlayPause() }) {
                        Text(vm.engine.isPlaying ? "Ⅱ" : "▶")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Color(hex: "#32353b"))
                            .clipShape(Circle())
                    }
                    .disabled(vm.engine.metadata == nil)
                    .buttonStyle(.plain)

                    Button(action: { vm.engine.step(frames: 1) }) {
                        Text("▶│")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(vm.engine.metadata == nil)
                    .buttonStyle(.plain)

                    // Clock
                    let effectiveTime = vm.engine.isScrubbing ? vm.engine.scrubTime : vm.engine.currentTime
                    let duration = vm.engine.metadata?.duration ?? 0
                    HStack(spacing: 4) {
                        Text(MotionInterpolator.formatTime(effectiveTime))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                        Text("/")
                            .foregroundColor(Color(hex: "#727681"))
                        Text(MotionInterpolator.formatTime(duration))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hex: "#727681"))
                    }
                    .padding(.leading, 8)
                }

                Spacer()

                // Speed Menu
                HStack(spacing: 6) {
                    Text("Speed")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#b2b5bd"))

                    Picker("", selection: Binding(
                        get: { vm.engine.playbackRate },
                        set: { vm.engine.setRate($0) }
                    )) {
                        Text("0.25×").tag(Float(0.25))
                        Text("0.5×").tag(Float(0.5))
                        Text("1×").tag(Float(1.0))
                        Text("1.5×").tag(Float(1.5))
                    }
                    .pickerStyle(.menu)
                    .frame(width: 76)
                    .disabled(vm.engine.metadata == nil)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color(hex: "#1a1b1f"))
        }
        .background(Color(hex: "#1a1b1f"))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#303238"), lineWidth: 1))
    }
}

struct CropOverlayCanvas: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var engine: VideoPlayerEngine
    let stageSize: CGSize

    init(vm: AppViewModel, stageSize: CGSize) {
        self.vm = vm
        self.engine = vm.engine
        self.stageSize = stageSize
    }

    var body: some View {
        GeometryReader { geo in
            if let meta = vm.engine.metadata {
                let scale = min(geo.size.width / Double(meta.width), geo.size.height / Double(meta.height))
                let videoRenderW = Double(meta.width) * scale
                let videoRenderH = Double(meta.height) * scale
                let videoLeft = (geo.size.width - videoRenderW) / 2.0
                let videoTop = (geo.size.height - videoRenderH) / 2.0

                let effectiveTime = vm.engine.isScrubbing ? vm.engine.scrubTime : vm.engine.currentTime
                let normX = MotionInterpolator.position(at: effectiveTime, points: vm.points, mode: vm.mode)
                let availableW = Double(meta.width - meta.cropWidth)
                let cropPixelX = normX * availableW

                let cropBoxLeft = videoLeft + cropPixelX * scale
                let cropBoxW = Double(meta.cropWidth) * scale

                ZStack(alignment: .topLeading) {
                    // Left shaded letterbox
                    Rectangle()
                        .fill(Color.black.opacity(0.60))
                        .frame(width: max(0, cropBoxLeft - videoLeft), height: videoRenderH)
                        .position(x: videoLeft + (max(0, cropBoxLeft - videoLeft)) / 2, y: videoTop + videoRenderH / 2)

                    // Right shaded letterbox
                    let rightLeft = cropBoxLeft + cropBoxW
                    let rightW = max(0, (videoLeft + videoRenderW) - rightLeft)
                    Rectangle()
                        .fill(Color.black.opacity(0.60))
                        .frame(width: rightW, height: videoRenderH)
                        .position(x: rightLeft + rightW / 2, y: videoTop + videoRenderH / 2)

                    // Crop Border & Guides
                    ZStack(alignment: .topLeading) {
                        // Green border
                        Rectangle()
                            .stroke(Color(hex: "#ddff8f"), lineWidth: 1.8)
                            .frame(width: cropBoxW, height: videoRenderH)

                        // Dashed center vertical line
                        Line()
                            .stroke(Color(hex: "#ddff8f").opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                            .frame(width: 1, height: videoRenderH)
                            .position(x: cropBoxW / 2, y: videoRenderH / 2)

                        // "YOUR CUT" Badge
                        HStack(spacing: 0) {
                            Text("YOUR CUT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#1a2116"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(hex: "#ddff8f"))
                                .cornerRadius(2)
                        }
                        .padding(8)
                    }
                    .frame(width: cropBoxW, height: videoRenderH)
                    .position(x: cropBoxLeft + cropBoxW / 2, y: videoTop + videoRenderH / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            vm.engine.pause()
                            let clickX = value.location.x
                            let clickInsideVideo = clickX - videoLeft
                            let clickSourceX = clickInsideVideo / scale
                            let targetCropX = (clickSourceX - Double(meta.cropWidth) / 2.0) / availableW
                            let clampedX = max(0.0, min(1.0, targetCropX))
                            vm.addOrUpdatePoint(x: clampedX)
                        }
                )
            }
        }
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
