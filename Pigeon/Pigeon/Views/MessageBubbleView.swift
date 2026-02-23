import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack {
            if !message.isIncoming { Spacer(minLength: 60) }

            VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 2) {
                Text(message.plaintext)
                    .font(PigeonTheme.bodyFont)
                    .foregroundColor(PigeonTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.isIncoming ? PigeonTheme.incomingBubble : PigeonTheme.outgoingBubble,
                        in: BubbleShape(isIncoming: message.isIncoming)
                    )

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.textTertiary)

                    if !message.isIncoming {
                        statusIcon
                    }
                }
                .padding(.horizontal, 4)

                if !message.isIncoming, message.status == .failed {
                    Text("Failed to send")
                        .font(PigeonTheme.captionFont)
                        .foregroundColor(PigeonTheme.error)
                        .padding(.horizontal, 4)
                }
            }

            if message.isIncoming { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundColor(PigeonTheme.textTertiary)
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
