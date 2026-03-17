import Foundation
import SwiftUI

@MainActor
final class ActivityPresentationModel: ObservableObject {
    @Published var analyzeProgress = 0.0
    @Published var analyzeStatusText = ""
    @Published var exportProgress = 0.0
    @Published var exportStatusText = "No export yet"
    @Published var uiMessage = "Ready"
    @Published var lastActivityState: ActivityState = .idle
    @Published var showActivityConsole = false
    @Published var activityConsoleText = ""

    var lastResultIconName: String {
        switch lastActivityState {
        case .idle:
            return "circle.dashed"
        case .running:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }

    var lastResultLabel: String {
        switch lastActivityState {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .success:
            return "Success"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}
