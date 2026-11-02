import AppKit
import SwiftUI

Pixel.registerFont()

if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { IconRenderer.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
} else if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { PreviewRender.run(to: CommandLine.arguments[i + 1]) }
    exit(0)
} else if CommandLine.arguments.contains("--agent") {
    let app = NSApplication.shared
    let agent = MainActor.assumeIsolated { Agent() }
    app.delegate = agent
    app.run()
} else {
    LockDownApp.main()
}

struct LockDownApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("LockDown") {
            ContentView().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Writes an .iconset of the padlock logo for the build script to turn into AppIcon.icns.
enum IconRenderer {
    @MainActor
    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                             (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
            let s = CGFloat(size)
            let view = ZStack {
                PixelRect(step: s / 16).fill(Pixel.bg)
                PixelRect(step: s / 16).stroke(Pixel.yellow, lineWidth: max(1, s / 32)).padding(s / 64)
                Logo(pixel: (s * 0.6 / 16).rounded(.down))
            }
            .frame(width: s, height: s)
            let r = ImageRenderer(content: view)
            r.scale = 1
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }
}
