import AppKit
import LockDownCore
import SwiftUI

struct BlocksScreen: View {
    @EnvironmentObject var store: Store
    /// A block created locally that hasn't been saved yet.
    @State private var newDraft: Block?

    var body: some View {
        HStack(spacing: 0) {
            BlockList(newDraft: $newDraft)
                .frame(width: Pixel.ui(250))
            Rectangle().fill(Pixel.edge).frame(width: 3)
            Group {
                if let draft = newDraft {
                    BlockEditor(original: draft, status: nil, isNew: true) { newDraft = nil }
                        .id(draft.id)
                } else if let s = store.status(store.selectedID) {
                    BlockEditor(original: s.block, status: s, isNew: false) {}
                        .id(s.id)
                } else {
                    EmptyLevel { newDraft = Block(name: "NEW BLOCK") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EmptyLevel: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Logo(pixel: 7)
            Text("NO BLOCKS YET").font(Pixel.font(14)).foregroundStyle(Pixel.ink)
            Text("PRESS START").font(Pixel.font(10)).foregroundStyle(Pixel.yellow).blinking()
            Button("+ NEW BLOCK", action: create).buttonStyle(PixelButtonStyle())
        }
    }
}

struct BlockList: View {
    @EnvironmentObject var store: Store
    @Binding var newDraft: Block?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SELECT BLOCK").font(Pixel.font(10)).foregroundStyle(Pixel.inkDim).padding(.top, 16)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.snapshot?.blocks ?? []) { s in
                        BlockRow(status: s, selected: newDraft == nil && store.selectedID == s.id, now: store.daemonNow)
                            .onTapGesture {
                                newDraft = nil
                                store.selectedID = s.id
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 10) {
                Button("+ BLOCK") { newDraft = Block(name: "NEW BLOCK") }
                    .buttonStyle(PixelButtonStyle(size: 9))
                Button("+ FREEZE") { newDraft = Block(name: "FREEZE", kind: .frozen) }
                    .buttonStyle(PixelButtonStyle(color: Pixel.ice, size: 9))
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 14)
        .background(Pixel.bg)
    }
}

struct BlockRow: View {
    let status: BlockStatus
    let selected: Bool
    let now: Date

    var body: some View {
        let a = status.activity
        HStack(spacing: 10) {
            Group {
                if status.block.kind == .frozen { Sprites.snowflake(2) }
                else if !status.block.apps.isEmpty && !status.block.hasWebRules { Sprites.joystick(2) }
                else { Sprites.globe(2) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(status.block.name.uppercased()).font(Pixel.font(9)).foregroundStyle(Pixel.ink).lineLimit(1)
                Text(subtitle(a)).font(Pixel.font(7)).foregroundStyle(color(a))
            }
            Spacer()
            if status.locked { Sprites.lock(2) }
        }
        .padding(10)
        .background(PixelRect(step: 3).fill(selected ? Pixel.panelHi : Pixel.panel))
        .overlay(PixelRect(step: 3).stroke(selected ? Pixel.yellow : Pixel.edge, lineWidth: 2))
        .contentShape(Rectangle())
    }

    func subtitle(_ a: Activity) -> String {
        if let b = a.breakEndsAt { return "BREAK \(clockString(Int(b.timeIntervalSince(now))))" }
        if a.enforcing {
            if let e = a.endsAt { return "ON \(clockString(Int(e.timeIntervalSince(now))))" }
            return "ON - NO END"
        }
        if status.block.flicker != nil { return "FLICKER ON" }
        if !status.block.scheduleEnabled, let m = status.block.reenableDailyMinute { return "BACK \(clockLabel(minute: m))" }
        guard status.block.scheduleEnabled else { return "IDLE" }
        return nextRunLabel(status.block, now: now).map { "NEXT \($0)" } ?? "NO HOURS SET"
    }

    func color(_ a: Activity) -> Color {
        if a.breakEndsAt != nil { return Pixel.cyan }
        return a.enforcing ? Pixel.green : Pixel.inkMuted
    }
}

// MARK: - Editor

struct BlockEditor: View {
    @EnvironmentObject var store: Store
    let original: Block
    let status: BlockStatus?
    let isNew: Bool
    let onSaved: () -> Void

    @State private var draft: Block
    @State private var newPassword = ""
    @State private var showStart = false
    @State private var showUnlock = false
    @State private var showBreak = false
    @State private var confirmDelete = false

    init(original: Block, status: BlockStatus?, isNew: Bool, onSaved: @escaping () -> Void) {
        self.original = original
        self.status = status
        self.isNew = isNew
        self.onSaved = onSaved
        _draft = State(initialValue: original)
    }

    var dirty: Bool { draft != original || !newPassword.isEmpty }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    RunModePanel(block: $draft, status: status, dirty: dirty) { showStart = true }
                    if draft.kind == .frozen { frozenPanel } else {
                        websitesPanel
                        appsPanel
                    }
                    if draft.kind == .standard { breaksPanel }
                    lockPanel
                    footer
                }
                .padding(20)
            }
            if showStart, let s = status {
                Overlay { StartSheet(status: s) { showStart = false } }
            }
            if showUnlock, let s = status {
                Overlay { UnlockSheet(status: s) { showUnlock = false } }
            }
            if showBreak, let s = status {
                Overlay { BreakSheet(status: s) { showBreak = false } }
            }
            if confirmDelete {
                Overlay {
                    ConfirmSheet(title: "DELETE?", message: "Delete \(original.name)? This can't be undone.",
                                 confirm: "DELETE", color: Pixel.red) {
                        confirmDelete = false
                        store.send(Request(.deleteBlock, blockID: original.id)) { _ in store.selectedID = nil }
                    } cancel: { confirmDelete = false }
                }
            }
        }
    }

    // MARK: Sections

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("NAME", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(Pixel.font(18))
                    .foregroundStyle(Pixel.yellow)
                if let s = status { ActivityBadge(status: s) } else {
                    Text("NEW - NOT SAVED").font(Pixel.font(8)).foregroundStyle(Pixel.inkMuted)
                }
            }
            Spacer()
            if let s = status { actionButtons(s) }
        }
    }

    @ViewBuilder
    func actionButtons(_ s: BlockStatus) -> some View {
        HStack(spacing: 10) {
            if s.activity.running, case .allowance = s.block.breakPolicy {
                if s.activity.breakEndsAt != nil {
                    Button("END BREAK") { store.send(Request(.endBreak, blockID: s.id)) }
                        .buttonStyle(PixelButtonStyle(color: Pixel.cyan, size: 9))
                } else {
                    Button("BREAK") { showBreak = true }
                        .buttonStyle(PixelButtonStyle(color: Pixel.cyan, size: 9))
                }
            }
            if s.locked && s.block.lock != .timer {
                Button("UNLOCK") { showUnlock = true }
                    .buttonStyle(PixelButtonStyle(color: Pixel.yellow, size: 9))
            }
            if s.activity.running {
                Button("STOP") { store.send(Request(.stopBlock, blockID: s.id)) }
                    .buttonStyle(PixelButtonStyle(color: Pixel.red, size: 9))
                    .disabled(s.locked)
                    .help(s.activity.source == .schedule ? "Skip the rest of this scheduled window"
                          : s.activity.source == .flicker ? "End this freeze. Flicker stays on" : "Stop this run")
            }
        }
    }

    var websitesPanel: some View {
        PixelPanel(title: "WEBSITES", accent: Pixel.cyan) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BLOCK (ONE PER LINE)").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
                    PixelListEditor(lines: $draft.websites)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXCEPTIONS").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
                    PixelListEditor(lines: $draft.websiteExceptions)
                }
            }
            PixelToggle(label: "BLOCK THE ENTIRE INTERNET", isOn: $draft.blockEntireInternet,
                        detail: "Everything except the exceptions list.")
            if draft.websites.contains(where: DomainMatcher.entryHasPath) || draft.websiteExceptions.contains(where: DomainMatcher.entryHasPath) {
                Text("NOTE: PATHS ARE IGNORED. LOCKDOWN BLOCKS WHOLE DOMAINS.")
                    .font(Pixel.font(7)).foregroundStyle(Pixel.yellow)
            }
            Text(verbatim: "example.com blocks all subdomains. Use * as a wildcard, e.g. *tube*.")
                .font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
        }
    }

    var appsPanel: some View {
        PixelPanel(title: "APPS", accent: Pixel.magenta) {
            if draft.apps.isEmpty {
                Text("NO APPS BLOCKED").font(Pixel.font(8)).foregroundStyle(Pixel.inkMuted)
            }
            FlowRows(items: draft.apps) { app in
                HStack(spacing: 8) {
                    if let p = app.path {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().interpolation(.none)
                            .frame(width: 16, height: 16)
                    }
                    Text(app.name.uppercased()).font(Pixel.font(8)).foregroundStyle(Pixel.ink)
                    Button("X") { draft.apps.removeAll { $0.bundleID == app.bundleID } }
                        .buttonStyle(.plain).font(Pixel.font(8)).foregroundStyle(Pixel.red)
                }
                .padding(7)
                .background(Pixel.bg)
                .overlay(Rectangle().stroke(Pixel.panelHi, lineWidth: 2))
            }
            HStack(spacing: 10) {
                Button("+ CHOOSE APP") { chooseApps() }.buttonStyle(PixelButtonStyle(color: Pixel.magenta, size: 8))
                Menu {
                    ForEach(runningApps(), id: \.bundleID) { a in
                        Button(a.name) { if !draft.apps.contains(a) { draft.apps.append(a) } }
                    }
                } label: {
                    Text("+ RUNNING APP").font(Pixel.font(8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("WINDOW TITLES (HIDE APPS WHOSE WINDOW TITLE CONTAINS)").font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
                .padding(.top, 4)
            PixelListEditor(lines: $draft.titleKeywords, height: 60)
        }
    }

    var frozenPanel: some View {
        PixelPanel(title: "FREEZE", accent: Pixel.ice) {
            HStack(spacing: 12) {
                Sprites.snowflake(4)
                Text("Locks the whole computer while active.")
                    .font(Pixel.font(8)).foregroundStyle(Pixel.inkDim).lineSpacing(5)
            }
            HStack(spacing: 8) {
                ForEach(FrozenMode.allCases, id: \.self) { m in
                    PixelChip(label: label(m), selected: draft.frozenMode == m, color: Pixel.ice) { draft.frozenMode = m }
                }
            }
        }
    }

    func label(_ m: FrozenMode) -> String {
        switch m {
        case .lockScreen: return "FREEZE SCREEN"
        case .logout: return "LOG OUT"
        case .shutdown: return "SHUT DOWN"
        }
    }

    var breaksPanel: some View {
        PixelPanel(title: "BREAKS", accent: Pixel.green) {
            HStack(spacing: 8) {
                PixelChip(label: "NONE", selected: draft.breakPolicy == .none, color: Pixel.green) { draft.breakPolicy = .none }
                PixelChip(label: "POMODORO", selected: isPomodoro, color: Pixel.green) {
                    draft.breakPolicy = .pomodoro(workMinutes: 25, breakMinutes: 5)
                }
                PixelChip(label: "ALLOWANCE", selected: isAllowance, color: Pixel.green) {
                    draft.breakPolicy = .allowance(minutesPerDay: 30)
                }
            }
            switch draft.breakPolicy {
            case .none:
                Text("NO BREAKS. BLOCK STAYS ON THE WHOLE RUN.").font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
            case let .pomodoro(w, b):
                HStack(spacing: 20) {
                    PixelStepper(label: "WORK MIN", value: Binding(get: { w }, set: { draft.breakPolicy = .pomodoro(workMinutes: $0, breakMinutes: b) }), range: 1...240)
                    PixelStepper(label: "BREAK MIN", value: Binding(get: { b }, set: { draft.breakPolicy = .pomodoro(workMinutes: w, breakMinutes: $0) }), range: 1...120)
                }
            case let .allowance(m):
                PixelStepper(label: "FREE MIN / DAY", value: Binding(get: { m }, set: { draft.breakPolicy = .allowance(minutesPerDay: $0) }), range: 1...720, step: 5)
                Text("Spend allowance minutes on demand with BREAK while the block runs.")
                    .font(Pixel.font(7)).foregroundStyle(Pixel.inkMuted)
            }
        }
    }

    var isPomodoro: Bool { if case .pomodoro = draft.breakPolicy { return true } else { return false } }
    var isAllowance: Bool { if case .allowance = draft.breakPolicy { return true } else { return false } }

    var lockPanel: some View {
        PixelPanel(title: "LOCK", accent: Pixel.yellow) {
            HStack(spacing: 8) {
                PixelChip(label: "NONE", selected: draft.lock == .none) { draft.lock = .none }
                PixelChip(label: "LOCKED IN", selected: draft.lock == .timer) { draft.lock = .timer }
                PixelChip(label: "RANDOM TEXT", selected: isRandom) { draft.lock = .randomText(length: 60) }
                PixelChip(label: "PASSWORD", selected: isPassword) { draft.lock = .password(salt: "", hash: "") }
                PixelChip(label: "RESTART", selected: draft.lock == .restart) { draft.lock = .restart }
            }
            Text(lockHelp).font(Pixel.font(7)).foregroundStyle(Pixel.inkDim).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if case .randomText(let n) = draft.lock {
                PixelStepper(label: "CHARACTERS", value: Binding(get: { n }, set: { draft.lock = .randomText(length: $0) }), range: 5...500, step: 5)
            }
            if isPassword {
                PixelField(placeholder: originalHasPassword ? "NEW PASSWORD (LEAVE EMPTY TO KEEP)" : "SET PASSWORD", text: $newPassword, secure: true)
                    .frame(maxWidth: 380)
            }
            if draft.flicker != nil && draft.lock != .none {
                PixelToggle(label: "LOCK FLICKER BETWEEN FREEZES", isOn: $draft.lockScheduleAlways,
                            detail: draft.lock == .timer
                                ? "Locked in has no unlock, so only 3 restarts during a freeze can turn flicker off."
                                : "Stops you switching flicker off while the computer is free.")
            }
            if !draft.scheduleEnabled && draft.reenableDailyMinute != nil && draft.lock != .none && draft.lock != .timer {
                PixelToggle(label: "LOCK RE-ENABLE WHILE OFF", isOn: $draft.lockScheduleAlways,
                            detail: "Stops you switching this off for good during the evening.")
            }
            if draft.scheduleEnabled && draft.lock != .none {
                PixelToggle(label: "LOCK SCHEDULE OUTSIDE BLOCKED HOURS", isOn: $draft.lockScheduleAlways,
                            detail: "Stops you editing the schedule away before it starts.")
            }
        }
    }

    var isRandom: Bool { if case .randomText = draft.lock { return true } else { return false } }
    var isPassword: Bool { if case .password = draft.lock { return true } else { return false } }
    var originalHasPassword: Bool { if case .password = original.lock, !isNew { return true } else { return false } }

    var lockHelp: String {
        switch draft.lock {
        case .none: return "No lock. You can stop or edit this block any time."
        case .timer: return "No way out. Once started it can't be stopped or loosened until the run you picked (or the schedule window) ends."
        case .randomText: return "To unlock, type a fresh random string by hand. No pasting."
        case .password: return "Give the password to someone you trust. Only a hash is stored."
        case .restart: return "Unlocks only after you restart your Mac."
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Button(isNew ? "SAVE NEW BLOCK" : "SAVE") { save() }
                .buttonStyle(PixelButtonStyle(color: Pixel.yellow))
                .disabled(!dirty && !isNew)
                .keyboardShortcut("s", modifiers: .command)
            if dirty && !isNew {
                Button("REVERT") { draft = original; newPassword = "" }
                    .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink))
            }
            Spacer()
            if !isNew {
                Button("DELETE") { confirmDelete = true }
                    .buttonStyle(PixelButtonStyle(color: Pixel.red))
                    .disabled(status?.locked == true)
            } else {
                Button("CANCEL") { onSaved() }
                    .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink))
            }
        }
    }

    func save() {
        let pw = newPassword.isEmpty ? nil : newPassword
        store.send(Request(.saveBlock, block: draft, text: pw)) { _ in
            newPassword = ""
            store.selectedID = draft.id
            onSaved()
        }
    }

    func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier else { continue }
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let ref = AppRef(bundleID: id, name: name, path: url.path)
            if !draft.apps.contains(where: { $0.bundleID == id }) { draft.apps.append(ref) }
        }
    }

    func runningApps() -> [AppRef] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in
                a.bundleIdentifier.map { AppRef(bundleID: $0, name: a.localizedName ?? $0, path: a.bundleURL?.path) }
            }
            .sorted { $0.name < $1.name }
    }
}

