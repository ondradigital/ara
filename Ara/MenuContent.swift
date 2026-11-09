import KeyboardShortcuts
import SwiftUI

struct MenuContent: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private var statusText: String {
        switch appState.modelState {
        case .loading(let fraction) where fraction > 0 && fraction < 1:
            "Downloading speech model… \(Int(fraction * 100)) %"
        case .loading:
            "Preparing speech model…"
        case .failed(let message):
            "Speech model failed to load: \(message)"
        case .ready:
            appState.phase.statusText
        }
    }

    var body: some View {
        Text(statusText)

        if let error = appState.lastError {
            Text(error)
        }

        if !TextInserter.isTrusted {
            Button("Allow Pasting in Accessibility Settings…") {
                TextInserter.openAccessibilitySettings()
            }
        }

        Button(appState.phase == .recording ? "Stop Recording" : "Start Recording") {
            appState.toggle()
        }
        .globalKeyboardShortcut(.toggleDictation)
        .disabled(appState.phase == .transcribing || appState.modelState != .ready)

        if appState.phase == .recording {
            Button("Cancel Recording") {
                appState.cancelRecording()
            }
            .globalKeyboardShortcut(.cancelDictation)
        }

        if appState.lastTranscript != nil {
            Button("Add Selected Word to Vocabulary") {
                appState.learnFromSelection()
            }
            .globalKeyboardShortcut(.learnSelection)
        }

        if let transcript = appState.lastTranscript {
            Divider()
            Text(transcript)
            Button("Paste Last Transcript") {
                appState.pasteLastTranscript()
            }
            .globalKeyboardShortcut(.pasteLastTranscript)
            Button("Copy Last Transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript, forType: .string)
            }
        }

        Divider()

        Button("Personal Vocabulary…") {
            openWindow(id: "vocabulary")
            // A menu bar app is not frontmost, so its window would open behind others.
            NSApplication.shared.activate()
        }

        Toggle("Mute Other Audio While Recording", isOn: $appState.mutesOutputWhileRecording)
        Toggle("Show Recording Indicator", isOn: $appState.showsRecordingIndicator)
        Toggle(
            "Launch at Login",
            isOn: Binding(get: { appState.launchesAtLogin }, set: { appState.setLaunchesAtLogin($0) })
        )

        Divider()

        Button("Quit Ara") {
            appState.quit()
        }
        .keyboardShortcut("q")
    }
}
