import LockDownCore
import SwiftUI

struct StartSheet: View {
    @EnvironmentObject var store: Store
    let status: BlockStatus
    let close: () -> Void

    @State private var minutes = 60
    @State private var untilStopped = false

    let presets: [(String, Int)] = [("15M", 15), ("30M", 30), ("1H", 60), ("2H", 120), ("4H", 240), ("8H", 480), ("1D", 1440), ("1W", 10080)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(status.activity.source == .timer ? "EXTEND RUN" : "START RUN").font(Pixel.font(14)).foregroundStyle(Pixel.green)
            Text(status.block.name.uppercased()).font(Pixel.font(9)).foregroundStyle(Pixel.inkDim)
            Text("HOW LONG SHOULD IT RUN?").font(Pixel.font(8)).foregroundStyle(Pixel.ink)
            FlowLayout(spacing: 8) {
                ForEach(presets, id: \.1) { p in
                    PixelChip(label: p.0, selected: !untilStopped && minutes == p.1, color: Pixel.green) {
                        minutes = p.1
                        untilStopped = false
                    }
                }
            }
            HStack(spacing: 18) {
                PixelStepper(label: "HOURS", value: Binding(get: { minutes / 60 }, set: { minutes = $0 * 60 + minutes % 60 }), range: 0...720)
                PixelStepper(label: "MIN", value: Binding(get: { minutes % 60 }, set: { minutes = (minutes / 60) * 60 + $0 }), range: 0...55, step: 5)
            }
            if status.block.lock != .timer {
                PixelToggle(label: "RUN UNTIL STOPPED", isOn: $untilStopped,
                            detail: status.block.lock == .none ? "Stop it whenever you like." : "Stopping needs the unlock: \(status.block.lock.label).")
            }
            if status.block.lock != .none {
                HStack(spacing: 8) {
                    Sprites.lock(2)
                    Text("LOCK: \(status.block.lock.label) - APPLIES ONCE STARTED")
                        .font(Pixel.font(7)).foregroundStyle(Pixel.yellow)
                }
            }
            HStack {
                Button("CANCEL", action: close).buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink))
                Spacer()
                Button(untilStopped ? "GO!" : "GO! (\(durationString(minutes * 60)))") {
                    let end: Date? = untilStopped ? nil : endDate()
                    store.send(Request(.startBlock, blockID: status.id, endsAt: end)) { _ in close() }
                }
                .buttonStyle(PixelButtonStyle(color: Pixel.green))
                .disabled(!untilStopped && minutes == 0)
            }
        }
    }

    /// Extends from the current end when a run is already going.
    func endDate() -> Date {
        let base = status.activity.source == .timer ? (status.activity.endsAt ?? store.daemonNow) : store.daemonNow
        return base.addingTimeInterval(Double(minutes) * 60)
    }
}

struct BreakSheet: View {
    @EnvironmentObject var store: Store
    let status: BlockStatus
    let close: () -> Void
    @State private var minutes = 5

    var body: some View {
        let left = (status.allowanceRemaining ?? 0) / 60
        VStack(alignment: .leading, spacing: 16) {
            Text("TAKE A BREAK").font(Pixel.font(14)).foregroundStyle(Pixel.cyan)
            Text("\(left) MIN OF ALLOWANCE LEFT TODAY").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim)
            PixelStepper(label: "MINUTES", value: $minutes, range: 1...max(1, left))
            HStack {
                Button("CANCEL", action: close).buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink))
                Spacer()
                Button("START BREAK") {
                    store.send(Request(.takeBreak, blockID: status.id, minutes: minutes)) { _ in close() }
                }
                .buttonStyle(PixelButtonStyle(color: Pixel.cyan))
                .disabled(left < 1)
            }
        }
    }
}

struct UnlockSheet: View {
    @EnvironmentObject var store: Store
    let status: BlockStatus
    let close: () -> Void

    @State private var challenge: String?
    @State private var typed = ""
    @State private var password = ""
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Sprites.lock(3)
                Text("UNLOCK \(status.block.name.uppercased())").font(Pixel.font(12)).foregroundStyle(Pixel.yellow)
            }
            content
            if let warning {
                Text(warning).font(Pixel.font(8)).foregroundStyle(Pixel.red)
            }
            Text("A solved lock stays open for \(Int(LockEngine.grantSeconds / 60)) minutes. Stop or edit the block in that time.")
                .font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted).lineSpacing(4)
            HStack {
                Button("GIVE UP", action: close).buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink))
                Spacer()
                submitButton
            }
        }
    }

    @ViewBuilder
    var content: some View {
        switch status.block.lock {
        case .randomText:
            if let c = challenge {
                Text("TYPE THIS EXACTLY:").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim)
                // Rendered as plain, non-selectable text so it can't be copied.
                Text(c).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Pixel.ink)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Pixel.bg)
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .padding(8).background(Pixel.bg).overlay(Rectangle().stroke(Pixel.panelHi, lineWidth: 2))
                    .onChange(of: typed) { old, new in
                        // Reject pastes: only one new character at a time is allowed.
                        if new.count > old.count + 1 {
                            typed = old
                            warning = "NO PASTING! TYPE IT."
                        }
                    }
                Text("\(typed.count) / \(c.count)").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
            } else {
                Text("You'll get a random string to type by hand.").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim)
            }
        case .password:
            PixelField(placeholder: "PASSWORD", text: $password, secure: true)
        case .restart:
            Text("This block unlocks after you restart your Mac.").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim).lineSpacing(5)
        case .timer:
            Text("NO CONTINUES. A locked-in block only ends when its run does.").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim).lineSpacing(5)
        case .none:
            Text("Not locked.").font(Pixel.font(8)).foregroundStyle(Pixel.inkDim)
        }
    }

    @ViewBuilder
    var submitButton: some View {
        switch status.block.lock {
        case .randomText:
            if challenge == nil {
                Button("GET CHALLENGE") { requestChallenge() }.buttonStyle(PixelButtonStyle(color: Pixel.yellow))
            } else {
                Button("SUBMIT") {
                    store.send(Request(.solveChallenge, blockID: status.id, text: typed), success: "Unlocked. Stop or edit it now.") { _ in close() }
                    challenge = nil
                    typed = ""
                }
                .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
                .disabled(typed.count != (challenge?.count ?? 0))
            }
        case .password:
            Button("SUBMIT") {
                store.send(Request(.submitPassword, blockID: status.id, text: password), success: "Unlocked. Stop or edit it now.") { _ in close() }
                password = ""
            }
            .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
            .disabled(password.isEmpty)
        default:
            EmptyView()
        }
    }

    func requestChallenge() {
        store.send(Request(.requestChallenge, blockID: status.id)) { r in
            challenge = r.challenge
            typed = ""
            warning = nil
        }
    }
}

