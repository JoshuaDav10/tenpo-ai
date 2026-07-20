import SwiftUI

/// Tenpo's character: a soft morphing blob that is both the brand mark and the
/// voice-state indicator — the thing you meet on the home screen is the thing
/// that listens to you in session (one continuous personality, Pingo-style).
///
/// Drawn as a closed smooth curve whose control-point radii breathe on layered
/// sine waves; each mood changes amplitude, tempo, and palette rather than
/// swapping shapes, so transitions feel like the same creature changing state.
public struct TenpoBlob: View {
    public enum Mood: Equatable {
        case idle          // home screen: slow, confident breathing
        case listening     // receptive: gentle open wobble
        case thinking      // compact, quick simmer
        case speaking      // energetic ripple
        case celebrating   // wrap/debrief: big happy pulse
    }

    public var mood: Mood
    public var palette: [Color]
    public var size: CGFloat

    public init(mood: Mood = .idle,
                palette: [Color] = TenpoBlob.defaultPalette,
                size: CGFloat = 160) {
        self.mood = mood
        self.palette = palette
        self.size = size
    }

    public static let defaultPalette: [Color] = TenpoTheme.blobPalette

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Soft halo that swells with the mood.
                BlobShape(time: t * tempo * 0.6, amplitude: amplitude * 1.25, points: 7, phase: 2.1)
                    .fill(palette[0].opacity(0.14))
                    .frame(width: size * 1.32, height: size * 1.32)
                // Two offset color layers make the edge shimmer between hues; the
                // accent rotates slowly so color movement reads even at idle.
                BlobShape(time: t * tempo * 0.8, amplitude: amplitude * 1.5, points: 7, phase: 4.2)
                    .fill(AngularGradient(colors: [palette[1], palette[2], palette[1]], center: .center))
                    .frame(width: size * 1.1, height: size * 1.1)
                    .rotationEffect(.radians(t * tempo * 0.22))
                    .opacity(0.9)
                BlobShape(time: t * tempo, amplitude: amplitude, points: 7, phase: 0)
                    .fill(LinearGradient(colors: [palette[0], palette[0].opacity(0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .animation(.spring(duration: 0.6), value: mood)
    }

    private var amplitude: CGFloat {
        switch mood {
        case .idle: return 0.085
        case .listening: return 0.11
        case .thinking: return 0.06
        case .speaking: return 0.16
        case .celebrating: return 0.19
        }
    }

    private var tempo: Double {
        switch mood {
        case .idle: return 0.5
        case .listening: return 0.9
        case .thinking: return 1.8
        case .speaking: return 2.6
        case .celebrating: return 1.4
        }
    }
}

/// Closed smooth blob: N points around a circle, radius modulated by two
/// incommensurate sine waves so the motion never visibly loops.
struct BlobShape: Shape {
    var time: Double
    var amplitude: CGFloat
    var points: Int
    var phase: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2

        let radii: [CGFloat] = (0..<points).map { i in
            let angle = Double(i) / Double(points) * 2 * .pi
            let wobble = sin(time + angle * 3 + phase) * 0.6
                + sin(time * 1.7 + angle * 2 - phase) * 0.4
            return base * (1 - amplitude + CGFloat(wobble) * amplitude)
        }
        let pts: [CGPoint] = (0..<points).map { i in
            let angle = Double(i) / Double(points) * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + radii[i] * cos(angle),
                           y: center.y + radii[i] * sin(angle))
        }

        // Catmull-Rom through the points → cubic Bézier, closed.
        var path = Path()
        guard pts.count > 2 else { return path }
        path.move(to: midpoint(pts[points - 1], pts[0]))
        for i in 0..<points {
            let current = pts[i]
            let next = pts[(i + 1) % points]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
