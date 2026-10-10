import SwiftUI
import AppKit

struct BottomActionPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            // Motion Flow Section
            VStack(alignment: .leading, spacing: 10) {
                Text("MAKE IT FLOW")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#ddff8f"))

                Text("A little direction. A smooth result.")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text("Click on yourself at key moments. The crop glides between your points.\nAdd extra points around fast turns or direction changes.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#a1a3ad"))
                    .lineSpacing(4)

                HStack(spacing: 8) {
                    Text("Motion")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#b2b5bd"))

                    Picker("", selection: $vm.mode) {
                        ForEach(MotionMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                .padding(.top, 4)

                HStack(spacing: 6) {
                    kbd("←")
                    kbd("→")
                    Text("Step a frame")
                    Text("·").foregroundColor(.gray)
                    kbd("Shift")
                    Text("10 frames")
                    Text("·").foregroundColor(.gray)
                    kbd("Space")
                    Text("Play")
                    Text("·").foregroundColor(.gray)
                    kbd("K")
                    Text("Add point")
                }
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#888d98"))
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .background(Color(hex: "#303238"))

            // Export Section
            VStack(alignment: .leading, spacing: 12) {
                Text("READY FOR YOUR CLOSE-UP?")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#ddff8f"))

                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Text("Output")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#b2b5bd"))

                        Picker("", selection: $vm.exportSize) {
                            Text("1080 × 1920").tag("1080")
                            Text("720 × 1280").tag("720")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    Spacer()

                    Button(action: { vm.exportDialog() }) {
                        Text("Export vertical MP4 ↗")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(vm.points.isEmpty || vm.exporter.isExporting ? Color.gray.opacity(0.3) : Color(hex: "#ddff8f"))
                            .foregroundColor(vm.points.isEmpty || vm.exporter.isExporting ? Color.gray : Color(hex: "#172011"))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.points.isEmpty || vm.exporter.isExporting)
                }

                HStack(spacing: 16) {
                    Button(action: { vm.saveProjectDialog() }) {
                        Text("↓ Save tracking project")
                            .font(.system(size: 11))
                            .foregroundColor(vm.engine.metadata == nil ? .gray : Color(hex: "#a6acb7"))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.engine.metadata == nil)

                    Button(action: { vm.loadProjectDialog() }) {
                        Text("↑ Load tracking project")
                            .font(.system(size: 11))
                            .foregroundColor(vm.engine.metadata == nil ? .gray : Color(hex: "#a6acb7"))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.engine.metadata == nil)
                }
                .padding(.top, 4)

                // Export Progress & Status
                if vm.exporter.isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.exporter.statusMessage)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#b7c6a8"))

                        ProgressView(value: vm.exporter.progress)
                            .progressViewStyle(.linear)
                            .tint(Color(hex: "#ddff8f"))

                        Button("Cancel export") {
                            vm.exporter.cancel()
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#ffaaa0"))
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                } else if let completedURL = vm.exporter.completedURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.exporter.statusMessage)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#b7c6a8"))

                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([completedURL])
                        }) {
                            Text("Show exported video in Finder ↗")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color(hex: "#ddff8f"))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                } else if let err = vm.exporter.errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#ffa49b"))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Color(hex: "#1a1b1f"))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#303238"), lineWidth: 1))
    }

    private func kbd(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9))
            .foregroundColor(Color(hex: "#b4b8c0"))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(hex: "#26282d"))
            .cornerRadius(3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: "#4e535b"), lineWidth: 1))
    }
}
