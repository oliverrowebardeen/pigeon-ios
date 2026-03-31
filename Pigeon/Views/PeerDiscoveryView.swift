import SwiftUI

struct PeerDiscoveryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var navigationPath = NavigationPath()
    @State private var pendingWarningPeer: Peer?
    @State private var pendingWarning: PeerKeyChangeWarning?
    @State private var selectedMeshNode: Peer?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                if coordinator.nearbyContacts.isEmpty && coordinator.connectedMeshNodeCount == 0 {
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
            .sheet(item: $selectedMeshNode) { node in
                MeshNodeDetailSheet(node: node)
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

    private var meshNodes: [Peer] {
        coordinator.nearbyPeers.filter(\.isMeshNode)
    }

    private var peerList: some View {
        List {
            if !meshNodes.isEmpty {
                Section {
                    ForEach(meshNodes) { node in
                        MeshNodeRowView(node: node) {
                            selectedMeshNode = node
                        }
                        .listRowBackground(PigeonTheme.surface)
                    }
                } header: {
                    HStack {
                        Text("Mesh Nodes")
                        Spacer()
                        Text("\(meshNodes.count)")
                            .foregroundColor(PigeonTheme.accent)
                    }
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

// MARK: - Mesh Node Row

struct MeshNodeRowView: View {
    let node: Peer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(PigeonTheme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundColor(PigeonTheme.accent)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName ?? "Mesh Node")
                        .font(PigeonTheme.headlineFont)
                        .foregroundColor(PigeonTheme.textPrimary)

                    HStack(spacing: 6) {
                        Text(node.pigeonID)
                            .font(PigeonTheme.monoFont)
                            .foregroundColor(PigeonTheme.textTertiary)

                        bridgeIndicator
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(PigeonTheme.textTertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bridgeIndicator: some View {
        if node.relayReachable {
            HStack(spacing: 2) {
                Image(systemName: "globe")
                Text("Bridge")
            }
            .font(PigeonTheme.captionFont)
            .foregroundColor(.green)
        } else if let state = node.bridgeState, MeshNodeDetailSheet.wifiErrorStates.contains(state) {
            HStack(spacing: 2) {
                Image(systemName: "wifi.exclamationmark")
                Text("Error")
            }
            .font(PigeonTheme.captionFont)
            .foregroundColor(.red)
        } else if node.bridgeState == "offline" {
            HStack(spacing: 2) {
                Image(systemName: "wifi")
                Text("WiFi")
            }
            .font(PigeonTheme.captionFont)
            .foregroundColor(.yellow)
        } else if node.bridgeEnabled {
            HStack(spacing: 2) {
                Image(systemName: "wifi")
                Text("Bridge")
            }
            .font(PigeonTheme.captionFont)
            .foregroundColor(.orange)
        }
    }
}

// MARK: - Mesh Node Detail Sheet

struct MeshNodeDetailSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let node: Peer

    @State private var ssid = ""
    @State private var password = ""
    @State private var showingWiFiForm = false
    @State private var showingDisconnectConfirm = false

    private var liveNode: Peer {
        coordinator.nearbyPeers.first(where: { $0.publicKey == node.publicKey }) ?? node
    }

    var body: some View {
        NavigationStack {
            List {
                nodeInfoSection
                bridgeStatusSection
                wifiActionSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background {
                PigeonTheme.background.ignoresSafeArea(.all)
            }
            .navigationTitle(liveNode.displayName ?? "Mesh Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Configure WiFi", isPresented: $showingWiFiForm) {
                TextField("Network name (SSID)", text: $ssid)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Cancel", role: .cancel) {
                    ssid = ""
                    password = ""
                }
                Button("Connect") {
                    guard !ssid.isEmpty else { return }
                    coordinator.sendWiFiCredentials(ssid: ssid, password: password, toMeshNode: liveNode)
                    ssid = ""
                    password = ""
                }
            } message: {
                Text("Enter WiFi credentials for this mesh node. Credentials are sent over BLE and stored on the node.")
            }
            .alert("Disconnect WiFi", isPresented: $showingDisconnectConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    coordinator.clearWiFiCredentials(forMeshNode: liveNode)
                }
            } message: {
                Text("This will disconnect the mesh node from WiFi and clear its stored credentials.")
            }
        }
    }

    private var nodeInfoSection: some View {
        Section("Node Info") {
            LabeledContent("Pigeon ID") {
                Text(liveNode.pigeonID)
                    .font(PigeonTheme.monoFont)
            }
            if let rssi = liveNode.rssi {
                LabeledContent("Signal") {
                    Text("\(rssi) dBm")
                        .font(PigeonTheme.monoFont)
                }
            }
        }
        .listRowBackground(PigeonTheme.surface)
    }

    private var bridgeStatusSection: some View {
        Section("WiFi Bridge") {
            HStack {
                Label {
                    Text("Status")
                } icon: {
                    Image(systemName: bridgeStatusIcon)
                        .foregroundColor(bridgeStatusColor)
                }

                Spacer()

                Text(bridgeStatusText)
                    .foregroundColor(bridgeStatusColor)
            }
        }
        .listRowBackground(PigeonTheme.surface)
    }

    private var wifiActionSection: some View {
        Section {
            Button {
                showingWiFiForm = true
            } label: {
                Label("Configure WiFi", systemImage: "wifi")
            }

            if liveNode.bridgeEnabled {
                Button(role: .destructive) {
                    showingDisconnectConfirm = true
                } label: {
                    Label("Disconnect WiFi", systemImage: "wifi.slash")
                }
            }
        }
        .listRowBackground(PigeonTheme.surface)
    }

    static let wifiErrorStates: Set<String> = [
        "ssid_not_found", "wrong_password", "auth_expired",
        "assoc_rejected", "conn_failed", "beacon_timeout"
    ]

    private var bridgeStatusIcon: String {
        if let state = liveNode.bridgeState, Self.wifiErrorStates.contains(state) {
            return "wifi.exclamationmark"
        }
        if liveNode.relayReachable { return "globe" }
        if liveNode.bridgeState == "offline" { return "wifi.exclamationmark" }
        if liveNode.bridgeEnabled { return "wifi" }
        return "wifi.slash"
    }

    private var bridgeStatusColor: Color {
        if let state = liveNode.bridgeState, Self.wifiErrorStates.contains(state) {
            return .red
        }
        if liveNode.relayReachable { return .green }
        if liveNode.bridgeState == "offline" { return .yellow }
        if liveNode.bridgeEnabled { return .orange }
        return PigeonTheme.textTertiary
    }

    private var bridgeStatusText: String {
        switch liveNode.bridgeState {
        case "online": return "Online"
        case "connecting": return "Connecting to WiFi..."
        case "wifi_connected": return "WiFi Connected"
        case "auth": return "Authenticating..."
        case "offline": return "WiFi Connected"
        case "no_wifi": return "Not Configured"
        case "ssid_not_found": return "Network Not Found"
        case "wrong_password": return "Wrong Password"
        case "auth_expired": return "Auth Expired"
        case "assoc_rejected": return "Connection Rejected"
        case "conn_failed": return "Connection Failed"
        case "beacon_timeout": return "Network Timeout"
        default:
            // No bridge_status received yet — fall back to identity flags
            if liveNode.relayReachable { return "Online" }
            if liveNode.bridgeEnabled { return "Configured" }
            return "Not Configured"
        }
    }
}
