import SwiftUI

@main
struct AraApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            switch appState.phase {
            case .idle: Image("MenuBarIcon")
            case .recording: Image(systemName: "waveform")
            case .transcribing: Image(systemName: "ellipsis")
            }
        }

        Window("Personal Vocabulary", id: "vocabulary") {
            VocabularyView(store: appState.vocabulary)
        }
        // Only opened from the menu, never at launch.
        .defaultLaunchBehavior(.suppressed)
    }
}
