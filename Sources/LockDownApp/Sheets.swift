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
                Text(c).font(Pixel.mono(15, weight: .bold)).foregroundStyle(Pixel.ink)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Pixel.bg)
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    .font(Pixel.mono(15))
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

/// "NEXT RUN" text for a scheduled block; nil when nothing is painted.
func nextRunLabel(_ block: Block, now: Date) -> String? {
    guard let next = LockEngine().nextScheduleStart(block.schedule, after: now) else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEE h:mm a"
    return f.string(from: next).uppercased()
}

/// "7:00 AM" for minutes after midnight.
func clockLabel(minute: Int) -> String {
    let h = minute / 60
    return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", minute % 60)) \(h < 12 ? "AM" : "PM")"
}

/// A block runs when you start it or by itself on a schedule. A freeze can also flicker at random.
struct RunModePanel: View {
    @EnvironmentObject var store: Store
    @Binding var block: Block
    let status: BlockStatus?
    let dirty: Bool
    let start: () -> Void

    var body: some View {
        PixelPanel(title: "WHEN IT RUNS", accent: Pixel.magenta) {
            HStack(spacing: 8) {
                PixelChip(label: "WHEN I START IT", selected: !block.scheduleEnabled && block.flicker == nil, color: Pixel.magenta) {
                    block.scheduleEnabled = false
                    block.flicker = nil
                }
                PixelChip(label: "ON A SCHEDULE", selected: block.scheduleEnabled, color: Pixel.magenta) {
                    block.scheduleEnabled = true
                    block.flicker = nil
                }
                if block.kind == .frozen {
                    PixelChip(label: "RANDOM FLICKER", selected: block.flicker != nil, color: Pixel.magenta) {
                        block.scheduleEnabled = false
                        block.reenableDailyMinute = nil
                        if block.flicker == nil { block.flicker = FlickerPolicy() }
                    }
                }
            }
            if block.flicker != nil {
                flickering
            } else if !block.scheduleEnabled {
                manual
            } else {
                scheduled
            }
            // Switching away from manual doesn't cancel a run you already started.
            if block.scheduleEnabled || block.flicker != nil, !dirty, status?.activity.source == .timer { startButton }
            if block.kind == .standard { reenableDaily }
        }
    }

    var startButton: some View {
        Button(status?.activity.source == .timer ? "EXTEND" : "START NOW", action: start)
            .buttonStyle(PixelButtonStyle(color: Pixel.green, size: 9))
            .disabled(dirty || status == nil)
    }

    var manual: some View {
        HStack(spacing: 14) {
            startButton
            Text(dirty || status == nil ? "SAVE FIRST, THEN START IT." : block.reenableDailyMinute == nil ? "RUNS ONLY WHEN YOU START IT." : "START IT NOW, OR LET IT COME BACK ON BELOW.")
                .font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
        }
    }

    var reenableIsOn: Binding<Bool> {
        Binding(get: { block.reenableDailyMinute != nil }, set: { block.reenableDailyMinute = $0 ? 7 * 60 : nil })
    }

    func shiftReenable(by minutes: Int) {
        guard let m = block.reenableDailyMinute else { return }
        block.reenableDailyMinute = (m + minutes + 1440) % 1440
    }

