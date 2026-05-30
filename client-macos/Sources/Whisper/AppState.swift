import SwiftUI

/// The dictation state machine, observed by the menu bar, the HUD, and the windows.
enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case inserted
    case error(String)
}

final class AppState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var level: CGFloat = 0        // 0…1 mic level, drives the HUD waveform
    @Published var elapsed: TimeInterval = 0 // seconds since record start

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
}