struct ActivityBadge: View {
    @EnvironmentObject var store: Store
    let status: BlockStatus

    var body: some View {
        let a = status.activity
        let now = store.daemonNow
        HStack(spacing: 10) {
            if status.locked { Sprites.lock(2) } else if a.running { Sprites.unlock(2) }
            if let b = a.breakEndsAt {
                Text("BREAK - \(clockString(Int(b.timeIntervalSince(now))))").foregroundStyle(Pixel.cyan)
            } else if a.enforcing {
                Text(a.endsAt.map { "BLOCKING - \(clockString(Int($0.timeIntervalSince(now)))) LEFT" } ?? "BLOCKING - UNTIL STOPPED")
                    .foregroundStyle(Pixel.green)
            } else {
                Text(status.block.flicker != nil ? "FLICKER ON - FREE FOR NOW"
                     : status.block.scheduleEnabled ? nextRunLabel(status.block, now: now).map { "NEXT RUN \($0)" } ?? "NO HOURS SET"
                     : status.block.reenableDailyMinute.map { "OFF - BACK ON AT \(clockLabel(minute: $0))" } ?? "IDLE")
                    .foregroundStyle(Pixel.inkMuted)
            }
            if let next = a.nextBreakAt {
                Text("NEXT BREAK \(clockString(Int(next.timeIntervalSince(now))))").foregroundStyle(Pixel.inkDim)
            }
            if let r = status.allowanceRemaining {
                Text("ALLOWANCE \(durationString(r))").foregroundStyle(Pixel.inkDim)
            }
        }
        .font(Pixel.font(8))
    }
}

