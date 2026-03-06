import SwiftUI

struct MainTabView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedTab: Tab = .conversations

    enum Tab: Hashable {
        case conversations
        case nearby
        case identity
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SwiftUI.Tab("Messages", systemImage: "bubble.left.and.bubble.right.fill", value: Tab.conversations) {
                ConversationListView()
            }

            SwiftUI.Tab("Nearby", systemImage: "antenna.radiowaves.left.and.right", value: Tab.nearby) {
                PeerDiscoveryView()
            }

            SwiftUI.Tab("Identity", systemImage: "person.crop.circle", value: Tab.identity) {
                IdentityView()
            }

            SwiftUI.Tab("Settings", systemImage: "gearshape", value: Tab.settings) {
                SettingsView()
            }
        }
        .tint(PigeonTheme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: coordinator.presentedContactProfile?.id) {
            if coordinator.presentedContactProfile != nil {
                selectedTab = .conversations
            }
        }
        .sheet(item: presentedContactProfileBinding, onDismiss: {
            coordinator.dismissPresentedContactProfile()
        }) { peer in
            NavigationStack {
                ContactProfileView(peer: peer, showsDismissButton: true)
                    .environment(coordinator)
            }
        }
    }

    private var presentedContactProfileBinding: Binding<Peer?> {
        Binding(
            get: { coordinator.presentedContactProfile },
            set: { peer in
                if let peer {
                    coordinator.presentContactProfile(peer)
                } else {
                    coordinator.dismissPresentedContactProfile()
                }
            }
        )
    }
}
