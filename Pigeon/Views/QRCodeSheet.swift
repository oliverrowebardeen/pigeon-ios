import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeSheet: View {
    let payloadString: String
    let pigeonID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PigeonTheme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Your QR Code")
                    .font(PigeonTheme.titleFont)
                    .foregroundColor(PigeonTheme.textPrimary)

                if let image = generateQRCode(from: payloadString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 250, height: 250)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(pigeonID)
                    .font(PigeonTheme.monoFont)
                    .foregroundColor(PigeonTheme.textSecondary)

                Text("Other Pigeon users can scan this\nto add your profile as a contact.")
                    .font(PigeonTheme.captionFont)
                    .foregroundColor(PigeonTheme.textTertiary)
                    .multilineTextAlignment(.center)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(PigeonTheme.accent)
                .padding(.top, 8)
            }
            .padding(32)
        }
        .presentationDetents([.medium, .large])
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scale = 250.0 / outputImage.extent.width
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
