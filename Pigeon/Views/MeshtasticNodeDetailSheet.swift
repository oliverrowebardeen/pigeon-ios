import SwiftUI

// MARK: - Meshtastic Node Row (for PeerDiscoveryView)

struct MeshtasticNodeRowView: View {
    let node: MeshtasticNode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.purple)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.longName ?? "Meshtastic Node")
                        .font(PigeonTheme.headlineFont)
                        .foregroundColor(PigeonTheme.textPrimary)

                    HStack(spacing: 6) {
                        if let shortName = node.shortName {
                            Text(shortName)
                                .font(PigeonTheme.monoFont)
                                .foregroundColor(PigeonTheme.textTertiary)
                        }

                        Text("#\(node.id)")
                            .font(PigeonTheme.monoFont)
                            .foregroundColor(PigeonTheme.textTertiary)

                        if node.isConnected {
                            Text("Connected")
                                .font(PigeonTheme.captionFont)
                                .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                if let rssi = node.rssi {
                    signalIndicator(rssi: rssi)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(PigeonTheme.textTertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func signalIndicator(rssi: Int) -> some View {
        let bars: Int = switch rssi {
        case -60 ... 0: 3
        case -80 ... -61: 2
        case -100 ... -81: 1
        default: 0
        }

        return HStack(spacing: 1) {
            ForEach(0 ..< 3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? PigeonTheme.accent : PigeonTheme.textTertiary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
}

// MARK: - Meshtastic Node Detail Sheet

struct MeshtasticNodeDetailSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let node: MeshtasticNode

    private var liveNode: MeshtasticNode {
        coordinator.meshtasticNodes.first(where: { $0.id == node.id }) ?? node
    }

    var body: some View {
        NavigationStack {
            List {
                nodeInfoSection
                connectionSection
                infoSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background {
                PigeonTheme.background.ignoresSafeArea(.all)
            }
            .navigationTitle(liveNode.longName ?? "Meshtastic Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var nodeInfoSection: some View {
        Section("Node Info") {
            LabeledContent("Node Number") {
                Text("#\(liveNode.id)")
                    .font(PigeonTheme.monoFont)
            }
            if let longName = liveNode.longName {
                LabeledContent("Name") {
                    Text(longName)
                }
            }
            if let shortName = liveNode.shortName {
                LabeledContent("Short Name") {
                    Text(shortName)
                        .font(PigeonTheme.monoFont)
                }
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

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Label {
                    Text("Status")
                } icon: {
                    Image(systemName: liveNode.isConnected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(liveNode.isConnected ? .green : PigeonTheme.textTertiary)
                }

                Spacer()

                Text(liveNode.isConnected ? "Connected" : "Not Connected")
                    .foregroundColor(liveNode.isConnected ? .green : PigeonTheme.textTertiary)
            }

            if liveNode.isConnected {
                Button(role: .destructive) {
                    coordinator.meshtasticBLEManager.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    coordinator.meshtasticBLEManager.connect(to: liveNode)
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
        .listRowBackground(PigeonTheme.surface)
    }

    private var infoSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(PigeonTheme.textTertiary)
                Text("Stock Meshtastic node — connect a Pigeon node for full features.")
                    .font(PigeonTheme.captionFont)
                    .foregroundColor(PigeonTheme.textSecondary)
            }
        }
        .listRowBackground(PigeonTheme.surface)
    }
}
