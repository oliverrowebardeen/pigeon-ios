import SwiftUI

struct ConversationListView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showNewGroupSheet = false
    @State private var showInviteScanner = false
    @State private var inviteResultMessage: String?

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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showInviteScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewGroupSheet = true
                    } label: {
                        Image(systemName: "person.3.sequence.fill")
                    }
                }
            }
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(conversation: conversation)
            }
            .sheet(isPresented: $showNewGroupSheet) {
                NewGroupView()
                    .environment(coordinator)
            }
            .sheet(isPresented: $showInviteScanner) {
                NavigationStack {
                    QRCodeScannerView { code in
                        handleScannedCode(code)
                        showInviteScanner = false
                    }
                    .ignoresSafeArea()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") {
                                showInviteScanner = false
                            }
                        }
                    }
                    .toolbarColorScheme(.dark, for: .navigationBar)
                }
            }
            .alert("Scan Result", isPresented: inviteAlertBinding) {
                Button("OK", role: .cancel) {
                    inviteResultMessage = nil
                }
            } message: {
                Text(inviteResultMessage ?? "")
            }
        }
    }

    private var conversationList: some View {
        List {
            ForEach(coordinator.conversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRowView(
                        conversation: conversation,
                        isPeerNearby: conversation.peerPublicKey.map { coordinator.isPeerNearby(publicKey: $0) } ?? false
                    )
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
            Text("Tap Nearby to start direct chats\nor use the top-right button for groups.")
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

    private func handleScannedCode(_ code: String) {
        if coordinator.consumeProfileShareString(code) {
            inviteResultMessage = "Profile added to your conversations."
            return
        }

        if let url = URL(string: code), coordinator.consumeGroupInviteURL(url) {
            inviteResultMessage = "Invite accepted. Group added to messages."
            return
        }

        if (try? coordinator.consumeGroupInviteTokenString(code)) != nil {
            inviteResultMessage = "Invite accepted. Group added to messages."
            return
        }

        if coordinator.consumeLegacyProfilePublicKeyHex(code) {
            inviteResultMessage = "Profile added to your conversations."
            return
        }

        inviteResultMessage = "QR code is invalid or expired."
    }

    private var inviteAlertBinding: Binding<Bool> {
        Binding(
            get: { inviteResultMessage != nil },
            set: { isPresented in
                if !isPresented {
                    inviteResultMessage = nil
                }
            }
        )
    }
}
