import SwiftUI

struct PeerRowView: View {
    let peer: Peer
    let onMessage: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(PigeonTheme.accent.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundColor(PigeonTheme.accent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName ?? peer.pigeonID)
                    .font(PigeonTheme.headlineFont)
                    .foregroundColor(PigeonTheme.textPrimary)

                HStack(spacing: 6) {
                    Text(peer.pigeonID)
                        .font(PigeonTheme.monoFont)
                        .foregroundColor(PigeonTheme.textTertiary)

                    if let rssi = peer.rssi {
                        signalIndicator(rssi: rssi)
                    }
                }
            }

            Spacer()

            Button("Message") {
                onMessage()
            }
            .buttonStyle(.borderedProminent)
            .tint(PigeonTheme.accent)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func signalIndicator(rssi: Int) -> some View {
        HStack(spacing: 2) {
            let strength = signalStrength(rssi: rssi)
            ForEach(0 ..< 3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < strength ? PigeonTheme.accent : PigeonTheme.textTertiary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }

    private func signalStrength(rssi: Int) -> Int {
        if rssi > -50 { return 3 }      // Near
        if rssi > -70 { return 2 }      // Medium
        return 1                          // Far
    }
}
