import Foundation

public func formatSeconds(_ value: Double) -> String {
    let whole = Int(value)
    let h = whole / 3600
    let m = (whole % 3600) / 60
    let s = whole % 60
    let ms = Int(((value - floor(value)) * 1000.0).rounded())
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}
