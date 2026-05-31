import SwiftUI

/// The dictation state machine, observed by the menu bar, the HUD, and the windows.
enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case inserted
    case copied        // transcript on the clipboard; no editable field was focused (Scenario 1)
    case error(String)
}

final class AppState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var level: CGFloat = 0        // 0…1 mic level, drives the HUD waveform
    @Published var elapsed: TimeInterval = 0 // seconds since record start

    // Surfaced in the HUD + menu for robustness.
    @Published var serverStatus: ServerStatus = .unknown
    @Published var pendingCount: Int = 0
    @Published var lastTranscript: String = "" // for "Paste last transcript"
    @Published var hudHovering = false         // drives the HUD compact ↔ expanded layout

    let settings: Settings
    let history: HistoryStore

    init(settings: Settings, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    var isBusy: Bool {
        switch phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    /// HUD shows its full form while active or when the user hovers the idle pill.
    var hudExpanded: Bool {
        switch phase {
        case .idle: return hudHovering
        default: return true
        }
    }
}