struct PixelStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Pixel.font(7)).foregroundStyle(Pixel.inkDim)
            Button("-") { value = max(range.lowerBound, value - step) }
                .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink, size: 8))
            Text("\(value)").font(Pixel.font(10)).foregroundStyle(Pixel.yellow).frame(minWidth: 44)
            Button("+") { value = min(range.upperBound, value + step) }
                .buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink, size: 8))
        }
    }
}

/// Wraps items onto multiple rows.
struct FlowRows<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { cell($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

struct Overlay<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            content()
                .padding(24)
                .frame(maxWidth: Pixel.ui(480))
                .background(PixelRect(step: 6).fill(Pixel.panel))
                .overlay(PixelRect(step: 6).stroke(Pixel.yellow, lineWidth: 3))
        }
    }
}

struct ConfirmSheet: View {
    let title: String
    let message: String
    let confirm: String
    let color: Color
    let onConfirm: () -> Void
    let cancel: () -> Void

    init(title: String, message: String, confirm: String, color: Color, onConfirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.confirm = confirm
        self.color = color
        self.onConfirm = onConfirm
        self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(Pixel.font(16)).foregroundStyle(color)
            Text(message).font(Pixel.font(9)).foregroundStyle(Pixel.ink).multilineTextAlignment(.center).lineSpacing(6)
            HStack(spacing: 14) {
                Button("CANCEL", action: cancel).buttonStyle(PixelButtonStyle(color: Pixel.panelHi, textColor: Pixel.ink))
                Button(confirm, action: onConfirm).buttonStyle(PixelButtonStyle(color: color))
            }
        }
    }
}
