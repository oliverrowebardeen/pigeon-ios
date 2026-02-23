import SwiftUI

struct ConversationListView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            ZStack {
                PigeonTheme.background.ignoresSafeArea()

                if coordinator.conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Messages")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(conversation: conversation)
            }
        }
    }

    private var conversationList: some View {
        List {
            ForEach(coordinator.conversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRowView(conversation: conversation)
                }
                .listRowBackground(PigeonTheme.background)
            }
            .onDelete(perform: deleteConversation)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(PigeonTheme.textTertiary)
            Text("No conversations yet")
                .font(PigeonTheme.headlineFont)
                .foregroundColor(PigeonTheme.textSecondary)
            Text("Tap the Nearby tab to find\nnearby Pigeon users.")
                .font(PigeonTheme.captionFont)
                .foregroundColor(PigeonTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func deleteConversation(at offsets: IndexSet) {
        for index in offsets {
            let conversation = coordinator.conversations[index]
            try? coordinator.deleteConversation(id: conversation.id)
        }
    }
}
