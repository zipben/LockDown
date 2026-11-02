import SwiftUI

/// Tiny sprites drawn from character grids. Each character maps to a palette color; "." is transparent.
struct Sprite: View {
    let rows: [String]
    let palette: [Character: Color]
    var scale: CGFloat = 3

    var body: some View {
        let w = rows.map(\.count).max() ?? 0
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)), with: .color(c))
                }
            }
        }
        .frame(width: CGFloat(w) * scale, height: CGFloat(rows.count) * scale)
        .accessibilityHidden(true)
    }
}

enum Sprites {
    static let k = Pixel.edge

    static func lock(_ scale: CGFloat = 3, color: Color = Pixel.yellow) -> Sprite {
        Sprite(rows: [
            "..kkkk..",
            ".k....k.",
            ".k....k.",
            "kkkkkkkk",
            "kyyyyyyk",
            "kyyKKyyk",
            "kyyKKyyk",
            "kyyyyyyk",
            "kkkkkkkk",
        ], palette: ["k": k, "y": color, "K": k], scale: scale)
    }

    static func unlock(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "..kkkk..",
            ".k....k.",
            ".k......",
            "kkkkkkkk",
            "kggggggk",
            "kggKKggk",
            "kggKKggk",
            "kggggggk",
            "kkkkkkkk",
        ], palette: ["k": k, "g": Pixel.green, "K": k], scale: scale)
    }

    static func heart(_ scale: CGFloat = 3, color: Color = Pixel.red) -> Sprite {
        Sprite(rows: [
            ".kk.kk.",
            "krrkrrk",
            "krrrrrk",
            "krrrrrk",
            ".krrrk.",
            "..krk..",
            "...k...",
        ], palette: ["k": k, "r": color], scale: scale)
    }

    static func snowflake(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "....i....",
            ".i..i..i.",
            "..i.i.i..",
            "...iii...",
            "iiiiIiiii",
            "...iii...",
            "..i.i.i..",
            ".i..i..i.",
            "....i....",
        ], palette: ["i": Pixel.ice, "I": .white], scale: scale)
    }

    static func globe(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "..kkkk..",
            ".kccgck.",
            "kcggcggk",
            "kcgccgck",
            "kccgcgck",
            "kcggccgk",
            ".kcgggk.",
            "..kkkk..",
        ], palette: ["k": k, "c": Pixel.cyan, "g": Pixel.green], scale: scale)
    }

    static func joystick(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "...rr...",
            "..rrrr..",
            "...rr...",
            "...kk...",
            "...kk...",
            "kkkkkkkk",
            "kmmmmmmk",
            "kkkkkkkk",
        ], palette: ["k": k, "r": Pixel.red, "m": Pixel.magenta], scale: scale)
    }

    static func clock(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "..kkkk..",
            ".kwwkwk.",
            "kwwwkwwk",
            "kwwwkwwk",
            "kwwwkkwk",
            "kwwwwwwk",
            ".kwwwwk.",
            "..kkkk..",
        ], palette: ["k": k, "w": Pixel.ink], scale: scale)
    }

    static func trophy(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "kkkkkkkk",
            "kyyyyyyk",
            "yyyyyyyy",
            "kyyyyyyk",
            ".kyyyyk.",
            "..kyyk..",
            "...yy...",
            ".kkkkkk.",
        ], palette: ["k": k, "y": Pixel.yellow], scale: scale)
    }

    static func gear(_ scale: CGFloat = 3) -> Sprite {
        Sprite(rows: [
            "...ww...",
            ".w.ww.w.",
            "..wwww..",
            "wwwkkwww",
            "wwwkkwww",
            "..wwww..",
            ".w.ww.w.",
            "...ww...",
        ], palette: ["w": Pixel.inkDim, "k": Pixel.bg], scale: scale)
    }

    /// LockDown's mascot: a little padlock robot with an antenna. Original design.
    static func mascot(_ scale: CGFloat = 4) -> Sprite {
        Sprite(rows: [
            ".....r.....",
            ".....k.....",
            "...kkkkk...",
            "..k.....k..",
            "..k.....k..",
            ".kkkkkkkkk.",
            ".kyyyyyyyk.",
            ".kyWkykWyk.",
            ".kyyyyyyyk.",
            ".kyykkkyyk.",
            ".kyyyyyyyk.",
            ".kkkkkkkkk.",
            "..kk...kk..",
        ], palette: ["k": k, "y": Pixel.yellow, "W": .white, "r": Pixel.red], scale: scale)
    }
}
