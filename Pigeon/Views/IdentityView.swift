import CryptoKit
import SwiftUI

struct IdentityView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var displayName: String = ""
    @State private var showingQR = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        avatarSection
                        pigeonIDSection
                        publicKeySection
                        displayNameSection
                        qrButton
                        privacyNote
                    }
                    .padding(.top, 32)
                    .padding(.horizontal, 24)
                }
            }
            .navigationTitle("Identity")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                displayName = coordinator.identity.displayName ?? ""
            }
            .sheet(isPresented: $showingQR) {
                QRCodeSheet(
                    publicKeyHex: coordinator.identity.publicKey.rawRepresentation.hexEncodedString,
                    pigeonID: coordinator.identity.pigeonID
                )
            }
        }
    }

    private var avatarSection: some View {
        Circle()
            .fill(PigeonTheme.accent.opacity(0.15))
            .frame(width: 100, height: 100)
            .overlay {
                Text(String(coordinator.identity.pigeonID.prefix(2)).uppercased())
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(PigeonTheme.accent)
            }
    }

    private var pigeonIDSection: some View {
        VStack(spacing: 4) {
            Text("Your Pigeon ID")
                .font(PigeonTheme.captionFont)
                .foregroundColor(PigeonTheme.textSecondary)
            Text(coordinator.identity.pigeonID)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(PigeonTheme.textPrimary)
        }
    }

    private var publicKeySection: some View {
        VStack(spacing: 4) {
            Text("Public Key")
                .font(PigeonTheme.captionFont)
                .foregroundColor(PigeonTheme.textSecondary)

            Text(coordinator.identity.publicKey.rawRepresentation.hexEncodedString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PigeonTheme.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Button {
                UIPasteboard.general.string = coordinator.identity.publicKey.rawRepresentation.hexEncodedString
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(PigeonTheme.captionFont)
                    .foregroundColor(PigeonTheme.accent)
            }
            .padding(.top, 4)
        }
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display Name")
                .font(PigeonTheme.captionFont)
                .foregroundColor(PigeonTheme.textSecondary)

            TextField("Optional display name", text: $displayName)
                .textFieldStyle(.plain)
                .padding(12)
                .background(PigeonTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .foregroundColor(PigeonTheme.textPrimary)
                .submitLabel(.done)
                .onSubmit {
                    coordinator.updateDisplayName(normalizedDisplayName)
                }

            Button("Save Display Name") {
                coordinator.updateDisplayName(normalizedDisplayName)
            }
            .buttonStyle(.borderedProminent)
            .tint(PigeonTheme.accent)
            .disabled(normalizedDisplayName == coordinator.identity.displayName)
        }
    }

    private var qrButton: some View {
        Button {
            showingQR = true
        } label: {
            Label("Show QR Code", systemImage: "qrcode")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(PigeonTheme.accent)
    }

    private var privacyNote: some View {
        Text("Your identity is stored only on this device.\nNo account, no phone number, no tracking.")
            .font(PigeonTheme.captionFont)
            .foregroundColor(PigeonTheme.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }

    private var normalizedDisplayName: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
