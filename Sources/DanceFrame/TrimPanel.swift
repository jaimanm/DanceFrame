import SwiftUI

struct TrimPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TRIM YOUR VIDEO")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#ddff8f"))
                Text("Keep just the part you want. Tracking stays aligned to the original timeline.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#a1a3ad"))
            }

            HStack(spacing: 14) {
                // Start
                HStack(spacing: 6) {
                    Text("Start")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#b2b5bd"))
                    TextField("", value: $vm.trim.start, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 72)
                        .padding(5)
                        .background(Color(hex: "#24262a"))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                }

                Button(action: { vm.setTrimStartHere() }) {
                    Text("Set start here")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#26282d"))
                        .foregroundColor(Color(hex: "#eeeeee"))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(vm.engine.metadata == nil)

                // End
                HStack(spacing: 6) {
                    Text("End")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#b2b5bd"))
                    TextField("", value: $vm.trim.end, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 72)
                        .padding(5)
                        .background(Color(hex: "#24262a"))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                }

                Button(action: { vm.setTrimEndHere() }) {
                    Text("Set end here")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#26282d"))
                        .foregroundColor(Color(hex: "#eeeeee"))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(vm.engine.metadata == nil)

                Button(action: { vm.resetTrim() }) {
                    Text("Reset trim")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#26282d"))
                        .foregroundColor(Color(hex: "#eeeeee"))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#41434a"), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(vm.engine.metadata == nil)

                Spacer()

                // Duration kept
                let kept = max(0, vm.trim.end - vm.trim.start)
                Text(vm.engine.metadata != nil ? "\(MotionInterpolator.formatTime(kept)) kept" : "No video loaded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#ddff8f"))
            }
        }
        .padding(18)
        .background(Color(hex: "#1a1b1f"))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#303238"), lineWidth: 1))
    }
}
