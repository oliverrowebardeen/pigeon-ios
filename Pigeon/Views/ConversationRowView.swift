import SwiftUI

struct ConversationRowView: View {
    let conversation: Conversation
    let reachability: DirectConversationReachability?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            content
        }
        .padding(.vertical, 4)
    }

    private var avatar: some View {
        Circle()
            .fill(PigeonTheme.accent.opacity(0.2))
            .frame(width: 48, height: 48)
            .overlay {
                Text(avatarLetter)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(PigeonTheme.accent)
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayName)
                    .font(PigeonTheme.headlineFont)
                    .foregroundColor(PigeonTheme.textPrimary)
                Spacer()
                if let timestamp = conversation.lastMessageTimestamp {
                    Text(timestamp, style: .relative)
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textTertiary)
                }
            }

            HStack(spacing: 6) {
                if conversation.kind == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(PigeonTheme.textSecondary)

                    Text("\(conversation.memberCount) members")
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textSecondary)
                } else {
                    if reachability != nil {
                        Image(systemName: reachabilitySymbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(reachabilityColor)

                        Text(reachabilityLabel)
                            .font(PigeonTheme.captionFont)
                            .foregroundColor(reachabilityColor)
                            .lineLimit(1)
                    }
                }
            }

            HStack {
                Text(conversation.lastMessagePreview ?? "No messages yet")
                    .font(.system(size: 14))
                    .foregroundColor(PigeonTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PigeonTheme.accent, in: Capsule())
                }
            }
        }
    }

    private var displayName: String {
        conversation.displayTitle
    }

    private var avatarLetter: String {
        String((displayName).prefix(1)).uppercased()
    }

    private var reachabilityLabel: String {
        switch reachability ?? .outOfRange {
        case .inRange:
            return "In Range"
        case .meshReachable:
            return "Mesh Reachable"
        case .connectedToInternet:
            return "Connected to Internet"
        case .outOfRange:
            return "Out of Range"
        }
    }

    private var reachabilityColor: Color {
        switch reachability ?? .outOfRange {
        case .inRange:
            return PigeonTheme.success
        case .meshReachable:
            return PigeonTheme.accent
        case .connectedToInternet:
            return PigeonTheme.internet
        case .outOfRange:
            return PigeonTheme.error
        }
    }

    private var reachabilitySymbolName: String {
        switch reachability ?? .outOfRange {
        case .inRange:
            return "antenna.radiowaves.left.and.right"
        case .meshReachable:
            return "point.3.connected.trianglepath.dotted"
        case .connectedToInternet:
            return "globe"
        case .outOfRange:
            return "wifi.slash"
        }
    }
}
