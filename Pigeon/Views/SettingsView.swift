import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showResetConfirmation = false
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                List {
                    networkSection
                    dataSection
                    aboutSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var networkSection: some View {
        Section("Network") {
            HStack {
                Text("BLE Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(bleStatusColor)
                        .frame(width: 8, height: 8)
                    Text(bleStatusText)
                        .foregroundColor(PigeonTheme.textSecondary)
                }
            }
            .listRowBackground(PigeonTheme.surface)

            HStack {
                Text("Internet Relay")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(relayStatusColor)
                        .frame(width: 8, height: 8)
                    Text(relayStatusText)
                        .foregroundColor(PigeonTheme.textSecondary)
                }
            }
            .listRowBackground(PigeonTheme.surface)

            Toggle("Internet Bridge", isOn: internetBridgeBinding)
                .tint(PigeonTheme.accent)
                .listRowBackground(PigeonTheme.surface)

            HStack {
                Text("APNS Token")
                Spacer()
                Text(apnsTokenStatusText)
                    .foregroundColor(PigeonTheme.textSecondary)
            }
            .listRowBackground(PigeonTheme.surface)

            HStack {
                Text("Your Pigeon ID")
                Spacer()
                Text(coordinator.identity.pigeonID)
                    .font(PigeonTheme.monoFont)
                    .foregroundColor(PigeonTheme.textSecondary)
            }
            .listRowBackground(PigeonTheme.surface)
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button("Clear All Messages", role: .destructive) {
                showClearConfirmation = true
            }
            .listRowBackground(PigeonTheme.surface)
            .confirmationDialog(
                "Clear all messages?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    try? coordinator.store.deleteAllData()
                    Task { await coordinator.loadConversations() }
                }
            } message: {
                Text("This will delete all conversations and messages. This cannot be undone.")
            }

            Button("Reset Identity", role: .destructive) {
                showResetConfirmation = true
            }
            .listRowBackground(PigeonTheme.surface)
            .confirmationDialog(
                "Reset your identity?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Identity", role: .destructive) {
                    resetIdentity()
                }
            } message: {
                Text("This will generate a new keypair and delete all data. Your contacts will no longer recognize you. This cannot be undone.")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundColor(PigeonTheme.textTertiary)
            }
            .listRowBackground(PigeonTheme.surface)

            HStack {
                Text("Protocol")
                Spacer()
                Text("BLE Mesh v1")
                    .foregroundColor(PigeonTheme.textTertiary)
            }
            .listRowBackground(PigeonTheme.surface)
        }
    }

    private var apnsTokenStatusText: String {
        if coordinator.relayPushTokenRegistered {
            return "Registered"
        }
        if coordinator.relayPushTokenRegistrationError != nil {
            return "Failed"
        }
        return "Waiting"
    }

    private var bleStatusColor: Color {
        switch coordinator.bleState {
        case .running: return PigeonTheme.success
        case .poweredOff, .unauthorized, .unsupported: return PigeonTheme.error
        default: return PigeonTheme.textTertiary
        }
    }

    private var bleStatusText: String {
        switch coordinator.bleState {
        case .idle: return "Idle"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .unauthorized: return "Unauthorized"
        case .unsupported: return "Unsupported"
        case .poweredOff: return "Bluetooth Off"
        }
    }

    private var relayStatusColor: Color {
        switch coordinator.transportState {
        case .internetDirectConnected, .internetBridgedConnected: return PigeonTheme.success
        case .internetDisconnected: return PigeonTheme.error
        case .bleOnly: return PigeonTheme.textTertiary
        }
    }

    private var relayStatusText: String {
        switch coordinator.transportState {
        case .internetDirectConnected: return "Direct"
        case .internetBridgedConnected:
            if let bridge = coordinator.activeBridge {
                return "Via \(bridge.pigeonID)"
            }
            return "Via Nearby Bridge"
        case .internetDisconnected: return "Disconnected"
        case .bleOnly: return "Disabled"
        }
    }

    private var internetBridgeBinding: Binding<Bool> {
        Binding(
            get: { coordinator.internetBridgeEnabled },
            set: { coordinator.setInternetBridgeEnabled($0) }
        )
    }

    private func resetIdentity() {
        try? coordinator.store.deleteAllData()
        try? KeyStore.shared.deleteAll()
        // App will regenerate identity on next launch
        Task { await coordinator.loadConversations() }
    }
}
