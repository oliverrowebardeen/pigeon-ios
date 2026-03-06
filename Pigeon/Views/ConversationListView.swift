import SwiftUI

struct ConversationListView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showNewGroupSheet = false
    @State private var showContactsSheet = false
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showContactsSheet = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }

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
            .sheet(isPresented: $showContactsSheet) {
                ContactsView()
                    .environment(coordinator)
            }
            .sheet(isPresented: $showInviteScanner) {
                NavigationStack {
                    QRCodeScannerView { code in
                        showInviteScanner = false
                        Task { @MainActor in
                            handleScannedCode(code)
                        }
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
                        reachability: conversation.kind == .direct
                            ? coordinator.directConversationReachability(for: conversation.peerPublicKey)
                            : nil
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
            Text("Tap Nearby to start direct chats, scan a profile, or open Contacts from the top-right.")
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
