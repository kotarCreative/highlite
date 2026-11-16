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
    private var cancellables: Set<AnyCancellable> = []
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            let image = NSImage(
                systemSymbolName: "sparkles",
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
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateChrome()
    }

    private func updateChrome() {
        let pending = model.pendingCount
        if let button = statusItem?.button {
            button.title = pending > 0 ? " \(min(pending, 99))" : ""
            button.toolTip = pending > 0
                ? "Highlite — \(pending) pending OpenCode suggestion\(pending == 1 ? "" : "s")"
                : "Highlite"
        }
        statusMenuItem?.title = statusText()
        pendingMenuItem?.title = pending > 0
            ? "Review \(pending) pending suggestion\(pending == 1 ? "" : "s")…"
            : "No pending suggestions"
        pendingMenuItem?.isEnabled = pending > 0
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

    private func showDashboard() {
        if dashboardWindow == nil {
            let hosting = NSHostingController(rootView: DashboardView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Highlite"
            window.contentViewController = hosting
            window.minSize = NSSize(width: 840, height: 620)
            window.isReleasedWhenClosed = false
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

        let hosting = NSHostingController(rootView: ReviewView(model: model, request: request))
        if let window = reviewWindow {
            window.title = "Confirm OpenCode send"
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 820, height: 700))
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Confirm OpenCode send"
            window.contentViewController = hosting
            window.minSize = NSSize(width: 720, height: 580)
            window.isReleasedWhenClosed = false
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
        } else if window === dashboardWindow {
            dashboardWindow = nil
        }
    }
}
