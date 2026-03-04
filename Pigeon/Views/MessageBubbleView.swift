import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    let senderName: String
    let isGroupConversation: Bool
    let reactionSummaries: [ReactionSummary]
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onSwipeReply: () -> Void
    let onTapReplyPreview: () -> Void
    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        HStack {
            if !message.isIncoming { Spacer(minLength: 60) }

            VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 4) {
                if message.isIncoming, isGroupConversation {
                    Text(senderName)
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                bubbleContent
                    .offset(x: swipeOffset)
                    .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.88), value: swipeOffset)
                    .onTapGesture(count: 2, perform: onDoubleTap)
                    .onLongPressGesture(perform: onLongPress)
                    .highPriorityGesture(replyDragGesture)

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textTertiary)

                    if !message.isIncoming {
                        statusIcon
                    }
                }
                .padding(.horizontal, 4)

                if !message.isIncoming, let statusLabel {
                    Text(statusLabel)
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(statusLabelColor)
                        .padding(.horizontal, 4)
                }
            }

            if message.isIncoming { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if let replyPreview = message.replyPreview {
            Button {
                onTapReplyPreview()
            } label: {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(PigeonTheme.accent)
                        .frame(width: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reply")
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(PigeonTheme.textSecondary)
                        Text(replyPreview)
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(PigeonTheme.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(PigeonTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }

        Text(message.plaintext)
            .font(PigeonTheme.bodyFont)
            .foregroundColor(PigeonTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isIncoming ? PigeonTheme.incomingBubble : PigeonTheme.outgoingBubble,
                in: BubbleShape(isIncoming: message.isIncoming)
            )

        if !reactionSummaries.isEmpty {
            HStack(spacing: 6) {
                ForEach(reactionSummaries) { summary in
                    HStack(spacing: 4) {
                        Image(systemName: summary.tapback.symbolName)
                            .font(.system(size: 10))
                        Text("\(summary.count)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(summary.includesCurrentUser ? PigeonTheme.accent : PigeonTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(PigeonTheme.surfaceSecondary, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var replyDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > vertical else {
                    swipeOffset = 0
                    return
                }

                if message.isIncoming {
                    guard horizontal > 0 else {
                        swipeOffset = 0
                        return
                    }
                    swipeOffset = min(horizontal * 0.5, 34)
                } else {
                    guard horizontal < 0 else {
                        swipeOffset = 0
                        return
                    }
                    swipeOffset = max(horizontal * 0.5, -34)
                }
            }
            .onEnded { value in
                let horizontal = message.isIncoming
                    ? max(value.translation.width, value.predictedEndTranslation.width)
                    : min(value.translation.width, value.predictedEndTranslation.width)
                let vertical = abs(value.translation.height)
                let shouldReply: Bool = {
                    if message.isIncoming {
                        return horizontal > 32 && horizontal > (vertical * 1.1)
                    }
                    return horizontal < -32 && abs(horizontal) > (vertical * 1.1)
                }()

                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.9)) {
                    swipeOffset = 0
                }
                if shouldReply {
                    onSwipeReply()
                }
            }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundColor(PigeonTheme.textTertiary)
        case .queued:
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 10))
                .foregroundColor(PigeonTheme.textSecondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundColor(PigeonTheme.textTertiary)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(PigeonTheme.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(PigeonTheme.error)
        }
    }

    private var statusLabel: String? {
        switch message.status {
        case .sending:
            return "Sending..."
        case .queued:
            return "Queued (not sent yet)"
        case .failed:
            return "Failed to send"
        case .sent, .delivered:
            return nil
        }
    }

    private var statusLabelColor: Color {
        switch message.status {
        case .failed:
            return PigeonTheme.error
        case .queued:
            return PigeonTheme.textSecondary
        case .sending:
            return PigeonTheme.textTertiary
        case .sent, .delivered:
            return PigeonTheme.textTertiary
        }
    }
}

struct BubbleShape: Shape {
    let isIncoming: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let smallRadius: CGFloat = 4

        let topLeft = isIncoming ? smallRadius : radius
        let topRight = isIncoming ? radius : radius
        let bottomLeft = isIncoming ? radius : radius
        let bottomRight = isIncoming ? radius : smallRadius

        return Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: topLeft,
                bottomLeading: bottomLeft,
                bottomTrailing: bottomRight,
                topTrailing: topRight
            )
        )
    }
}
