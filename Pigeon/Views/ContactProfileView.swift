import SwiftUI

struct ContactProfileView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let peer: Peer
    var showsDismissButton = false

    @State private var activeConversation: Conversation?
    @State private var pendingWarning: PeerKeyChangeWarning?
    @State private var draftDisplayName = ""
    @State private var showRenamePrompt = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Circle()
                        .fill(PigeonTheme.accent.opacity(0.18))
                        .frame(width: 84, height: 84)
                        .overlay {
                            Text(String(displayName.prefix(1)).uppercased())
                                .font(.system(size: 34, weight: .bold))
                                .foregroundColor(PigeonTheme.accent)
                        }

                    VStack(spacing: 6) {
                        Button {
                            startRenaming()
                        } label: {
                            HStack(spacing: 8) {
                                Text(displayName)
                                    .font(PigeonTheme.titleFont)
                                    .foregroundColor(PigeonTheme.textPrimary)
                                    .multilineTextAlignment(.center)

                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(PigeonTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.plain)

                        Text(resolvedPeer.pigeonID)
                            .font(PigeonTheme.monoFont)
                            .foregroundColor(PigeonTheme.textSecondary)

                        contactStatusBadge
                    }

                    Button {
                        startConversation()
                    } label: {
                        Text("Message")
                            .font(PigeonTheme.bodyFont.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PigeonTheme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(PigeonTheme.surface)
            }

            Section("Details") {
                detailRow(label: "Display Name", value: displayName)
                detailRow(label: "Pigeon ID", value: resolvedPeer.pigeonID)
                detailRow(label: "Connection", value: connectionLabel)
                detailRow(label: "Saved Contact", value: resolvedPeer.isSaved ? "Yes" : "No")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PigeonTheme.background)
        .navigationTitle("Contact")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .navigationDestination(item: $activeConversation) { conversation in
            ChatView(conversation: conversation)
        }
        .alert(
            "Security Warning",
            isPresented: warningBinding,
            presenting: pendingWarning
        ) { warning in
            Button("Cancel", role: .cancel) {
                pendingWarning = nil
            }
            Button("Trust New Key", role: .destructive) {
                coordinator.confirmPeerKeyChange(for: warning.peerPublicKey)
                pendingWarning = nil
                startConversation()
            }
        } message: { warning in
            Text(
                "\(warning.displayName) was previously trusted as \(warning.previousPigeonID), but is now advertising \(warning.currentPigeonID). Messaging is paused until you confirm this key change."
            )
        }
        .alert("Rename Contact", isPresented: $showRenamePrompt) {
            TextField("Display Name", text: $draftDisplayName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveDisplayName()
            }
        } message: {
            Text("Leave it blank to reset this contact back to their Pigeon ID.")
        }
    }

    private var resolvedPeer: Peer {
        coordinator.resolvedPeer(for: peer.publicKey) ?? peer
    }

    private var displayName: String {
        resolvedPeer.displayName ?? resolvedPeer.pigeonID
    }

    private var reachability: DirectConversationReachability {
        coordinator.directConversationReachability(for: resolvedPeer.publicKey)
    }

    @ViewBuilder
    private var contactStatusBadge: some View {
        Label(connectionLabel, systemImage: connectionSymbolName)
            .font(PigeonTheme.captionFont)
            .foregroundColor(connectionColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(connectionColor.opacity(0.16), in: Capsule())
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(PigeonTheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(PigeonTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .listRowBackground(PigeonTheme.surface)
    }

    private var connectionLabel: String {
        switch reachability {
        case .inRange:
            return "In Range"
        case .connectedToInternet:
            return coordinator.transportState == .internetBridgedConnected
                ? "Connected to Internet via Nearby Bridge"
                : "Connected to Internet"
        case .outOfRange:
            return "Out of Range"
        }
    }

    private var connectionColor: Color {
        switch reachability {
        case .inRange:
            return PigeonTheme.success
        case .connectedToInternet:
            return PigeonTheme.internet
        case .outOfRange:
            return PigeonTheme.error
        }
    }

    private var connectionSymbolName: String {
        switch reachability {
        case .inRange:
            return "antenna.radiowaves.left.and.right"
        case .connectedToInternet:
            return coordinator.transportState == .internetBridgedConnected
                ? "point.3.connected.trianglepath.dotted"
                : "globe"
        case .outOfRange:
            return "wifi.slash"
        }
    }

    private func startConversation() {
        let resolvedPeer = resolvedPeer
        if let warning = coordinator.peerKeyChangeWarning(for: resolvedPeer) {
            pendingWarning = warning
            return
        }

        do {
            activeConversation = try coordinator.startConversation(with: resolvedPeer)
        } catch {
            activeConversation = nil
        }
    }

    private func startRenaming() {
        draftDisplayName = resolvedPeer.displayName ?? ""
        showRenamePrompt = true
    }

    private func saveDisplayName() {
        try? coordinator.renameContact(
            publicKey: resolvedPeer.publicKey,
            displayName: draftDisplayName
        )
    }

    private var warningBinding: Binding<Bool> {
        Binding(
            get: { pendingWarning != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWarning = nil
                }
            }
        )
    }
}
