import SwiftUI

struct PeerDiscoveryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var navigationPath = NavigationPath()

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
        do {
            let conversation = try coordinator.startConversation(with: peer)
            navigationPath.append(conversation)
        } catch {
            // Handle error
        }
    }
}
