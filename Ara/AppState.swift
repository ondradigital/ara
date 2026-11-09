import AppKit
import SwiftUI
import AVFoundation
import KeyboardShortcuts
import Observation
import ServiceManagement
import os

enum DictationPhase: String {
    case idle
    case recording
    case transcribing

    var statusText: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        }
    }
}

enum ModelState: Equatable {
    case loading(fraction: Double)
    case ready
    case failed(String)
}

@Observable
final class AppState {
    private(set) var phase: DictationPhase = .idle {
        didSet {
            updateIndicator()
            // Escape is only taken over while a recording runs; otherwise it belongs to the focused app.
            if phase == .recording {
                KeyboardShortcuts.enable(.cancelDictation)
            } else {
                KeyboardShortcuts.disable(.cancelDictation)
            }
        }
    }
    private(set) var modelState: ModelState = .loading(fraction: 0)
    private(set) var lastTranscript: String?
    private(set) var lastError: String?

    var mutesOutputWhileRecording = UserDefaults.standard.object(forKey: "mutesOutputWhileRecording") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mutesOutputWhileRecording, forKey: "mutesOutputWhileRecording") }
    }

    var showsRecordingIndicator = UserDefaults.standard.object(forKey: "showsRecordingIndicator") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsRecordingIndicator, forKey: "showsRecordingIndicator")
            updateIndicator()
        }
    }

    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    let vocabulary = VocabularyStore()

    private let indicator = FloatingPanel(position: .bottom)
    private let proposalPanel = FloatingPanel(position: .top, isInteractive: true)
    /// Vocabulary changes waiting for the user's answer.
    private var pendingProposals: [VocabularyProposal] = [] {
        didSet { updateProposalPanel() }
    }
    private let meter = LevelMeter()
    private let recorder = AudioRecorder()
    private let muter = OutputMuter()
    private var correctionWatch: Task<Void, Never>?
    private let engine: any SpeechEngine = ParakeetEngine()
    private let logger = Logger(subsystem: "com.erikondra.Ara", category: "dictation")

    init() {
        // The global shortcut only fires on key down, so one press starts a
        // recording and the next press stops it; nothing has to be held.
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleDictation) {
                self?.toggle()
            }
        }
        KeyboardShortcuts.disable(.cancelDictation)
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .cancelDictation) {
                self?.cancelRecording()
            }
        }
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .learnSelection) {
                self?.learnFromSelection()
            }
        }
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .pasteLastTranscript) {
                self?.pasteLastTranscript()
            }
        }
        recorder.onLevels = { [meter] levels in
            Task { @MainActor in meter.append(levels) }
        }
        // Loaded once at launch and kept in memory, so no dictation pays the load time.
        Task { [weak self] in
            await self?.loadModel()
        }
        if !TextInserter.isTrusted {
            TextInserter.requestTrust()
        }
        muter.restoreAfterUncleanExit()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Could not change the login item: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Quits the app without leaving the output muted.
    func quit() {
        muter.restore()
        NSApplication.shared.terminate(nil)
    }

    /// Starts a recording, or stops the running one. A toggle while a
    /// transcription is still in flight is ignored.
    func toggle() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .transcribing: break
        }
    }

    /// Throws the running recording away without transcribing it.
    func cancelRecording() {
        guard phase == .recording else { return }
        _ = recorder.stop()
        muter.restore()
        phase = .idle
        logger.notice("recording cancelled")
    }

    private func loadModel() async {
        let started = ContinuousClock.now
        do {
            try await engine.prepare { [weak self] fraction in
                Task { @MainActor in
                    // A late progress callback must not undo `.ready`.
                    guard let self, case .loading = self.modelState else { return }
                    self.modelState = .loading(fraction: fraction)
                }
            }
            modelState = .ready
            logger.notice("speech model ready after \(ContinuousClock.now - started, privacy: .public)")
        } catch {
            modelState = .failed(error.localizedDescription)
            logger.error("speech model failed to load: \(error, privacy: .public)")
        }
    }

    private func startRecording() {
        guard modelState == .ready else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // The permission dialog interrupts the dictation anyway, so this
            // press only asks; the next one starts recording.
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            return
        default:
            lastError = "Microphone access is denied. Allow Ara in System Settings → Privacy & Security → Microphone."
            return
        }

        // Ends the watch on the previous dictation; what it saw so far still counts.
        correctionWatch?.cancel()

        do {
            let started = ContinuousClock.now
            meter.reset()
            try recorder.start()
            // Muted after the recorder is running, so it never delays the start.
            if mutesOutputWhileRecording {
                muter.mute()
            }
            lastError = nil
            phase = .recording
            logger.notice("recording running after \(ContinuousClock.now - started, privacy: .public)")
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            logger.error("recorder start failed: \(error, privacy: .public)")
        }
    }

    private func stopRecording() {
        let samples = recorder.stop()
        muter.restore()
        let seconds = Double(samples.count) / AudioRecorder.format.sampleRate

        guard seconds >= ParakeetEngine.minimumDuration else {
            phase = .idle
            return
        }

        phase = .transcribing
        Task {
            let started = ContinuousClock.now
            do {
                let text = vocabulary.apply(to: try await engine.transcribe(samples))
                let elapsed = ContinuousClock.now - started
                if !text.isEmpty {
                    // An empty result (nothing was said) must not replace the last real transcript in the menu.
                    lastTranscript = text
                    await insert(text)
                } else {
                    showNotice("Nothing recognized.", systemImage: "waveform.slash")
                }
                logger.notice("transcribed \(seconds, format: .fixed(precision: 1), privacy: .public) s of audio in \(elapsed, privacy: .public)")
            } catch {
                lastError = "Transcription failed: \(error.localizedDescription)"
                logger.error("transcription failed: \(error, privacy: .public)")
            }
            phase = .idle
        }
    }

    /// Pastes `text` into the focused field and tells the user when that may not have worked.
    private func insert(_ text: String) async {
        let outcome = await TextInserter.insert(text)
        logger.notice("insert outcome: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .pasted:
            watchForCorrections(of: text)
        case .pastedUnverified:
            watchForCorrections(of: text)
            showNotice("If nothing appeared, press ⌃⌥V to paste again.", systemImage: "doc.on.clipboard")
        case .pasteFailed:
            showNotice("Could not paste here. Click into the field and press ⌃⌥V.", systemImage: "doc.on.clipboard")
        case .noPermission:
            lastError = "Copied to the clipboard instead of pasting. Ara needs the Accessibility permission to paste."
        case .noTextField:
            showClipboardNotice()
        }
    }

    /// Pastes the last transcript again, for a field that did not take the first paste.
    func pasteLastTranscript() {
        guard let text = lastTranscript, phase == .idle else { return }
        Task { await insert(text) }
    }

    private let notice = FloatingPanel(position: .bottom)
    private var noticeHide: Task<Void, Never>?

    /// Tells the user that no text field was focused and the text waits on the clipboard.
    private func showClipboardNotice() {
        showNotice("No text field in focus. Text copied, press ⌘V to paste.", systemImage: "doc.on.clipboard")
    }

    private func showNotice(_ text: String, systemImage: String) {
        notice.show(NoticeView(text: text, systemImage: systemImage))
        noticeHide?.cancel()
        noticeHide = Task { [notice] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice.hide()
        }
    }

    private func updateIndicator() {
        if phase == .recording, showsRecordingIndicator {
            indicator.show(RecordingIndicatorView(meter: meter))
        } else {
            indicator.hide()
        }
    }

    /// The corrections already picked up while one dictation is being watched.
    private final class CorrectionSession {
        var known: [CorrectionDiff.Correction] = []
    }

    /// Watches how the user edits the text that was just inserted, and
    /// announces corrections that are about to go into the vocabulary.
    private func watchForCorrections(of inserted: String) {
        correctionWatch?.cancel()
        let session = CorrectionSession()
        // Names the app in the log, because only some apps let their text be read.
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        correctionWatch = Task {
            let final = await CorrectionWatcher.observe(inserted: inserted) { [weak self] edited in
                self?.proposeCorrections(inserted: inserted, edited: edited, session: session)
            }
            if final == nil {
                logger.notice("corrections: text field not readable in \(app, privacy: .public)")
            } else {
                logger.notice("corrections: watch ended in \(app, privacy: .public), \(session.known.count, privacy: .public) found")
            }
        }
    }

    private func proposeCorrections(inserted: String, edited: String, session: CorrectionSession) {
        enqueue(vocabulary.proposals(inserted: inserted, edited: edited, known: &session.known))
    }

    /// For apps whose text field cannot be watched: the user selects the word
    /// they corrected and presses the shortcut.
    func learnFromSelection() {
        guard let inserted = lastTranscript else { return }
        Task {
            guard let selection = await TextInserter.copySelection(),
                let correction = CorrectionDiff.correction(forSelection: selection, in: inserted)
            else {
                showNotice("Select the corrected word in the text first.", systemImage: "text.cursor")
                noticeHide?.cancel()
                noticeHide = Task { [notice] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    notice.hide()
                }
                return
            }
            enqueue(vocabulary.proposals(for: correction))
        }
    }

    /// Shows the proposals and applies each one when its countdown ends,
    /// unless the user has cancelled it by then.
    private func enqueue(_ proposals: [VocabularyProposal]) {
        // The same change may already be waiting from an earlier dictation.
        let new = proposals.filter { proposal in
            !pendingProposals.contains {
                $0.kind == proposal.kind && $0.heard == proposal.heard && $0.replacement == proposal.replacement
            }
        }
        pendingProposals += new

        for proposal in new {
            Task {
                try? await Task.sleep(for: .seconds(proposal.deadline.timeIntervalSinceNow))
                // Cancelled proposals are gone from the list by now.
                guard pendingProposals.contains(where: { $0.id == proposal.id }) else { return }
                vocabulary.accept(proposal)
                pendingProposals.removeAll { $0.id == proposal.id }
            }
        }
    }

    private func updateProposalPanel() {
        guard !pendingProposals.isEmpty else {
            proposalPanel.hide()
            return
        }
        proposalPanel.show(
            VocabularyProposalView(
                proposals: pendingProposals,
                onCancel: { [weak self] proposal in
                    self?.pendingProposals.removeAll { $0.id == proposal.id }
                }
            )
        )
    }
}
