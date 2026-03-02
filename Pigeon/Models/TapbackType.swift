import Foundation

nonisolated enum TapbackType: String, Codable, CaseIterable, Sendable {
    case like
    case dislike
    case laugh
    case emphasize
    case question
    case exclaim

    var symbolName: String {
        switch self {
        case .like: return "hand.thumbsup.fill"
        case .dislike: return "hand.thumbsdown.fill"
        case .laugh: return "face.smiling.fill"
        case .emphasize: return "exclamationmark.bubble.fill"
        case .question: return "questionmark.bubble.fill"
        case .exclaim: return "exclamationmark.circle.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .like: return "Like"
        case .dislike: return "Dislike"
        case .laugh: return "Laugh"
        case .emphasize: return "Emphasize"
        case .question: return "Question"
        case .exclaim: return "Exclaim"
        }
    }
}
