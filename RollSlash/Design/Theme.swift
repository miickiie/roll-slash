import SwiftUI

enum RollSlashTheme {
    static let coral = Color(red: 0.98, green: 0.31, blue: 0.38)
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