// MARK: - Schedule

struct SchedulePanel: View {
    @Binding var block: Block

    var body: some View {
        PixelPanel(title: "SCHEDULE", accent: Pixel.magenta) {
            PixelToggle(label: "RUN ON A WEEKLY SCHEDULE", isOn: $block.scheduleEnabled)
            if block.scheduleEnabled {
                ScheduleGrid(ranges: $block.schedule)
                HStack(spacing: 8) {
                    PixelChip(label: "WORKDAYS 9-5", selected: false, color: Pixel.magenta) {
                        block.schedule = (2...6).map { ScheduleRange(weekday: $0, startMinute: 540, endMinute: 1020) }
                    }
                    PixelChip(label: "EVERY NIGHT 10-7", selected: false, color: Pixel.magenta) {
                        block.schedule = (1...7).flatMap {
                            [ScheduleRange(weekday: $0, startMinute: 1320, endMinute: 1440), ScheduleRange(weekday: $0, startMinute: 0, endMinute: 420)]
                        }
                    }
                    PixelChip(label: "CLEAR", selected: false, color: Pixel.magenta) { block.schedule = [] }
                }
                Text("Click or drag to paint half-hour cells.").font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
            }
        }
    }
}

/// 7 x 48 grid of half-hour cells. Rows run Monday to Sunday.
struct ScheduleGrid: View {
    @Binding var ranges: [ScheduleRange]
    @State private var paintValue: Bool?

    static let rowWeekdays = [2, 3, 4, 5, 6, 7, 1]
    static let rowNames = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    let labelWidth: CGFloat = 40
    let cellH: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Spacer().frame(width: labelWidth)
                GeometryReader { g in
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text("\(h)").font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
                            .position(x: g.size.width * CGFloat(h) / 24 + 6, y: 6)
                    }
                }
                .frame(height: 12)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Self.rowNames, id: \.self) { n in
                        Text(n).font(Pixel.font(7)).foregroundStyle(Pixel.inkDim).frame(width: labelWidth, height: cellH, alignment: .leading)
                    }
                }
                GeometryReader { g in
                    let cells = cellSet()
                    let cw = g.size.width / 48
                    Canvas { ctx, _ in
                        for row in 0..<7 {
                            for col in 0..<48 {
                                let r = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * cellH, width: cw - 1, height: cellH - 1)
                                let on = cells.contains(Cell(row: row, col: col))
                                ctx.fill(Path(r), with: .color(on ? Pixel.magenta : (col % 2 == 0 ? Pixel.bg : Pixel.panel.opacity(0.7))))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let col = Int(v.location.x / cw), row = Int(v.location.y / cellH)
                        guard (0..<48).contains(col), (0..<7).contains(row) else { return }
                        var set = cells
                        let c = Cell(row: row, col: col)
                        if paintValue == nil { paintValue = !set.contains(c) }
                        if paintValue == true { set.insert(c) } else { set.remove(c) }
                        ranges = Self.ranges(from: set)
                    }.onEnded { _ in paintValue = nil })
                }
                .frame(height: cellH * 7)
            }
        }
    }

    struct Cell: Hashable { var row: Int; var col: Int }

    func cellSet() -> Set<Cell> {
        var s = Set<Cell>()
        for r in ranges {
            guard let row = Self.rowWeekdays.firstIndex(of: r.weekday) else { continue }
            for col in (r.startMinute / 30)..<min(48, (r.endMinute + 29) / 30) { s.insert(Cell(row: row, col: col)) }
        }
        return s
    }

    static func ranges(from cells: Set<Cell>) -> [ScheduleRange] {
        var out: [ScheduleRange] = []
        for row in 0..<7 {
            var col = 0
            while col < 48 {
                guard cells.contains(Cell(row: row, col: col)) else { col += 1; continue }
                let start = col
                while col < 48 && cells.contains(Cell(row: row, col: col)) { col += 1 }
                out.append(ScheduleRange(weekday: rowWeekdays[row], startMinute: start * 30, endMinute: col * 30))
            }
        }
        return out
    }
}
