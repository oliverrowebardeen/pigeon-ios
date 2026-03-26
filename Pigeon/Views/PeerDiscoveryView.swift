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

                if coordinator.nearbyContacts.isEmpty {
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
            if coordinator.connectedMeshNodeCount > 0 {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundColor(PigeonTheme.accent)
                        Text("Connected to \(coordinator.connectedMeshNodeCount) mesh \(coordinator.connectedMeshNodeCount == 1 ? "node" : "nodes")")
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(PigeonTheme.textSecondary)
                        Spacer()
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    .listRowBackground(PigeonTheme.surface)
                }
            }

            Section {
                ForEach(coordinator.nearbyContacts) { peer in
                    PeerRowView(peer: peer) {
                        startConversation(with: peer)
                    }
                    .listRowBackground(PigeonTheme.surface)
                }
            } header: {
                HStack {
                    Text("Nearby")
                    Spacer()
                    Text("\(coordinator.nearbyContacts.count)")
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
            print("[Pigeon] Peer discovery error: \(error)")
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
