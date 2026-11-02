import Foundation
import LockDownCore

// Client mode used by uninstall.sh: exit 0 if no block is locked.
if CommandLine.arguments.contains("--can-uninstall") {
    guard let r = try? DaemonClient.send(Request(.canUninstall)) else {
        print("daemon not reachable; nothing is being enforced")
        exit(0)
    }
    if r.allowed == true { exit(0) }
    print("A block is locked. LockDown can't be uninstalled until it ends or is unlocked.")
    exit(1)
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("lockdownd must run as root (it's started by launchd).\n".utf8))
    exit(1)
}

setvbuf(stderr, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let daemon = Daemon()
daemon.start()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

Log.info("started (boot \(daemon.bootID))")
dispatchMain()
