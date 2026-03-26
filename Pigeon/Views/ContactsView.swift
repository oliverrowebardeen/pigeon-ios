import SwiftUI

struct ContactsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                if contacts.isEmpty {
                    emptyState
                } else {
                    contactsList
                }
            }
            .navigationTitle("Contacts")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: Peer.self) { peer in
                ContactProfileView(peer: peer)
            }
        }
    }

    private var contacts: [Peer] {
        coordinator.contactPeers()
    }

    private var contactsList: some View {
        List {
            ForEach(contacts) { peer in
                NavigationLink(value: peer) {
                    ContactRowView(peer: peer, reachability: coordinator.directConversationReachability(for: peer.publicKey))
                }
                .listRowBackground(PigeonTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 46))
                .foregroundColor(PigeonTheme.textTertiary)

            Text("No contacts yet")
                .font(PigeonTheme.headlineFont)
                .foregroundColor(PigeonTheme.textSecondary)

            Text("Profiles you scan or people you message will show up here.")
                .font(PigeonTheme.captionFont)
                .foregroundColor(PigeonTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

private struct ContactRowView: View {
    let peer: Peer
    let reachability: DirectConversationReachability

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(PigeonTheme.accent.opacity(0.15))
                .frame(width: 42, height: 42)
                .overlay {
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(PigeonTheme.accent)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(PigeonTheme.headlineFont)
                    .foregroundColor(PigeonTheme.textPrimary)

                Text(peer.pigeonID)
                    .font(PigeonTheme.monoFont)
                    .foregroundColor(PigeonTheme.textTertiary)

                Label(statusText, systemImage: statusSymbolName)
                    .font(PigeonTheme.captionFont)
                    .foregroundColor(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        peer.displayName ?? peer.pigeonID
    }

    private var statusText: String {
        switch reachability {
        case .inRange:
            return "In Range"
        case .meshReachable:
            return "Mesh Reachable"
        case .connectedToInternet:
            return "Connected to Internet"
        case .outOfRange:
            return "Out of Range"
        }
    }

    private var statusColor: Color {
        switch reachability {
        case .inRange:
            return PigeonTheme.success
        case .meshReachable:
            return PigeonTheme.accent
        case .connectedToInternet:
            return PigeonTheme.internet
        case .outOfRange:
            return PigeonTheme.error
        }
    }

    private var statusSymbolName: String {
        switch reachability {
        case .inRange:
            return "antenna.radiowaves.left.and.right"
        case .meshReachable:
            return "point.3.connected.trianglepath.dotted"
        case .connectedToInternet:
            return "globe"
        case .outOfRange:
            return "wifi.slash"
        }
    }
}
