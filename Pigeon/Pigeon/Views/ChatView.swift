import CryptoKit
import SwiftUI

struct ChatView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let conversation: Conversation

    @State private var messages: [Message] = []
    @State private var draftText = ""
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            connectionStatusBanner
            messagesList
            Divider().overlay(PigeonTheme.divider)
            messageInputBar
        }
        .background(PigeonTheme.background)
        .navigationTitle(conversation.peerDisplayName ?? conversation.peerPigeonID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            loadMessages()
            try? coordinator.clearUnread(conversationID: conversation.id)
        }
        .onChange(of: coordinator.messageChangeToken) {
            loadMessages()
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .onChange(of: messages.count) {
                if let lastID = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var connectionStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isPeerNearby ? PigeonTheme.success : PigeonTheme.error)
                .frame(width: 8, height: 8)

            Text(isPeerNearby ? "Peer nearby" : "Peer out of range. Messages will queue until detected.")
                .font(PigeonTheme.captionFont)
                .foregroundColor(isPeerNearby ? PigeonTheme.success : PigeonTheme.error)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PigeonTheme.surface)
    }

    private var messageInputBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(PigeonTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
                .foregroundColor(PigeonTheme.textPrimary)
                .lineLimit(1...5)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSend ? PigeonTheme.accent : PigeonTheme.textTertiary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PigeonTheme.surface)
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var isPeerNearby: Bool {
        coordinator.isPeerNearby(publicKey: conversation.peerPublicKey)
    }

    private func loadMessages() {
        messages = (try? coordinator.messagesForConversation(conversation.id)) ?? []
    }

    private func sendMessage() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draftText = ""
        isSending = true

        Task {
            do {
                _ = try await coordinator.sendMessage(text: text, in: conversation)
                loadMessages()
            } catch {
                loadMessages()
            }
            isSending = false
        }
    }
}
