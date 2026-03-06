import SwiftUI

enum PigeonTheme {
    // MARK: - Colors

    static let background = Color(hex: 0x0A0A0A)
    static let surface = Color(hex: 0x1A1A1A)
    static let surfaceSecondary = Color(hex: 0x2A2A2A)
    static let accent = Color(hex: 0x8B5CF6)
    static let accentLight = Color(hex: 0xA78BFA)
    static let accentDark = Color(hex: 0x7C3AED)
    static let textPrimary = Color(hex: 0xF5F5F5)
    static let textSecondary = Color(hex: 0x8A8A8A)
    static let textTertiary = Color(hex: 0x6B7280)
    static let success = Color(hex: 0x4CAF50)
    static let internet = Color(hex: 0x38BDF8)
    static let error = Color(hex: 0xEF5350)
    static let divider = Color(hex: 0x1F1F1F)

    // MARK: - Bubble Colors

    static let outgoingBubble = accentDark
    static let incomingBubble = surfaceSecondary

    // MARK: - Typography

    static let titleFont: Font = .system(size: 20, weight: .semibold)
    static let headlineFont: Font = .system(size: 17, weight: .semibold)
    static let bodyFont: Font = .system(size: 16, weight: .regular)
    static let captionFont: Font = .system(size: 12, weight: .regular)
    static let monoFont: Font = .system(size: 14, weight: .medium, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
