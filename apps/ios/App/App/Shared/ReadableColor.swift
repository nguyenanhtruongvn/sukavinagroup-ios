import Foundation

/// An sRGB colour (components 0...1) with the WCAG 2.x contrast maths used to
/// keep coloured text legible. Mirrors Android `Color.readableOn` in Theme.kt.
///
/// Status and brand hues such as the brand red, system green or orange are
/// only 2-4:1 on white, so text drawn in them directly was too faint even
/// though icons and fills in the same hue are fine.
struct SRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = SRGB(red: 0, green: 0, blue: 0)
    static let white = SRGB(red: 1, green: 1, blue: 1)

    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            let c = min(max(value, 0), 1)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static func contrast(_ a: SRGB, _ b: SRGB) -> Double {
        let x = a.relativeLuminance, y = b.relativeLuminance
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func mixed(with other: SRGB, fraction: Double) -> SRGB {
        SRGB(
            red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction
        )
    }

    /// This colour painted at `alpha` over `background` (a tinted pill).
    func composited(over background: SRGB, alpha: Double) -> SRGB {
        background.mixed(with: self, fraction: alpha)
    }

    /// The same hue moved toward black (light backgrounds) or white (dark
    /// backgrounds) just far enough to reach `minContrast` (AA text is 4.5:1).
    func readable(on background: SRGB, minContrast: Double = 4.5) -> SRGB {
        let target: SRGB = background.relativeLuminance > 0.179 ? .black : .white
        var result = self
        var step = 0
        while SRGB.contrast(result, background) < minContrast && step < 20 {
            step += 1
            result = mixed(with: target, fraction: Double(step) / 20)
        }
        return result
    }
}
