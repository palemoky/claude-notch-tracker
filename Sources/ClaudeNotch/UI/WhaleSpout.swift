import SwiftUI

/// DeepSeek's whale spouts when the balance is seen to drop — money leaving the account. Like
/// Clawd's walk it means something: a quiet whale is one nobody is spending on. The mark itself
/// stays DeepSeek's own; the water is drawn above it, out of the gap between fin and tail.
struct WhaleSpout: View {
    let start: Date
    /// Side of the square the mark is drawn in; the spout is laid out against it.
    let iconSize: CGFloat

    static let duration: TimeInterval = 1.6
    /// Room above the mark for the water to rise into.
    static let headroom: CGFloat = 10
    /// The blowhole, as a fraction of the mark: just behind the head, between fin and tail.
    private static let blowhole = CGPoint(x: 0.60, y: 0.30)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSince(start) / Self.duration
            Canvas { context, size in
                guard t >= 0, t < 1 else { return }
                let base = CGPoint(x: (size.width - iconSize) / 2 + iconSize * Self.blowhole.x,
                                   y: Self.headroom + iconSize * Self.blowhole.y)
                Self.draw(in: &context, base: base, t: t, height: Self.headroom + iconSize * 0.18)
            }
        }
        .frame(width: iconSize + 8, height: iconSize + Self.headroom)
        .allowsHitTesting(false)
    }

    /// The cartoon spout, in three overlapping beats over `t` 0…1: a column rises from the
    /// blowhole, opens into a crown of two arcs, and sheds droplets outward as it fades.
    private static func draw(in context: inout GraphicsContext, base: CGPoint, t: Double,
                             height: CGFloat) {
        let water = Color(red: 0.66, green: 0.76, blue: 1.0)
        let fade = t < 0.7 ? 1 : 1 - (t - 0.7) / 0.3
        let ease = { (x: Double) in 1 - pow(1 - min(max(x, 0), 1), 3) }

        // Column: grows over the first third, then drains from the bottom up.
        let grow = ease(t / 0.32)
        let drain = ease((t - 0.45) / 0.4)
        let top = base.y - height * grow
        let bottom = base.y - height * 0.9 * drain
        if bottom > top + 0.5 {
            var column = Path()
            column.move(to: CGPoint(x: base.x - 0.55, y: bottom))
            column.addLine(to: CGPoint(x: base.x - 0.95, y: top))
            column.addLine(to: CGPoint(x: base.x + 0.95, y: top))
            column.addLine(to: CGPoint(x: base.x + 0.55, y: bottom))
            column.closeSubpath()
            context.fill(column, with: .color(water.opacity(fade)))
        }

        // Crown: two arcs curling out and down from the top of the column.
        let open = ease((t - 0.22) / 0.35)
        if open > 0 {
            let crownTop = base.y - height
            for side in [-1.0, 1.0] {
                let reach = 3.6 * open
                var arc = Path()
                arc.move(to: CGPoint(x: base.x, y: crownTop))
                arc.addQuadCurve(to: CGPoint(x: base.x + side * reach, y: crownTop + 1.8 * open),
                                 control: CGPoint(x: base.x + side * reach * 0.6, y: crownTop - 2.2 * open))
                context.stroke(arc, with: .color(water.opacity(fade)),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
        }

        // Droplets: shed from the crown's tips, falling outward.
        let shed = (t - 0.45) / 0.55
        if shed > 0 {
            for (side, lean) in [(-1.0, 1.0), (1.0, 1.0), (-1.0, 0.55), (1.0, 0.55)] {
                let x = base.x + side * (3.6 + 2.2 * lean * shed)
                let y = base.y - height + 1.8 + 6 * shed * shed * lean
                let r = 0.7 * lean + 0.25
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(water.opacity(fade)))
            }
        }
    }
}

/// Plays `WhaleSpout` once each time `observedAt` is new and recent — and when the mark comes on
/// screen shortly after a spend, so rotating back to DeepSeek still shows that money just went.
struct WhaleSpoutTrigger: ViewModifier {
    let observedAt: Date?
    let active: Bool
    let iconSize: CGFloat
    @State private var startedAt: Date?

    /// A drop older than this is history, not news; it covers one missed 60 s poll.
    private static let fresh: TimeInterval = 90

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let startedAt {
                    WhaleSpout(start: startedAt, iconSize: iconSize)
                }
            }
            .onAppear { spoutIfFresh() }
            .onChange(of: observedAt) { _, _ in spoutIfFresh() }
    }

    private func spoutIfFresh() {
        guard active, let observedAt, Date().timeIntervalSince(observedAt) < Self.fresh else { return }
        let start = Date()
        startedAt = start
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(WhaleSpout.duration))
            if startedAt == start { startedAt = nil }
        }
    }
}
