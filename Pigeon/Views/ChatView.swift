import CryptoKit
import SwiftUI
import UIKit

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
    @State private var showGroupDetails = false
    @State private var composerResetToken = UUID()
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            connectionStatusBanner
            messagesList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composerArea
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
        }
        .onAppear {
            coordinator.setActiveConversation(conversation.id)
            try? coordinator.clearUnread(conversationID: conversation.id)
        }
        .onDisappear {
            coordinator.setActiveConversation(nil)
            try? coordinator.clearUnread(conversationID: conversation.id)
            isComposerFocused = false
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
                        VStack(spacing: 4) {
                            if selectedReactionMessage?.id == message.id {
                                reactionPickerRow(for: message)
                                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                            }

                            MessageBubbleView(
                                message: message,
                                senderName: senderName(for: message.senderPublicKey),
                                isGroupConversation: conversation.kind == .group,
                                reactionSummaries: reactionSummaries(for: message.id),
                                showsActionMenu: selectedReactionMessage?.id == message.id,
                                onDoubleTap: { quickReact(to: message) },
                                onLongPress: {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                                        selectedReactionMessage = message
                                    }
                                },
                                onCopy: {
                                    UIPasteboard.general.string = message.plaintext
                                    playLightHaptic()
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        selectedReactionMessage = nil
                                    }
                                },
                                onSwipeReply: {
                                    replyTarget = message
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
                                        selectedReactionMessage = nil
                                    }
                                },
                                onTapReplyPreview: {
                                    guard let replyID = message.replyToMessageID else { return }
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(replyID, anchor: .center)
                                    }
                                }
                            )
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .contentShape(Rectangle())
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissComposerKeyboard()
                    if selectedReactionMessage != nil {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedReactionMessage = nil
                        }
                    }
                }
            )
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
            Image(systemName: connectionBannerSymbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(connectionBannerColor)

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
                .id(composerResetToken)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(PigeonTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
                .foregroundColor(PigeonTheme.textPrimary)
                .lineLimit(1 ... 5)
                .focused($isComposerFocused)

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
        .animation(.easeOut(duration: 0.15), value: isComposerFocused)
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var directConversationReachability: DirectConversationReachability {
        coordinator.directConversationReachability(for: conversation.peerPublicKey)
    }

    private var connectionBannerText: String {
        if conversation.kind == .group {
            switch coordinator.transportState {
            case .internetDirectConnected:
                return "Group chat active (direct internet + mesh fallback)."
            case .internetBridgedConnected:
                return "Group chat active (nearby bridge + mesh fallback)."
            default:
                return "Group chat active (mesh-first)."
            }
        }

        switch directConversationReachability {
        case .inRange:
            return "In Range"
        case .connectedToInternet:
            if coordinator.transportState == .internetBridgedConnected {
                return "Connected to Internet via Nearby Bridge"
            }
            return "Connected to Internet"
        case .outOfRange:
            return "Out of Range"
        }
    }

    private var connectionBannerColor: Color {
        if conversation.kind == .group {
            switch coordinator.transportState {
            case .internetDirectConnected, .internetBridgedConnected:
                return PigeonTheme.success
            default:
                return PigeonTheme.textSecondary
            }
        }

        switch directConversationReachability {
        case .inRange:
            return PigeonTheme.success
        case .connectedToInternet:
            return PigeonTheme.internet
        case .outOfRange:
            return PigeonTheme.error
        }
    }

    private var connectionBannerSymbolName: String {
        if conversation.kind == .group {
            switch coordinator.transportState {
            case .internetDirectConnected:
                return "globe"
            case .internetBridgedConnected:
                return "point.3.connected.trianglepath.dotted"
            case .internetDisconnected, .bleOnly:
                return "antenna.radiowaves.left.and.right"
            }
        }

        switch directConversationReachability {
        case .inRange:
            return "antenna.radiowaves.left.and.right"
        case .connectedToInternet:
            return coordinator.transportState == .internetBridgedConnected
                ? "point.3.connected.trianglepath.dotted"
                : "globe"
        case .outOfRange:
            return "wifi.slash"
        }
    }

    private func loadMessagesAndReactions() {
        messages = (try? coordinator.messagesForConversation(conversation.id)) ?? []
        let reactions = (try? coordinator.reactionsForConversation(conversation.id)) ?? []
        reactionsByMessage = Dictionary(grouping: reactions, by: \.messageID)
    }

    private func sendMessage() {
        let originalDraft = draftText
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

        resetComposer(text: "", focus: true)
        isSending = true
        let reply = replyTarget
        replyTarget = nil

        Task {
            do {
                _ = try await coordinator.sendMessage(text: text, in: conversation, replyTo: reply)
                loadMessagesAndReactions()
            } catch {
                resetComposer(text: originalDraft, focus: true)
                replyTarget = reply
                loadMessagesAndReactions()
            }
            isSending = false
        }
    }

    private func resetComposer(text: String, focus: Bool) {
        draftText = text
        composerResetToken = UUID()
        Task { @MainActor in
            isComposerFocused = focus
        }
    }

    private func quickReact(to message: Message) {
        playLightHaptic()
        Task {
            try? await coordinator.sendReaction(.like, to: message, in: conversation)
            loadMessagesAndReactions()
        }
    }

    private func react(with tapback: TapbackType, to message: Message) {
        if shouldTriggerAdditionHaptic(tapback: tapback, for: message) {
            playLightHaptic()
        }

        withAnimation(.easeOut(duration: 0.15)) {
            selectedReactionMessage = nil
        }

        Task {
            try? await coordinator.sendReaction(tapback, to: message, in: conversation)
            loadMessagesAndReactions()
        }
    }

    private func reactionPickerRow(for message: Message) -> some View {
        HStack {
            if !message.isIncoming {
                Spacer(minLength: 60)
            }

            HStack(spacing: 10) {
                ForEach(TapbackType.allCases, id: \.self) { tapback in
                    Button {
                        react(with: tapback, to: message)
                    } label: {
                        Image(systemName: tapback.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(PigeonTheme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(PigeonTheme.surfaceSecondary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(PigeonTheme.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PigeonTheme.divider, lineWidth: 1)
            }

            if message.isIncoming {
                Spacer(minLength: 60)
            }
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

    private func shouldTriggerAdditionHaptic(tapback: TapbackType, for message: Message) -> Bool {
        let myKey = coordinator.identity.publicKey.rawRepresentation
        let existing = reactionsByMessage[message.id]?.first(where: { $0.reactorPublicKey == myKey })
        return existing?.tapback != tapback
    }

    private func playLightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

    private var composerArea: some View {
        VStack(spacing: 0) {
            Divider().overlay(PigeonTheme.divider)
            replyComposerBar
            messageInputBar
        }
        .background(PigeonTheme.surface)
    }

    private func dismissComposerKeyboard() {
        isComposerFocused = false

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .endEditing(true)
    }
}
