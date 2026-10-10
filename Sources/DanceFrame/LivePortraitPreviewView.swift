import SwiftUI
import AppKit

struct LivePortraitPreviewView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("02 / YOUR CUT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "#a8abb4"))
                Spacer()
                Text("9:16")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#a8abb4"))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color(hex: "#1a1b1f"))

            // Preview Canvas Container (9:16 aspect ratio)
            ZStack {
                Color(hex: "#0c0e10")

                if let img = vm.engine.currentCroppedImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 6) {
                        Text("Your moment,\nfront and center.")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundColor(Color(hex: "#676b75"))
                    }
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#353840"), lineWidth: 1))
            .padding(10)

            Text("Live crop preview")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#737781"))
                .padding(.bottom, 8)
        }
        .frame(width: 230)
        .background(Color(hex: "#1a1b1f"))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#303238"), lineWidth: 1))
    }
}
