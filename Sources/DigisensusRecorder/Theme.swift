import AppKit
import SwiftUI

/// The app's colours: the warm neutrals of the design, with dark-mode twins.
enum Palette {
    static let canvas = dynamic(0xFBFAF8, 0x1F1E1C)
    static let card = dynamic(0xFFFFFF, 0x2C2B28)
    static let border = dynamic(0xE3E0DA, 0x3D3B37)
    /// Behind chips, icons and code.
    static let fill = dynamic(0xF2F0EC, 0x363430)
    /// Progress and meter tracks.
    static let track = dynamic(0xECE9E3, 0x3A3835)
    static let ink = dynamic(0x1D1B18, 0xEDEAE4)
    static let secondary = dynamic(0x5F5A52, 0xA9A39A)
    static let tertiary = dynamic(0x6B665E, 0x8F8980)
    /// Dark buttons (light text) in light mode, light ones in dark mode.
    static let strong = dynamic(0x1D1B18, 0xEDEAE4)
    static let onStrong = dynamic(0xFFFFFF, 0x1D1B18)

    static let record = Color(hex: 0xD6342C)
    static let recordInk = dynamic(0xB52A23, 0xFF7A70)
    static let recordTint = dynamic(0xFBE9E7, 0x4A2522)
    static let accent = dynamic(0x2F6BD8, 0x5B8DEF)
    static let accentTint = dynamic(0xEEF3FC, 0x243451)
    static let good = dynamic(0x2E7D46, 0x5FC07F)
    static let goodTint = dynamic(0xEAF4EC, 0x21382A)

    /// "You" is the microphone, "Them" the other side.
    static let you = dynamic(0x2F5FB8, 0x7FA5EA)
    static let them = dynamic(0x9A4A0B, 0xE8A15F)
    static let youWave = dynamic(0x2F6BD8, 0x5B8DEF)
    static let themWave = dynamic(0xD9731F, 0xE8914A)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension View {
    /// A white (dark: raised) rounded card with a hairline border.
    func card(radius: CGFloat = 12, fill: Color = Palette.card, border: Color = Palette.border) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border))
    }
}

/// Each tag keeps one colour everywhere, picked from its name.
enum TagColor {
    private static let colors: [Color] = [
        0x2F6BD8, 0xC2410C, 0xD9731F, 0x7C4DBA, 0x8A6D3B, 0x0F8B8D, 0x4B5563, 0x2E9E55, 0xDB2777,
    ].map { Color(hex: $0) }

    static func color(for tag: String) -> Color {
        // Not `hashValue`: that changes on every launch.
        let sum = tag.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[sum % colors.count]
    }
}

/// A tag as a small pill with its colour dot.
struct TagChip: View {
    let tag: String
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(TagColor.color(for: tag)).frame(width: 6, height: 6)
            Text(tag).font(.system(size: size, weight: .semibold))
        }
        .foregroundStyle(Palette.ink.opacity(0.85))
        .padding(.horizontal, 7)
        .frame(height: size + 9)
        .background(Palette.fill, in: Capsule())
    }
}

/// The phone or video glyph on a tinted square, in front of a call's name.
struct ChannelIcon: View {
    let isPhone: Bool
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: isPhone ? "phone" : "video")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(isPhone ? Palette.good : Palette.you)
            .frame(width: size, height: size)
            .background(isPhone ? Palette.goodTint : Palette.accentTint, in: RoundedRectangle(cornerRadius: size / 4))
    }
}

/// Levels as rounded bars, newest on the right. `fade` dims older bars.
struct LevelBars: View {
    let levels: [Float]
    let color: Color
    var slots = RecorderModel.historyLength
    var maxHeight: CGFloat = 32
    var fade = true

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            let count = min(slots, Int(size.width / step))
            let shown = levels.suffix(count)
            let start = size.width - CGFloat(shown.count) * step
            for (offset, level) in shown.enumerated() {
                let height = max(2, CGFloat(Self.loudness(level)) * min(maxHeight, size.height))
                let rect = CGRect(x: start + CGFloat(offset) * step, y: (size.height - height) / 2, width: 3, height: height)
                let age = CGFloat(offset) / CGFloat(max(1, count - 1))
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(color.opacity(fade ? 0.25 + 0.75 * age : 1)))
            }
        }
        .accessibilityHidden(true)
    }

    /// Linear peak to 0...1 over a 50 dB range, so speech fills the bar.
    static func loudness(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level) + 50) / 50))
    }
}

/// Dark filled button: the main action on a screen.
struct StrongButtonStyle: ButtonStyle {
    var fill: Color = Palette.strong
    var ink: Color = Palette.onStrong
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        StrongButton(configuration: configuration, fill: fill, ink: ink, height: height)
    }

    private struct StrongButton: View {
        let configuration: Configuration
        let fill: Color
        let ink: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 22)
                .frame(height: height)
                .background(fill.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45),
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// The big red Record button, which turns into Stop with the running time.
struct RecordButton: View {
    @ObservedObject var model: RecorderModel
    var height: CGFloat = 44

    var body: some View {
        Button(action: model.toggle) {
            HStack(spacing: 10) {
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.record).frame(width: 12, height: 12)
                    Text("Stop")
                    Text(RecorderModel.clock(model.elapsed)).fontWeight(.medium).monospacedDigit()
                } else {
                    Circle().fill(.white).frame(width: 12, height: 12)
                    Text("Record")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(model.isRecording ? Palette.recordInk : .white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(model.isRecording ? Palette.card : Palette.record, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.record, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.6 : 1)
        .keyboardShortcut("r")
        .help(model.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
    }
}

/// The credit left today, as a thin bar.
struct CreditBar: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.accent).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

extension DigisensusAccount.Balance {
    /// Share of today's free credit still left.
    var freeFraction: Double { dailyFree > 0 ? free / dailyFree : 0 }
}

/// The Digisensus credit sign: a D with two short strokes through its top and bottom, the way
/// ₿ marks a B. There's no Unicode character for it, so plain text writes "D".
struct CreditSymbol: View {
    var size: CGFloat = 13
    var weight: Font.Weight = .semibold

    var body: some View {
        Text("D")
            .font(.system(size: size, weight: weight))
            .overlay {
                GeometryReader { proxy in
                    let w = proxy.size.width, h = proxy.size.height
                    let stroke = max(1, size * 0.09)
                    ForEach([0.34, 0.56], id: \.self) { x in
                        Group {
                            Capsule().frame(width: stroke, height: h * 0.2).position(x: w * x, y: h * 0.14)
                            Capsule().frame(width: stroke, height: h * 0.2).position(x: w * x, y: h * 0.86)
                        }
                    }
                }
            }
            .accessibilityLabel("D")
    }
}

/// An amount of Digisensus credit: "5.00" and the D sign.
struct CreditAmount: View {
    let amount: Double
    var size: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        HStack(spacing: 2) {
            Text(amount.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: size, weight: weight))
                .monospacedDigit()
            CreditSymbol(size: size, weight: weight)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DigisensusAccount.credit(amount))
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment = HorizontalAlignment.leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = alignment == .center ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : spacing + size.width
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : spacing + size.width
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

enum DayText {
    /// "Today, 29 September", "Yesterday, 28 September", "Tuesday, 24 September".
    static func title(_ date: Date) -> String {
        let calendar = Calendar.current
        let name = calendar.isDateInToday(date) ? "Today"
            : calendar.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.wide))
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return name + ", " + date.formatted(sameYear ? .dateTime.day().month(.wide) : .dateTime.day().month(.wide).year())
    }

    /// "Today, 10:30" in the menu bar; older days get their date.
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", \(time)"
    }
}
