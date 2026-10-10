import SwiftUI
import AppKit

struct TimelineView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var engine: VideoPlayerEngine

    init(vm: AppViewModel) {
        self.vm = vm
        self.engine = vm.engine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Text("MOTION TIMELINE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: "#ddff8f"))
                    Text("\(vm.points.count) tracking point\(vm.points.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#81858f"))

                    if !vm.selectedPointIds.isEmpty {
                        Text("·")
                            .foregroundColor(Color(hex: "#50545f"))
                        Text("\(vm.selectedPointIds.count) selected")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(hex: "#ddff8f"))
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if !vm.selectedPointIds.isEmpty {
                        Button(action: { vm.deleteSelectedPoints() }) {
                            HStack(spacing: 4) {
                                Text("🗑 Delete")
                                Text("(\(vm.selectedPointIds.count))")
                                    .font(.system(size: 10, weight: .bold))
                                Text("⌫")
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(2)
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(hex: "#3d1e1c"))
                            .foregroundColor(Color(hex: "#ff9c91"))
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#6b2c28"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button(action: { vm.clearSelection() }) {
                            Text("Deselect")
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color(hex: "#26282d"))
                                .foregroundColor(Color(hex: "#a6acb7"))
                                .cornerRadius(5)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: { vm.undo() }) {
                        Text("↶ Undo")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(hex: "#26282d"))
                            .foregroundColor(Color(hex: "#eeeeee"))
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.undoHistory.isEmpty)

                    Button(action: {
                        let t = vm.engine.isScrubbing ? vm.engine.scrubTime : vm.engine.currentTime
                        let normX = MotionInterpolator.position(at: t, points: vm.points, mode: vm.mode)
                        vm.addOrUpdatePoint(x: normX, at: t)
                    }) {
                        HStack(spacing: 4) {
                            Text("＋ Add point")
                            Text("K")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(hex: "#111214"))
                                .cornerRadius(3)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#2c3430"))
                        .foregroundColor(Color(hex: "#ddff8f"))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#454f3e"), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.engine.metadata == nil)
                }
            }

            // Auto-Track Controls Bar
            if vm.engine.metadata != nil {
                HStack(spacing: 12) {
                    if vm.isAutoTracking {
                        HStack(spacing: 10) {
                            ProgressView(value: vm.autoTrackProgress)
                                .progressViewStyle(.linear)
                                .tint(Color(hex: "#ddff8f"))
                                .frame(width: 160)

                            Text(String(format: "Auto-tracking: %.0f%%", vm.autoTrackProgress * 100))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(hex: "#ddff8f"))

                            Button("Cancel") {
                                vm.cancelAutoTrack()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#ffa49b"))
                            .buttonStyle(.plain)
                        }
                    } else {
                        let playheadTime = vm.engine.isScrubbing ? vm.engine.scrubTime : vm.engine.currentTime
                        Button(action: {
                            vm.startAutoTrack()
                        }) {
                            HStack(spacing: 6) {
                                Text("⦿")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Auto-Track from \(MotionInterpolator.formatTime(playheadTime))")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(hex: "#1d2b27"))
                            .foregroundColor(Color(hex: "#ddff8f"))
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#3b5843"), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 6) {
                            Text("Sensitivity:")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#888c96"))

                            Picker("", selection: $vm.autoTrackSensitivity) {
                                ForEach(TrackingSensitivity.allCases, id: \.self) { s in
                                    Text(s.rawValue).tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 95)
                        }

                        Text("Scrub to the frame the dancer appears, then click to track.")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6b707d"))
                    }

                    Spacer()
                }
                .padding(.vertical, 2)
            }

            // Timeline Track
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let duration = max(0.001, vm.engine.metadata?.duration ?? 1.0)
                let effectiveTime = vm.engine.isScrubbing ? vm.engine.scrubTime : vm.engine.currentTime
                let normTime = max(0, min(1, effectiveTime / duration))
                let handleX = normTime * w

                ZStack(alignment: .leading) {
                    // Track background with subtle tick marks
                    Rectangle()
                        .fill(Color(hex: "#141518"))
                        .border(Color(hex: "#40434a"), width: 1)

                    // Left Trim Shade
                    let trimStartNorm = min(1, max(0, vm.trim.start / duration))
                    Rectangle()
                        .fill(Color.black.opacity(0.65))
                        .frame(width: trimStartNorm * w)

                    // Right Trim Shade
                    let trimEndNorm = min(1, max(0, vm.trim.end / duration))
                    let rightShadeW = max(0, (1.0 - trimEndNorm) * w)
                    Rectangle()
                        .fill(Color.black.opacity(0.65))
                        .frame(width: rightShadeW)
                        .offset(x: trimEndNorm * w)

                    // Tracking Point Markers (Diamonds)
                    ForEach(vm.points) { point in
                        let pointNorm = min(1, max(0, point.t / duration))
                        let isSelected = vm.selectedPointIds.contains(point.id)

                        ZStack {
                            if isSelected {
                                Rectangle()
                                    .stroke(Color.white, lineWidth: 1.5)
                                    .frame(width: 13, height: 13)
                                    .rotationEffect(.degrees(45))
                            }

                            Rectangle()
                                .fill(isSelected ? Color.white : Color(hex: "#ddff8f"))
                                .frame(width: isSelected ? 10 : 9, height: isSelected ? 10 : 9)
                                .rotationEffect(.degrees(45))
                        }
                        .position(x: pointNorm * w, y: h - 11)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let isShift = NSEvent.modifierFlags.contains(.shift)
                            let isCommand = NSEvent.modifierFlags.contains(.command)
                            vm.handlePointClick(point, isShift: isShift, isCommand: isCommand)
                        }
                    }

                    // Scrubber Indicator Line & Green Marker Thumb
                    Rectangle()
                        .fill(Color(hex: "#ddff8f"))
                        .frame(width: 2, height: h)
                        .position(x: handleX, y: h / 2)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "#ddff8f"))
                        .frame(width: 8, height: 22)
                        .position(x: handleX, y: 12)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let meta = vm.engine.metadata else { return }
                            vm.engine.pause()
                            vm.engine.isScrubbing = true
                            let frac = max(0.0, min(1.0, value.location.x / w))
                            let targetSec = frac * meta.duration
                            vm.engine.scrubTime = targetSec
                            vm.engine.seek(to: targetSec)
                        }
                        .onEnded { value in
                            guard let meta = vm.engine.metadata else { return }
                            let frac = max(0.0, min(1.0, value.location.x / w))
                            let targetSec = frac * meta.duration
                            // Update currentTime immediately so the tick stays at the
                            // final scrub position while the async seek finishes.
                            vm.engine.currentTime = targetSec
                            vm.engine.isScrubbing = false
                            vm.engine.seek(to: targetSec)
                        }
                )
            }
            .frame(height: 42)

            // Timeline Labels
            HStack {
                Text("00:00")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "#747985"))
                Spacer()
                Text(MotionInterpolator.formatTime(vm.engine.metadata?.duration ?? 0))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "#747985"))
            }

            // Point Chips List
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if vm.points.isEmpty {
                        Text("Click on yourself in the source video or press K to add tracking points.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#757b86"))
                            .padding(.vertical, 4)
                    } else {
                        ForEach(Array(vm.points.enumerated()), id: \.element.id) { idx, point in
                            let isSelected = vm.selectedPointIds.contains(point.id)
                            HStack(spacing: 6) {
                                Button(action: {
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    let isCommand = NSEvent.modifierFlags.contains(.command)
                                    vm.handlePointClick(point, isShift: isShift, isCommand: isCommand)
                                }) {
                                    Text(String(format: "%02d · %@", idx + 1, MotionInterpolator.formatTime(point.t)))
                                        .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .monospaced))
                                        .foregroundColor(isSelected ? Color.white : Color(hex: "#eeeeee"))
                                }
                                .buttonStyle(.plain)

                                Button(action: { vm.deletePoint(id: point.id) }) {
                                    Text("×")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(isSelected ? Color(hex: "#ffa49b") : Color(hex: "#959ca6"))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isSelected ? Color(hex: "#343d3b") : Color(hex: "#252b2d"))
                            .cornerRadius(5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(isSelected ? Color(hex: "#ddff8f") : Color(hex: "#3b4146"), lineWidth: isSelected ? 1.5 : 1)
                            )
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(hex: "#1a1b1f"))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#303238"), lineWidth: 1))
    }
}
