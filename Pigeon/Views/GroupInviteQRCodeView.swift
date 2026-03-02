import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct GroupInviteQRCodeView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID

    @State private var tokenString: String = ""
    @State private var loadError: String?
    @State private var copied = false
    @State private var showScanner = false
    @State private var scanResultMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    Text("Group Invite")
                        .font(PigeonTheme.titleFont)
                        .foregroundColor(PigeonTheme.textPrimary)

                    if let image = generateQRCode(from: tokenString), !tokenString.isEmpty {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let loadError {
                        Text(loadError)
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(PigeonTheme.error)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Invite expires in 10 minutes.")
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(PigeonTheme.textSecondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = tokenString
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy Invite", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PigeonTheme.accent)
                        .disabled(tokenString.isEmpty)

                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan Invite", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(PigeonTheme.accent)
                    }

                    if let scanResultMessage {
                        Text(scanResultMessage)
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(PigeonTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Invite")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do {
                    tokenString = try coordinator.makeGroupInviteTokenString(groupID: groupID)
                } catch {
                    loadError = "Could not generate invite token."
                }
            }
            .sheet(isPresented: $showScanner) {
                scannerSheet
            }
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRCodeScannerView { code in
                do {
                    _ = try coordinator.consumeGroupInviteTokenString(code)
                    scanResultMessage = "Invite accepted. Group added to conversations."
                    showScanner = false
                } catch {
                    scanResultMessage = "Invite invalid or expired."
                    showScanner = false
                }
            }
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        showScanner = false
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        guard !string.isEmpty else { return nil }

        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scale = 260.0 / outputImage.extent.width
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
