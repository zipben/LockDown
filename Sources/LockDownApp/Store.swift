import Foundation
import LockDownCore
import SwiftUI

struct Dialog: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var color: Color = Pixel.red
}

/// Polls the daemon and runs commands off the main thread.
@MainActor
final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var connected = true
    @Published var dialog: Dialog?
    @Published var selectedID: UUID?
    @Published var busy = false

    /// Offset between the daemon's trusted clock and ours, so countdowns tick locally between polls.
    @Published var clockSkew: TimeInterval = 0

    private var timer: Timer?

    /// Static store for offscreen preview renders (no daemon).
    init(preview: Snapshot?) {
        snapshot = preview
        connected = preview != nil
        selectedID = preview?.blocks.first?.id
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var daemonNow: Date { Date().addingTimeInterval(clockSkew) }

    func status(_ id: UUID?) -> BlockStatus? {
        guard let id else { return nil }
        return snapshot?.blocks.first { $0.id == id }
    }

    func refresh() {
        Task.detached {
            let result = Result { try DaemonClient.send(Request(.snapshot), timeout: 3) }
            await MainActor.run {
                switch result {
                case .success(let r):
                    self.snapshot = r.snapshot
                    self.connected = true
                    if let n = r.now { self.clockSkew = n.timeIntervalSinceNow }
                    if self.selectedID == nil { self.selectedID = r.snapshot?.blocks.first?.id }
                case .failure:
                    self.connected = false
                }
            }
        }
    }

    /// Sends a command; shows a dialog on failure. `done` gets the response on success.
    func send(_ req: Request, success: String? = nil, done: ((Response) -> Void)? = nil) {
        busy = true
        Task.detached {
            let result = Result { try DaemonClient.send(req) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let r):
                    if let s = r.snapshot { self.snapshot = s }
                    if let success { self.dialog = Dialog(title: "OK!", message: success, color: Pixel.green) }
                    done?(r)
                case .failure(let e):
                    let text = "\(e)"
                    let locked = text.localizedCaseInsensitiveContains("locked")
                    self.dialog = Dialog(title: locked ? "LOCKED!" : "ERROR", message: text, color: locked ? Pixel.yellow : Pixel.red)
                }
            }
        }
    }
}
