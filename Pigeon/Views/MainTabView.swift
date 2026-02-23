import SwiftUI

struct MainTabView: View {
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
    }
}
