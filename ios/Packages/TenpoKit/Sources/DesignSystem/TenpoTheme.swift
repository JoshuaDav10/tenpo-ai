import SwiftUI

/// Tenpo's shared palette — one source of truth so the shell, session screens,
/// and character all read as the same product (the cohesion Pingo has that our
/// stock-SwiftUI screens lacked).
public enum TenpoTheme {
    /// Warm paper background — the calm canvas everything sits on.
    public static let canvas = Color(red: 0.98, green: 0.97, blue: 0.95)
    /// Card surface.
    public static let surface = Color.white

    public static let blue = Color(red: 0.28, green: 0.45, blue: 1.0)
    public static let pink = Color(red: 0.98, green: 0.42, blue: 0.55)
    public static let yellow = Color(red: 1.0, green: 0.78, blue: 0.25)

    /// The character's three-hue set (blue-led).
    public static let blobPalette: [Color] = [blue, pink, yellow]
}

public extension View {
    /// Fill the screen with the warm canvas.
    func tenpoCanvas() -> some View {
        background(TenpoTheme.canvas.ignoresSafeArea())
    }
}
