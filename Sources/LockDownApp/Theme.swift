import AppKit
import CoreText
import SwiftUI

enum Pixel {
    static let fontName = "PressStart2P-Regular"

    static func registerFont() {
        guard let url = Bundle.main.url(forResource: "PressStart2P-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// User-chosen text scale (OPTIONS > TEXT SIZE). Shared by the app and the agent's freeze screen.
    static var scale: CGFloat {
        let v = prefs.double(forKey: TextSize.key)
        return v > 0 ? v : TextSize.large.rawValue
    }

    static var prefs: UserDefaults {
        Bundle.main.bundleIdentifier == "com.lockdown.app" ? .standard : (UserDefaults(suiteName: "com.lockdown.app") ?? .standard)
    }

    /// Pixel font at `size` design points, scaled; never below 11pt so small labels stay legible.
    static func font(_ size: CGFloat) -> Font { .custom(fontName, fixedSize: max(11, (size * scale).rounded())) }

    /// Monospaced system font for challenge strings and commands, scaled the same way.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: (size * min(scale, 1.6)).rounded(), weight: weight, design: .monospaced)
    }

    /// Scales a layout dimension with the text size.
    static func ui(_ v: CGFloat) -> CGFloat { (v * scale).rounded() }

    // Palette: a dark arcade cabinet with neon accents.
    static let bg = Color(hex: 0x0E0B1F)
    static let panel = Color(hex: 0x1C1838)
    static let panelHi = Color(hex: 0x2A2552)
    static let ink = Color(hex: 0xF4F1E8)
    static let inkDim = Color(hex: 0xCFCBEA)
    static let inkMuted = Color(hex: 0xA6A2C8)
    static let edge = Color(hex: 0x000000)
    static let green = Color(hex: 0x3DDC84)
    static let red = Color(hex: 0xFF4D6D)
    static let yellow = Color(hex: 0xFFD23F)
    static let cyan = Color(hex: 0x4CC9F0)
    static let magenta = Color(hex: 0xF15BB5)
    static let ice = Color(hex: 0xA8E6FF)
}

enum TextSize: CGFloat, CaseIterable {
    case medium = 1.25, large = 1.5, huge = 1.85
    static let key = "textScale"

    var label: String {
        switch self {
        case .medium: return "MEDIUM"
        case .large: return "LARGE"
        case .huge: return "HUGE"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A rectangle with stepped (notched) corners, like a sprite-drawn box.
struct PixelRect: Shape {
    var step: CGFloat = 4

    func path(in r: CGRect) -> Path {
        let s = step
        var p = Path()
        p.move(to: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.closeSubpath()
        return p
    }
}

/// A framed panel with a title tab.
struct PixelPanel<Content: View>: View {
    var title: String?
    var accent: Color = Pixel.cyan
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(Pixel.font(10))
                    .foregroundStyle(Pixel.edge)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(accent)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PixelRect().fill(Pixel.panel))
        .overlay(PixelRect().stroke(Pixel.edge, lineWidth: 3))
        .overlay(PixelRect(step: 4).inset(by: 3).stroke(Pixel.panelHi, lineWidth: 2))
    }
}

extension PixelRect: InsettableShape {
    func inset(by amount: CGFloat) -> some InsettableShape { InsetPixelRect(step: step, inset: amount) }
}

struct InsetPixelRect: InsettableShape {
    var step: CGFloat
    var inset: CGFloat
    func path(in r: CGRect) -> Path { PixelRect(step: step).path(in: r.insetBy(dx: inset, dy: inset)) }
    func inset(by amount: CGFloat) -> some InsettableShape { InsetPixelRect(step: step, inset: inset + amount) }
}

/// Chunky button with a hard drop shadow that "presses" down.
struct PixelButtonStyle: ButtonStyle {
    var color: Color = Pixel.green
    var textColor: Color = Pixel.edge
    var size: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        PixelButtonBody(configuration: configuration, color: color, textColor: textColor, size: size)
    }
}

private struct PixelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    let textColor: Color
    let size: CGFloat
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Pixel.font(size))
            .foregroundStyle(enabled ? textColor : Pixel.inkMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PixelRect(step: 3).fill(enabled ? color : Pixel.panelHi))
            .overlay(PixelRect(step: 3).stroke(Pixel.edge, lineWidth: 2))
            .background(PixelRect(step: 3).fill(Pixel.edge).offset(x: pressed ? 0 : 3, y: pressed ? 0 : 3))
            .offset(x: pressed ? 3 : 0, y: pressed ? 3 : 0)
            .contentShape(Rectangle())
    }
}

/// Selectable chip used for segmented choices.
struct PixelChip: View {
    let label: String
    let selected: Bool
    var color: Color = Pixel.yellow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Pixel.font(9))
                .foregroundStyle(selected ? Pixel.edge : Pixel.inkDim)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(PixelRect(step: 2).fill(selected ? color : Pixel.bg))
                .overlay(PixelRect(step: 2).stroke(selected ? Pixel.edge : Pixel.panelHi, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct PixelToggle: View {
    let label: String
    @Binding var isOn: Bool
    var detail: String?

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Rectangle().fill(Pixel.bg).frame(width: 18, height: 18)
                        .overlay(Rectangle().stroke(Pixel.inkDim, lineWidth: 2))
                    if isOn { Rectangle().fill(Pixel.green).frame(width: 10, height: 10) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(label).font(Pixel.font(9)).foregroundStyle(Pixel.ink)
                    if let detail {
                        Text(detail).font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Retro text field.
struct PixelField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(Pixel.font(10))
        .foregroundStyle(Pixel.ink)
        .padding(8)
        .background(Rectangle().fill(Pixel.bg))
        .overlay(Rectangle().stroke(Pixel.panelHi, lineWidth: 2))
    }
}

/// Multi-line list editor (one entry per line).
struct PixelListEditor: View {
    @Binding var lines: [String]
    var height: CGFloat = 110
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(Pixel.font(9))
            .foregroundStyle(Pixel.ink)
            .scrollContentBackground(.hidden)
            .lineSpacing(6)
            .padding(6)
            .frame(height: height)
            .background(Rectangle().fill(Pixel.bg))
            .overlay(Rectangle().stroke(Pixel.panelHi, lineWidth: 2))
            .onAppear {
                text = lines.joined(separator: "\n")
                loaded = true
            }
            .onChange(of: lines) { _, new in
                // Only overwrite when the source changed (e.g. a different block was selected).
                if new != parsed { text = new.joined(separator: "\n") }
            }
            .onChange(of: text) { _, _ in
                if loaded, parsed != lines { lines = parsed }
            }
    }

    private var parsed: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// CRT scanlines over everything.
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.10)))
                y += 3
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Toggles visibility on a fixed beat, like an arcade attract screen.
struct Blink: ViewModifier {
    var interval: Double = 0.6

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: interval)) { ctx in
            content.opacity(Int(ctx.date.timeIntervalSinceReferenceDate / interval) % 2 == 0 ? 1 : 0)
        }
    }
}

extension View {
    func blinking(_ interval: Double = 0.6) -> some View { modifier(Blink(interval: interval)) }
}

func clockString(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
    if d > 0 { return String(format: "%dD %02d:%02d:%02d", d, h, m, sec) }
    return String(format: "%02d:%02d:%02d", h, m, sec)
}

func durationString(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60
    if h > 0 { return "\(h)H \(m)M" }
    if m > 0 { return "\(m)M" }
    return "\(seconds)S"
}
