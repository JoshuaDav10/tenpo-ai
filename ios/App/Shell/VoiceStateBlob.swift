import SwiftUI
import DesignSystem
import RealtimeKit

/// The session-screen face of Tenpo's character: the same morphing blob from the
/// home screen, its mood driven by the live voice loop. Tapping it interrupts
/// (the one continuous character, home → conversation).
struct VoiceStateBlob: View {
    let state: VoiceLoopState
    var onTap: () -> Void

    var body: some View {
        TenpoBlob(mood: mood, palette: palette, size: 150)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
    }

    private var mood: TenpoBlob.Mood {
        switch state {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .ended: return .idle
        }
    }

    /// Blue-led while listening (your turn), warm while it works/speaks.
    private var palette: [Color] {
        switch state {
        case .listening:
            return TenpoBlob.defaultPalette
        case .thinking, .speaking:
            return [TenpoBlob.defaultPalette[2], TenpoBlob.defaultPalette[1], TenpoBlob.defaultPalette[0]]
        case .ended:
            return [Color.gray, Color.gray.opacity(0.7), Color.gray.opacity(0.5)]
        }
    }
}
