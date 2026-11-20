import AppKit
import Combine
import SwiftUI
import HighliteMenuBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var pendingMenuItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var dashboardWindow: NSWindow?
    private var reviewWindow: NSWindow?
    private var captureWindow: NSWindow?
    private var captureMenuItem: NSMenuItem?
    private var recordingSetupWindow: NSWindow?
    private var recordingReviewWindow: NSWindow?
    private var recordingDraft: NativeRecordingDraft?
    private let recordingController = NativeRecordingController()
    private let liveAnnotations = NativeLiveAnnotationSession()
    private var recordMenuItem: NSMenuItem?
    private var stopRecordingMenuItem: NSMenuItem?
    private var isCapturingStill = false
    private var cancellables: Set<AnyCancellable> = []
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A prior process may have crashed or been force-quit while recording.
        // Launch is the single-instance boundary, so every leftover workspace
        // is safe to remove before this process can start a new recording.
        NativeRecordingTempStore.cleanupStale(olderThan: 0)
        NSApp.mainMenu = AppMenu.makeMainMenu()
        configureStatusItem()
        observeModel()
        showDashboard()
        Task { await model.bootstrap() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !terminationInProgress else { return false }
        showDashboard()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationInProgress {
            return .terminateLater
        }
        terminationInProgress = true
        Task {
            recordingDraft?.discard()
            recordingDraft = nil
            liveAnnotations.cancel()
            await recordingController.shutdown()
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status item

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Match the highlighter app icon in the menu bar. Keep a pencil
            // fallback for older symbol sets instead of leaving a blank item.
            let image = NSImage(
                systemSymbolName: "highlighter",
                accessibilityDescription: "Highlite"
            ) ?? NSImage(
                systemSymbolName: "pencil.tip",
                accessibilityDescription: "Highlite"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "Highlite"
        }

        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "Relay stopped", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        let pending = NSMenuItem(
            title: "No pending suggestions",
            action: #selector(reviewNextPending),
            keyEquivalent: ""
        )
        pending.target = self
        menu.addItem(pending)
        pendingMenuItem = pending

        menu.addItem(.separator())

        let dashboard = NSMenuItem(
            title: "Open Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: "d"
        )
        dashboard.target = self
        dashboard.keyEquivalentModifierMask = [.command]
        menu.addItem(dashboard)

        let capture = NSMenuItem(
            title: "Capture Screen…",
            action: #selector(captureScreen),
            keyEquivalent: ""
        )
        capture.target = self
        menu.addItem(capture)
        captureMenuItem = capture

        let record = NSMenuItem(
            title: "Record Screen…",
            action: #selector(recordScreen),
            keyEquivalent: ""
        )
        record.target = self
        menu.addItem(record)
        recordMenuItem = record

        let stopRecording = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecording),
            keyEquivalent: ""
        )
        stopRecording.target = self
        stopRecording.isHidden = true
        menu.addItem(stopRecording)
        stopRecordingMenuItem = stopRecording

        let startStop = NSMenuItem(
            title: "Start Relay",
            action: #selector(toggleRelay),
            keyEquivalent: "r"
        )
        startStop.target = self
        startStop.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(startStop)
        startStopMenuItem = startStop

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Highlite",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        updateChrome()
    }

    private func observeModel() {
        model.$relay
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateChrome() }
            }
            .store(in: &cancellables)
        model.$pendingCount
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateChrome() }
            }
            .store(in: &cancellables)
        model.$reviewRequest
            .sink { [weak self] request in
                Task { @MainActor in
                    guard let self else { return }
                    if let request {
                        self.showReview(request)
                    } else {
                        self.closeReviewWindow()
                    }
                }
            }
            .store(in: &cancellables)
        recordingController.$phase
            .sink { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    if case .recording = phase {
                        // Keep the live bar and drawing surface on screen.
                    } else {
                        self.liveAnnotations.pauseForStop()
                    }
                    self.updateChrome()
                }
            }
            .store(in: &cancellables)
        recordingController.$completedOutput
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          let output = self.recordingController.consumeCompletedOutput()
                    else {
                        return
                    }
                    self.presentCompletedRecording(output)
                }
            }
            .store(in: &cancellables)
        recordingController.$failureMessage
            .sink { [weak self] message in
                Task { @MainActor in
                    guard let self, let message else { return }
                    self.model.errorMessage = "Screen recording stopped: \(message)"
                    self.recordingController.clearFailureMessage()
                }
            }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateChrome()
    }

    private func updateChrome() {
        let pending = model.pendingCount
        switch recordingController.phase {
        case .recording(_, let includeMicrophone):
            setStatusTitle("● REC", color: .systemRed)
            statusItem?.button?.toolTip = includeMicrophone
                ? "Highlite — recording screen and microphone. Choose Stop Recording to review."
                : "Highlite — recording screen. Choose Stop Recording to review."
            statusItem?.button?.setAccessibilityLabel("Highlite is recording the screen")
        case .stopping:
            setStatusTitle("● REC", color: .systemRed)
            statusItem?.button?.toolTip = "Highlite — stopping and finalizing the recording."
            statusItem?.button?.setAccessibilityLabel("Highlite is stopping the screen recording")
        case .choosing:
            setStatusTitle("◉", color: .controlAccentColor)
            statusItem?.button?.toolTip = "Highlite — choose one window or display to record."
            statusItem?.button?.setAccessibilityLabel("Highlite is waiting for a screen choice")
        case .idle, .reviewing:
            setStatusTitle(pending > 0 ? " \(min(pending, 99))" : "")
            statusItem?.button?.toolTip = pending > 0
                ? "Highlite — \(pending) pending OpenCode suggestion\(pending == 1 ? "" : "s")"
                : "Highlite"
            statusItem?.button?.setAccessibilityLabel("Highlite")
        }

        statusMenuItem?.title = statusText()
        pendingMenuItem?.title = pending > 0
            ? "Review \(pending) pending suggestion\(pending == 1 ? "" : "s")…"
            : "No pending suggestions"
        pendingMenuItem?.isEnabled = pending > 0

        let relayReady = model.relay.isRunning && model.ingestToken != nil
        let captureFlowOpen = captureWindow != nil
            || recordingSetupWindow != nil
            || recordingReviewWindow != nil
            || isCapturingStill
        captureMenuItem?.isEnabled = relayReady
            && !captureFlowOpen
            && recordingController.phase == .idle
        recordMenuItem?.isEnabled = relayReady
            && !captureFlowOpen
            && recordingController.phase == .idle
            && NativeRecordingAvailability.isSupported
        stopRecordingMenuItem?.isHidden = !recordingController.isRecording
        stopRecordingMenuItem?.isEnabled = recordingController.isRecording
        switch model.relay.phase {
        case .running:
            startStopMenuItem?.title = model.relay.owned ? "Stop Relay" : "Detach from Relay"
            startStopMenuItem?.isEnabled = true
        case .checking, .starting:
            startStopMenuItem?.title = "Cancel Relay Start"
            startStopMenuItem?.isEnabled = true
        case .stopping:
            startStopMenuItem?.title = "Stopping Relay…"
            startStopMenuItem?.isEnabled = false
        case .stopped, .failed:
            startStopMenuItem?.title = "Start Relay"
            startStopMenuItem?.isEnabled = true
        }
    }

    private func setStatusTitle(_ text: String, color: NSColor = .labelColor) {
        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .semibold
        )
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private func statusText() -> String {
        switch model.relay.phase {
        case .running:
            let owner = model.relay.owned ? "managed" : "external"
            let version = model.relay.relayVersion.map { ", v\($0)" } ?? ""
            return "Relay running (\(owner))\(version) — \(model.relay.baseURL.host ?? "127.0.0.1"):\(model.relay.baseURL.port ?? 0)"
        case .failed:
            return "Relay failed — open Dashboard"
        case .checking:
            return "Checking relay..."
        case .starting:
            return "Starting relay..."
        case .stopping:
            return "Stopping relay..."
        case .stopped:
            return "Relay stopped"
        }
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        showDashboard()
    }

    @objc private func openSettings() {
        model.dashboardSection = .settings
        showDashboard()
    }

    @objc private func toggleRelay() {
        Task {
            switch model.relay.phase {
            case .running, .checking, .starting:
                await model.stopRelay()
            case .stopped, .failed:
                await model.startRelay()
            case .stopping:
                break
            }
        }
    }

    @objc private func reviewNextPending() {
        Task {
            await model.reviewNextPending()
        }
    }

    @objc private func captureScreen() {
        Task { await beginCapture() }
    }

    @objc private func recordScreen() {
        Task { await beginRecordingSetup() }
    }

    @objc private func stopRecording() {
        Task { await stopRecordingNow() }
    }

    private func beginCapture() async {
        if let window = captureWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard recordingController.phase == .idle,
              recordingSetupWindow == nil,
              recordingReviewWindow == nil
        else {
            model.setNotice("Finish the current recording flow before capturing a still.")
            return
        }
        guard !isCapturingStill else { return }
        guard model.relay.isRunning else {
            model.setNotice("Start the Highlite relay before capturing a screen region.")
            return
        }
        guard model.ingestToken != nil else {
            model.setNotice(
                "The relay ingest token is unavailable. Check the relay settings and try again."
            )
            return
        }
        isCapturingStill = true
        updateChrome()
        defer {
            isCapturingStill = false
            updateChrome()
        }
        do {
            let png = try await NativeCaptureService().captureInteractive()
            let draft = try NativeCaptureDraft(pngData: png)
            showCapture(draft)
        } catch let error as NativeCaptureCommandError {
            if case .cancelled = error {
                model.setNotice(error.localizedDescription)
            } else {
                model.errorMessage = error.localizedDescription
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func showCapture(_ draft: NativeCaptureDraft) {
        let window = AppWindowFactory.makeCaptureWindow(
            draft: draft,
            onSave: { [model = model] bundle in
                try await model.saveNativeCapture(bundle)
            },
            onClose: { [weak self] in
                self?.closeCaptureWindow()
            }
        )
        window.delegate = self
        window.center()
        captureWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeCaptureWindow() {
        guard let window = captureWindow else { return }
        captureWindow = nil
        window.delegate = nil
        window.close()
        updateChrome()
    }

    // MARK: - Screen recording

    private func beginRecordingSetup() async {
        if let window = recordingSetupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard NativeRecordingAvailability.isSupported else {
            model.setNotice("Screen recording requires macOS 15 or newer. Still capture is still available.")
            return
        }
        guard recordingController.phase == .idle else {
            model.setNotice(
                recordingController.isRecording
                    ? "Stop the current recording before starting another."
                    : "Finish the current recording flow before starting another."
            )
            return
        }
        guard captureWindow == nil, !isCapturingStill else {
            model.setNotice("Finish the current screen capture before recording.")
            return
        }
        guard model.relay.isRunning else {
            model.setNotice("Start the Highlite relay before recording the screen.")
            return
        }
        guard model.ingestToken != nil else {
            model.setNotice(
                "The relay ingest token is unavailable. Check the relay settings and try again."
            )
            return
        }
        showRecordingSetup()
    }

    private func showRecordingSetup() {
        let window = AppWindowFactory.makeRecordingSetupWindow(
            onStart: { [weak self] includeMicrophone in
                guard let self else { return }
                self.closeRecordingSetupWindow()
                Task { await self.startRecording(includeMicrophone: includeMicrophone) }
            },
            onCancel: { [weak self] in
                self?.closeRecordingSetupWindow()
            }
        )
        window.delegate = self
        window.center()
        recordingSetupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateChrome()
    }

    private func closeRecordingSetupWindow() {
        guard let window = recordingSetupWindow else { return }
        recordingSetupWindow = nil
        window.delegate = nil
        window.close()
        updateChrome()
    }

    private func startRecording(includeMicrophone: Bool) async {
        do {
            try await recordingController.start(includeMicrophone: includeMicrophone)
            if case .recording(let startedAt, _) = recordingController.phase {
                liveAnnotations.begin(
                    recordingStartedAt: startedAt,
                    captureArea: recordingController.captureArea,
                    onStop: { [weak self] in
                        Task { @MainActor in
                            await self?.stopRecordingNow()
                        }
                    }
                )
            }
            model.setNotice(nil)
        } catch {
            liveAnnotations.cancel()
            model.setNotice("Screen recording did not start: \(error.localizedDescription)")
        }
        updateChrome()
    }

    private func stopRecordingNow() async {
        guard recordingController.isRecording else { return }
        liveAnnotations.pauseForStop()
        do {
            // Presentation is driven by the controller's completedOutput.
            _ = try await recordingController.stop()
        } catch {
            model.errorMessage = "The recording could not be finalized: \(error.localizedDescription)"
        }
        updateChrome()
    }

    private func presentCompletedRecording(_ output: NativeRecordingOutput) {
        let liveStrokes = liveAnnotations.finish()
        do {
            let draft = try NativeRecordingDraft(output: output)
            showRecordingReview(draft)
            if !liveStrokes.isEmpty {
                Task { @MainActor [weak self] in
                    await draft.importLiveAnnotations(liveStrokes)
                    self?.updateChrome()
                }
            }
        } catch {
            NativeRecordingTempStore.remove(output.directory)
            recordingController.finishReview()
            model.errorMessage = "The recording could not be reviewed: \(error.localizedDescription)"
        }
        updateChrome()
    }

    private func showRecordingReview(_ draft: NativeRecordingDraft) {
        let window = AppWindowFactory.makeRecordingReviewWindow(
            draft: draft,
            onSave: { [model = model] bundle in
                try await model.saveNativeRecording(bundle)
            },
            onClose: { [weak self] in
                self?.closeRecordingReviewWindow()
            }
        )
        window.delegate = self
        window.center()
        recordingDraft = draft
        recordingReviewWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateChrome()
    }

    private func closeRecordingReviewWindow() {
        let draft = recordingDraft
        let window = recordingReviewWindow
        recordingDraft = nil
        recordingReviewWindow = nil

        // Stop playback before AppKit tears the AVKit view down, then release
        // the player and its time observer on the next main-actor turn. Doing
        // that inside `windowWillClose` mutates the player while SwiftUI is
        // still dismantling the view that owns it.
        draft?.pause()
        window?.delegate = nil
        window?.close()
        recordingController.finishReview()
        updateChrome()

        if let draft {
            Task { @MainActor in
                draft.discard()
            }
        }
    }

    private func showDashboard() {
        if dashboardWindow == nil {
            let window = AppWindowFactory.makeDashboardWindow(model: model)
            window.delegate = self
            window.center()
            dashboardWindow = window
        }
        dashboardWindow?.deminiaturize(nil)
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showReview(_ request: ReviewRequest) {
        if dashboardWindow != nil {
            model.dashboardSection = .sessions
            Task { await model.selectSession(request.sessionId) }
        }

        if let window = reviewWindow {
            window.title = "Confirm OpenCode send"
            AppWindowFactory.attachReview(request, model: model, to: window)
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = AppWindowFactory.makeReviewWindow(model: model, request: request)
            window.delegate = self
            window.center()
            reviewWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeReviewWindow() {
        guard let window = reviewWindow else { return }
        reviewWindow = nil
        window.delegate = nil
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === reviewWindow {
            let suppressed = terminationInProgress
            reviewWindow = nil
            if !suppressed {
                model.deferCurrentReview()
            }
        } else if window === captureWindow {
            captureWindow = nil
            updateChrome()
        } else if window === recordingSetupWindow {
            recordingSetupWindow = nil
            updateChrome()
        } else if window === recordingReviewWindow {
            let draft = recordingDraft
            recordingReviewWindow = nil
            recordingDraft = nil
            draft?.pause()
            recordingController.finishReview()
            updateChrome()
            if let draft {
                // The window is still closing while this delegate method runs.
                // Release the AVPlayer and delete its files only after AppKit
                // has finished dismantling the AVKit view.
                Task { @MainActor in
                    draft.discard()
                }
            }
        } else if window === dashboardWindow {
            dashboardWindow = nil
        }
    }
}
