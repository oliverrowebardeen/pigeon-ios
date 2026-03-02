import CryptoKit
import SwiftUI

struct ChatView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let conversation: Conversation

    @State private var messages: [Message] = []
    @State private var reactionsByMessage: [UUID: [MessageReaction]] = [:]
    @State private var draftText = ""
    @State private var isSending = false
    @State private var pendingWarning: PeerKeyChangeWarning?
    @State private var replyTarget: Message?
    @State private var selectedReactionMessage: Message?
    @State private var showReactionPicker = false
    @State private var showGroupDetails = false

    var body: some View {
        VStack(spacing: 0) {
            connectionStatusBanner
            messagesList
            Divider().overlay(PigeonTheme.divider)
            replyComposerBar
            messageInputBar
        }
        .background(PigeonTheme.background)
        .navigationTitle(conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if conversation.kind == .group {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showGroupDetails = true
                    } label: {
                        Image(systemName: "person.3")
                    }
                }
            }
        }
        .task {
            loadMessagesAndReactions()
            try? coordinator.clearUnread(conversationID: conversation.id)
        }
        .onChange(of: coordinator.messageChangeToken) {
            loadMessagesAndReactions()
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
                sendMessage()
            }
        } message: { warning in
            Text(
                "\(warning.displayName) was previously trusted as \(warning.previousPigeonID), but is now advertising \(warning.currentPigeonID). Sending is paused until you confirm this key change."
            )
        }
        .confirmationDialog(
            "React",
            isPresented: $showReactionPicker,
            titleVisibility: .visible
        ) {
            ForEach(TapbackType.allCases, id: \.self) { tapback in
                Button(tapback.shortLabel) {
                    react(with: tapback)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showGroupDetails) {
            if let groupID = conversation.groupID {
                GroupDetailsView(groupID: groupID)
                    .environment(coordinator)
            }
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubbleView(
                            message: message,
                            senderName: senderName(for: message.senderPublicKey),
                            isGroupConversation: conversation.kind == .group,
                            reactionSummaries: reactionSummaries(for: message.id),
                            onDoubleTap: { quickReact(to: message) },
                            onLongPress: {
                                selectedReactionMessage = message
                                showReactionPicker = true
                            },
                            onSwipeReply: { replyTarget = message },
                            onTapReplyPreview: {
                                guard let replyID = message.replyToMessageID else { return }
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(replyID, anchor: .center)
                                }
                            }
                        )
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
                .fill(connectionBannerColor)
                .frame(width: 8, height: 8)

            Text(connectionBannerText)
                .font(PigeonTheme.captionFont)
                .foregroundColor(connectionBannerColor)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PigeonTheme.surface)
    }

    @ViewBuilder
    private var replyComposerBar: some View {
        if let replyTarget {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replying to \(senderName(for: replyTarget.senderPublicKey))")
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textSecondary)
                    Text(replyTarget.plaintext)
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    self.replyTarget = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(PigeonTheme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PigeonTheme.surfaceSecondary)
        }
    }

    private var messageInputBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(PigeonTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
                .foregroundColor(PigeonTheme.textPrimary)
                .lineLimit(1 ... 5)

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
        guard let peerKey = conversation.peerPublicKey else {
            return false
        }
        return coordinator.isPeerNearby(publicKey: peerKey)
    }

    private var connectionBannerText: String {
        if conversation.kind == .group {
            if coordinator.transportState == .internetConnected {
                return "Group chat active (internet + mesh fallback)."
            }
            return "Group chat active (mesh-first)."
        }

        if coordinator.transportState == .internetConnected {
            return "Internet relay active. Mesh fallback enabled."
        }

        return isPeerNearby
            ? "Peer nearby"
            : "Peer out of range. Messages will queue until detected."
    }

    private var connectionBannerColor: Color {
        if conversation.kind == .group {
            return coordinator.transportState == .internetConnected ? PigeonTheme.success : PigeonTheme.textSecondary
        }

        if coordinator.transportState == .internetConnected {
            return PigeonTheme.success
        }
        return isPeerNearby ? PigeonTheme.success : PigeonTheme.error
    }

    private func loadMessagesAndReactions() {
        messages = (try? coordinator.messagesForConversation(conversation.id)) ?? []
        let reactions = (try? coordinator.reactionsForConversation(conversation.id)) ?? []
        reactionsByMessage = Dictionary(grouping: reactions, by: \.messageID)
    }

    private func sendMessage() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard pendingWarning == nil else { return }

        if conversation.kind == .direct,
           let peerPublicKey = conversation.peerPublicKey,
           let warning = coordinator.peerKeyChangeWarning(for: peerPublicKey)
        {
            pendingWarning = warning
            return
        }

        draftText = ""
        isSending = true
        let reply = replyTarget
        replyTarget = nil

        Task {
            do {
                _ = try await coordinator.sendMessage(text: text, in: conversation, replyTo: reply)
                loadMessagesAndReactions()
            } catch {
                replyTarget = reply
                loadMessagesAndReactions()
            }
            isSending = false
        }
    }

    private func quickReact(to message: Message) {
        Task {
            try? await coordinator.sendReaction(.like, to: message, in: conversation)
            loadMessagesAndReactions()
        }
    }

    private func react(with tapback: TapbackType) {
        guard let message = selectedReactionMessage else { return }
        selectedReactionMessage = nil

        Task {
            try? await coordinator.sendReaction(tapback, to: message, in: conversation)
            loadMessagesAndReactions()
        }
    }

    private func senderName(for publicKey: Data) -> String {
        coordinator.displayName(for: publicKey)
    }

    private func reactionSummaries(for messageID: UUID) -> [ReactionSummary] {
        let reactions = reactionsByMessage[messageID] ?? []
        let myKey = coordinator.identity.publicKey.rawRepresentation
        let grouped = Dictionary(grouping: reactions, by: \.tapback)

        return TapbackType.allCases.compactMap { tapback in
            guard let entries = grouped[tapback], !entries.isEmpty else {
                return nil
            }
            return ReactionSummary(
                tapback: tapback,
                count: entries.count,
                includesCurrentUser: entries.contains(where: { $0.reactorPublicKey == myKey })
            )
        }
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
