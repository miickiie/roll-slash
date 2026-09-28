import SwiftUI

enum RollSlashTheme {
    // Dark enough to keep white destructive-action labels readable in both
    // light and dark appearances.
    static let coral = Color(red: 0.84, green: 0.12, blue: 0.22)
    static let violet = Color(red: 0.56, green: 0.24, blue: 0.96)
    static let plum = Color(red: 0.12, green: 0.04, blue: 0.16)
    static let keep = Color(red: 0.16, green: 0.75, blue: 0.50)

    static var background: LinearGradient {
        LinearGradient(
            colors: [plum, Color(red: 0.19, green: 0.07, blue: 0.25)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
