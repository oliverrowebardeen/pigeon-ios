import SwiftUI

struct ConversationRowView: View {
    let conversation: Conversation
    let isPeerNearby: Bool

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
                Circle()
                    .fill(isPeerNearby ? PigeonTheme.success : PigeonTheme.error)
                    .frame(width: 6, height: 6)

                Text(isPeerNearby ? "Nearby" : "Out of range")
                    .font(PigeonTheme.captionFont)
                    .foregroundColor(isPeerNearby ? PigeonTheme.success : PigeonTheme.error)
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
        conversation.peerDisplayName ?? conversation.peerPigeonID
    }

    private var avatarLetter: String {
        String((displayName).prefix(1)).uppercased()
    }
}
