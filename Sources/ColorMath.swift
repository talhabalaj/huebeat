import Foundation

/// The Tuya TS0505B bulbs ignore hue/saturation commands and stay white, but follow CIE xy, so colors go out as xy.
enum ColorMath {
    struct XY: Equatable {
        let x: Double
        let y: Double
    }

    /// `hue` in degrees, `saturation` 0...1. Brightness is sent separately as a Zigbee level.
    static func xy(hue: Double, saturation: Double) -> XY {
        let (r, g, b) = rgb(hue: hue, saturation: saturation)
        return xy(red: r, green: g, blue: b)
    }

    /// sRGB components 0...1.
    static func xy(red r: Double, green g: Double, blue b: Double) -> XY {
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        // sRGB (D65) to CIE XYZ
        let x = 0.4124 * lr + 0.3576 * lg + 0.1805 * lb
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = 0.0193 * lr + 0.1192 * lg + 0.9505 * lb
        let sum = x + y + z
        guard sum > 0 else { return XY(x: 0.3127, y: 0.3290) }
        return XY(x: x / sum, y: y / sum)
    }

    /// Value 0...1000 to a Zigbee level, kept above a floor so beats never black the room out.
    static func level(value: Int, floor: Int = 40) -> Int {
        let scaled = Double(max(0, min(value, 1000))) / 1000 * 254
        return max(floor, min(254, Int(scaled.rounded())))
    }

    /// Slider brightness 0...1 to a Zigbee level (1...254).
    static func level(brightness: Double) -> Int {
        max(1, min(254, Int((brightness * 254).rounded())))
    }

    private static func rgb(hue: Double, saturation: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = max(0, min(saturation, 1))
        let c = s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = 1 - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