    @ViewBuilder
    var reenableDaily: some View {
        PixelToggle(label: "RE-ENABLE DAILY", isOn: reenableIsOn,
                    detail: "Turn it off for the evening. It comes back on and relocks.")
        if let m = block.reenableDailyMinute {
            HStack(spacing: 8) {
                Text("AT").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
                ForEach([("-1H", -60), ("-15", -15)], id: \.0) { label, shift in
                    Button(label) { shiftReenable(by: shift) }
                        .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink, size: 8))
                }
                Text(clockLabel(minute: m)).font(Pixel.font(10)).foregroundStyle(Pixel.yellow).frame(minWidth: Pixel.ui(84))
                ForEach([("+15", 15), ("+1H", 60)], id: \.0) { label, shift in
                    Button(label) { shiftReenable(by: shift) }
                        .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink, size: 8))
                }
            }
            Text(reenableNote(m)).font(Pixel.font(7)).foregroundStyle(block.lock == .timer ? Pixel.red : Pixel.inkMuted)
        }
    }

    func reenableNote(_ minute: Int) -> String {
        if block.lock == .timer { return "LOCKED IN HAS NO UNLOCK. PICK ANOTHER LOCK TO USE THIS." }
        let time = clockLabel(minute: minute)
        return block.scheduleEnabled
            ? "SKIPPED HOURS COME BACK AT \(time). OUTSIDE THE SCHEDULE IT STAYS OFF."
            : "BACK ON AT \(time) EVERY DAY, OR ON WAKING IF THE MAC WAS ASLEEP."
    }

    var flickerNote: String {
        if dirty || status == nil { return "SAVE TO TURN FLICKER ON. IT STARTS WITH A FREE WINDOW." }
        if status?.activity.source == .flicker { return "FROZEN NOW. A NEW LENGTH IS PICKED EACH TIME." }
        return "FLICKER IS ON. THE NEXT FREEZE COMES WITHOUT WARNING."
    }

    /// Steps by 5 above 5 minutes, snapping to multiples, and keeps each pair in order.
    func flickerBound(_ bound: WritableKeyPath<FlickerPolicy, Int>, other: WritableKeyPath<FlickerPolicy, Int>, isLower: Bool) -> Binding<Int> {
        Binding(
            get: { block.flicker?[keyPath: bound] ?? 1 },
            set: { new in
                guard var f = block.flicker else { return }
                let value = new < 5 ? new : new / 5 * 5
                f[keyPath: bound] = value
                f[keyPath: other] = isLower ? max(f[keyPath: other], value) : min(f[keyPath: other], value)
                block.flicker = f
            })
    }

    @ViewBuilder
    var flickering: some View {
        Text(flickerNote).font(Pixel.font(7)).foregroundStyle(Pixel.yellow)
        flickerRow("FROZEN FOR", low: \.frozenMinMinutes, high: \.frozenMaxMinutes)
        flickerRow("FREE FOR", low: \.freeMinMinutes, high: \.freeMaxMinutes)
        Text("Runs day and night until you switch it off.")
            .font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
        if block.frozenMode != .lockScreen {
            Text("\(block.frozenMode == .logout ? "LOG OUT" : "SHUT DOWN") GIVES ONLY 20 SECONDS' NOTICE. UNSAVED WORK CAN BE LOST.")
                .font(Pixel.font(7)).foregroundStyle(Pixel.red)
        }
    }

    func flickerRow(_ label: String, low: WritableKeyPath<FlickerPolicy, Int>, high: WritableKeyPath<FlickerPolicy, Int>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Pixel.font(7)).foregroundStyle(Pixel.ink).frame(width: Pixel.ui(84), alignment: .leading)
            PixelStepper(label: "AT LEAST", value: flickerBound(low, other: high, isLower: true), range: 1...720, step: 5)
            PixelStepper(label: "AT MOST", value: flickerBound(high, other: low, isLower: false), range: 1...720, step: 5)
            Text("MINUTES").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
        }
    }

    var scheduleNote: String {
        if block.schedule.isEmpty { return "PAINT SOME HOURS OR THIS BLOCK WILL NEVER RUN." }
        if dirty || status == nil { return "SAVE TO TURN THIS SCHEDULE ON." }
        if status?.activity.source == .schedule { return "RUNNING NOW. TURNS ITSELF OFF AND ON AT THESE TIMES." }
        return nextRunLabel(block, now: store.daemonNow).map { "TURNS ITSELF ON. NEXT RUN: \($0)" } ?? ""
    }

    @ViewBuilder
    var scheduled: some View {
        Text(scheduleNote).font(Pixel.font(7)).foregroundStyle(Pixel.yellow)
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

/// 7 x 48 grid of half-hour cells. Rows run Monday to Sunday.
struct ScheduleGrid: View {
    @Binding var ranges: [ScheduleRange]
    @State private var paintValue: Bool?

    static let rowWeekdays = [2, 3, 4, 5, 6, 7, 1]
    static let rowNames = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    var labelWidth: CGFloat { Pixel.ui(36) }
    var cellH: CGFloat { Pixel.ui(14) }
    var headerH: CGFloat { Pixel.ui(32) }

    static func hourLabel(_ hour: Int) -> String { "\(hour % 12 == 0 ? 12 : hour % 12)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Spacer().frame(width: labelWidth)
                GeometryReader { g in
                    let hourW = g.size.width / 24
                    ForEach(0..<24, id: \.self) { h in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(h == 0 ? "AM" : h == 12 ? "PM" : " ").foregroundStyle(Pixel.magenta)
                            Text(Self.hourLabel(h)).foregroundStyle(Pixel.inkDim)
                        }
                        .font(Pixel.font(7))
                        .fixedSize()
                        .frame(width: hourW, alignment: .leading)
                        .position(x: hourW * (CGFloat(h) + 0.5), y: headerH / 2)
                    }
                }
                .frame(height: headerH)
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
                                // A wider gap on the hour lines the cells up with the labels above.
                                let r = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * cellH, width: cw - (col % 2 == 1 ? 2 : 1), height: cellH - 1)
                                let on = cells.contains(Cell(row: row, col: col))
                                ctx.fill(Path(r), with: .color(on ? Pixel.magenta : Pixel.bg))
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
