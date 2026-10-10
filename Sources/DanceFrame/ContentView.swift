import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 20) {
                // Header Bar
                HStack(spacing: 24) {
                    HStack(spacing: 8) {
                        Text("▥")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(hex: "#ddff8f"))
                        Text("DanceFrame")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text("YOUR MOVEMENT. YOUR FRAME.")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#8b8e96"))
                        .tracking(1.4)

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: "#ddff8f"))
                            .frame(width: 6, height: 6)
                        Text("Local & private")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#afb1b8"))
                    }
                }
                .padding(.horizontal, 24)
                .frame(height: 56)
                .background(Color(hex: "#111214"))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: "#303238")), alignment: .bottom)

                // Intro & Open Video Callout
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("THE SPOTLIGHT IS YOURS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: "#ddff8f"))
                            .tracking(1.2)

                        Text("Stay in the frame.")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)

                        Text("Turn the whole dance floor into your own vertical video.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#a1a3ad"))
                    }

                    Spacer()

                    Button(action: { vm.openVideoDialog() }) {
                        HStack(spacing: 6) {
                            Text("＋ Open video")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color(hex: "#ddff8f"))
                        .foregroundColor(Color(hex: "#172011"))
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("o", modifiers: .command)
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)

                // Notice Banner
                HStack {
                    Text(vm.noticeText)
                        .font(.system(size: 11))
                        .foregroundColor(vm.isNoticeError ? Color(hex: "#ffa49b") : Color(hex: "#9a9da7"))
                    Spacer()
                }
                .padding(.horizontal, 28)

                // Workspace: Stage + 9:16 Preview
                HStack(alignment: .top, spacing: 20) {
                    PlayerStageView(vm: vm)
                    LivePortraitPreviewView(vm: vm)
                }
                .padding(.horizontal, 28)

                // Motion Timeline
                TimelineView(vm: vm)
                    .padding(.horizontal, 28)

                // Trim Controls
                TrimPanel(vm: vm)
                    .padding(.horizontal, 28)

                // Motion Flow & Export
                BottomActionPanel(vm: vm)
                    .padding(.horizontal, 28)

                // Footer
                HStack {
                    Text("Made for the moments you don’t want to lose.")
                    Spacer()
                    Text("No accounts. No uploads to the cloud. No watermarks.")
                }
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#696f7c"))
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 1550)
            .padding(.vertical, 10)
        }
        .background(Color(hex: "#111214"))
        .onAppear {
            setupGlobalKeyMonitor()
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private func setupGlobalKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Space always toggles play/pause globally and unfocuses any active text field
            if event.keyCode == 49 { // Space
                if let firstResp = NSApp.keyWindow?.firstResponder, firstResp is NSTextView || firstResp is NSTextField {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                vm.engine.togglePlayPause()
                return nil
            }

            // For other keys, if actively editing in a text field, let it handle text editing
            if let firstResp = NSApp.keyWindow?.firstResponder, firstResp is NSTextView || firstResp is NSTextField {
                // Return (36) or Escape (53) in a text field commits and clears focus
                if event.keyCode == 36 || event.keyCode == 53 {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return event
            }

            switch event.keyCode {
            case 123: // Left Arrow
                let stepAmount = event.modifierFlags.contains(.shift) ? -10 : -1
                vm.engine.step(frames: stepAmount)
                return nil
            case 124: // Right Arrow
                let stepAmount = event.modifierFlags.contains(.shift) ? 10 : 1
                vm.engine.step(frames: stepAmount)
                return nil
            case 40: // K key
                let t = vm.engine.isScrubbing ? vm.engine.scrubTime : vm.engine.currentTime
                let normX = MotionInterpolator.position(at: t, points: vm.points, mode: vm.mode)
                vm.addOrUpdatePoint(x: normX, at: t)
                return nil
            case 6: // Z key
                if event.modifierFlags.contains(.command) {
                    vm.undo()
                    return nil
                }
            case 51, 117: // Backspace (51) / Delete (117)
                if !vm.selectedPointIds.isEmpty {
                    vm.deleteSelectedPoints()
                    return nil
                }
            case 53: // Escape key
                if !vm.selectedPointIds.isEmpty {
                    vm.clearSelection()
                    return nil
                }
            default:
                break
            }
            return event
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
