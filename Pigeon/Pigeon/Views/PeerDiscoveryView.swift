import SwiftUI

struct PeerDiscoveryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var navigationPath = NavigationPath()
    @State private var pendingWarningPeer: Peer?
    @State private var pendingWarning: PeerKeyChangeWarning?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                if coordinator.nearbyPeers.isEmpty {
                    scanningState
                } else {
                    peerList
                }
            }
            .navigationTitle("Nearby")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(conversation: conversation)
            }
            .alert(
                "Security Warning",
                isPresented: warningBinding,
                presenting: pendingWarning
            ) { warning in
                Button("Cancel", role: .cancel) {
                    pendingWarningPeer = nil
                    pendingWarning = nil
                }
                Button("Trust New Key", role: .destructive) {
                    coordinator.confirmPeerKeyChange(for: warning.peerPublicKey)
                    if let peer = pendingWarningPeer {
                        startConversation(with: peer)
                    }
                    pendingWarningPeer = nil
                    pendingWarning = nil
                }
            } message: { warning in
                Text(
                    "\(warning.displayName) was previously trusted as \(warning.previousPigeonID), but is now advertising \(warning.currentPigeonID). Messaging is paused until you confirm this key change."
                )
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(PigeonTheme.accent)
                .symbolEffect(.pulse.wholeSymbol)
            Text("Scanning for nearby devices...")
                .font(PigeonTheme.bodyFont)
                .foregroundColor(PigeonTheme.textSecondary)
            Text("Make sure Bluetooth is on and\nanother Pigeon user is nearby.")
                .font(PigeonTheme.captionFont)
                .foregroundColor(PigeonTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var peerList: some View {
        List {
            Section {
                ForEach(coordinator.nearbyPeers) { peer in
                    PeerRowView(peer: peer) {
                        startConversation(with: peer)
                    }
                    .listRowBackground(PigeonTheme.surface)
                }
            } header: {
                HStack {
                    Text("Nearby")
                    Spacer()
                    Text("\(coordinator.nearbyPeers.count)")
                        .foregroundColor(PigeonTheme.accent)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func startConversation(with peer: Peer) {
        if let warning = coordinator.peerKeyChangeWarning(for: peer) {
            pendingWarningPeer = peer
            pendingWarning = warning
            return
        }

        do {
            let conversation = try coordinator.startConversation(with: peer)
            navigationPath.append(conversation)
        } catch {
            // Handle error
        }
    }

    private var warningBinding: Binding<Bool> {
        Binding(
            get: { pendingWarning != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWarning = nil
                    pendingWarningPeer = nil
                }
            }
        )
    }
}
