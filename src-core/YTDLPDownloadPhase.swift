import Foundation

public enum YTDLPDownloadPhase: String, CaseIterable, Sendable {
    case loadingCookies
    case connecting
    case fetchingMetadata
    case solvingChallenge
    case selectingFormat
    case downloading

    public var statusText: String {
        switch self {
        case .loadingCookies:
            return "Reading browser cookies…"
        case .connecting:
            return "Connecting to media source…"
        case .fetchingMetadata:
            return "Reading media information…"
        case .solvingChallenge:
            return "Preparing YouTube playback…"
        case .selectingFormat:
            return "Selecting media format…"
        case .downloading:
            return "Starting media download…"
        }
    }

    public var timingLabel: String {
        switch self {
        case .loadingCookies: return "browser cookie extraction"
        case .connecting: return "source connection"
        case .fetchingMetadata: return "metadata extraction"
        case .solvingChallenge: return "JavaScript challenge"
        case .selectingFormat: return "format selection"
        case .downloading: return "media transfer"
        }
    }

    public static func detect(in rawLine: String) -> YTDLPDownloadPhase? {
        let line = rawLine.lowercased()

        if line.contains("extracting cookies from") ||
            (line.contains("extracted") && line.contains("cookies from")) {
            return .loadingCookies
        }
        if line.contains("solving js challenge") ||
            line.contains("challenge solver") ||
            line.contains("[jsc:") {
            return .solvingChallenge
        }
        if line.contains("extracting url") {
            return .connecting
        }
        if line.contains("downloading webpage") ||
            line.contains("downloading initial data api json") ||
            (line.contains("downloading") && line.contains("player api json")) ||
            line.contains("downloading player ") ||
            line.contains("extracting formats") {
            return .fetchingMetadata
        }
        if line.contains("[info]") && line.contains("downloading") && line.contains("format") {
            return .selectingFormat
        }
        if line.hasPrefix("download:") || line.contains("[download] destination:") {
            return .downloading
        }
        return nil
    }
}
