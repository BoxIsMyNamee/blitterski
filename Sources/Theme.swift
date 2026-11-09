import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

/// App accent color, persisted.
@MainActor
final class Theme: ObservableObject {
    static let palette: [(name: String, hex: String)] = [
        ("Twitter blue", "1DA1F2"), ("Sky", "1083FE"), ("Indigo", "5856D6"), ("Purple", "AF52DE"),
        ("Pink", "FF2D92"), ("Red", "FF3B30"), ("Orange", "FF9500"), ("Yellow", "FFCC00"),
        ("Green", "34C759"), ("Teal", "30B0C7"), ("Gray", "8E8E93"),
    ]

    @Published var hex: String {
        didSet { UserDefaults.standard.set(hex, forKey: "accent.hex") }
    }

    var accent: Color { Color(hex: hex) }

    init() {
        hex = UserDefaults.standard.string(forKey: "accent.hex") ?? "1DA1F2"
    }
}
