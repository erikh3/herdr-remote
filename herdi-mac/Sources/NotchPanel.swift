import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.herdr.herdi", category: "Panel")

// MARK: - Keyable Panel (nonactivatingPanel that can become key for interactions)

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// NSHostingView subclass that avoids AppKit constraint-update re-entrancy crash
/// and ensures first click fires SwiftUI actions instead of being consumed for activation.
private class NotchHostingView<Content: View>: NSHostingView<Content> {
    private var applyingDeferred = false

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applySuperNeedsUpdateConstraints(_ value: Bool) {
        super.needsUpdateConstraints = value
    }

    private func applySuperNeedsLayout(_ value: Bool) {
        super.needsLayout = value
    }

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred {
                applySuperNeedsUpdateConstraints(newValue)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyingDeferred = true
                self.applySuperNeedsUpdateConstraints(newValue)
                self.applyingDeferred = false
            }
        }
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred {
                applySuperNeedsLayout(newValue)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyingDeferred = true
                self.applySuperNeedsLayout(newValue)
                self.applyingDeferred = false
            }
        }
    }
}

// MARK: - Screen Detection

enum ScreenDetector {
    /// Detect whether a screen has a physical notch (macOS 12+)
    static func hasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
        }
        return false
    }

    /// Get the notch/menu bar height for a screen
    static func topBarHeight(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let inset = screen.safeAreaInsets.top
            if inset > 0 { return inset }
        }
        // Menu bar height
        let menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBarH > 5 ? menuBarH : 25
    }

    /// Get the notch width (or simulated width for non-notch screens)
    static func notchWidth(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightW = screen.auxiliaryTopRightArea?.width ?? 0
            if leftW > 0 || rightW > 0 {
                return screen.frame.width - leftW - rightW
            }
        }
        // Simulated notch width for external displays
        return min(max(screen.frame.width * 0.14, 160), 240)
    }

    /// Preferred screen: notch screen first, then main
    static var preferredScreen: NSScreen {
        if let notchScreen = NSScreen.screens.first(where: { hasNotch($0) }) {
            return notchScreen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}

// MARK: - Panel Window Controller

@MainActor
final class PanelWindowController: NSObject, NSWindowDelegate, ObservableObject {
    private var panel: KeyablePanel?
    private var hostingView: NotchHostingView<NotchPanelView>?
    private let relay: RelayConnection
    @Published var surface: IslandSurface = .collapsed
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var fullscreenLatch = false

    /// Prompt keys the user explicitly minimized. Suppresses auto-pop until the
    /// user hovers Herdi (re-arm) or the prompt changes (new key).
    private var dismissedKeys: Set<String> = []

    init(relay: RelayConnection) {
        self.relay = relay
        super.init()
    }

    /// Stable per-prompt key. `promptId` changes when the question changes, so a
    /// new prompt for the same agent produces a fresh key and re-pops.
    static func promptKey(agentId: String, promptId: String?) -> String {
        "\(agentId)|\(promptId ?? "")"
    }

    /// User minimized this prompt via the chevron; suppress auto-pop for its key.
    func dismissPrompt(agentId: String, promptId: String?) {
        dismissedKeys.insert(Self.promptKey(agentId: agentId, promptId: promptId))
    }

    /// True when the user has minimized this exact prompt and it should stay hidden.
    func isPromptDismissed(agentId: String, promptId: String?) -> Bool {
        dismissedKeys.contains(Self.promptKey(agentId: agentId, promptId: promptId))
    }

    /// Re-arm auto-pop for every prompt (called when the user hovers Herdi).
    func rearmDismissed() {
        dismissedKeys.removeAll()
    }

    /// Drop dismissal keys that no longer correspond to a live blocked prompt so
    /// the set can't grow without bound.
    func pruneDismissed(liveKeys: Set<String>) {
        dismissedKeys.formIntersection(liveKeys)
    }

    func showPanel() {
        let screen = ScreenDetector.preferredScreen
        let size = panelSize(for: screen)

        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        // Above menu bar but below alerts
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = contentView
        panel.delegate = self

        self.panel = panel
        updatePosition()
        panel.orderFrontRegardless()

        // Screen change observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        }

        // Fullscreen space detection
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSpaceChange() }
        }

        // Global click: collapse expanded panel when clicking outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.surface.isExpanded else { return }
                // Approval: minimize and suppress re-pop (same as chevron/Esc).
                if case .approval = self.surface {
                    self.minimizeCurrentApproval()
                    return
                }
                withAnimation(NotchAnimation.close) {
                    self.surface = .collapsed
                }
            }
        }

        // Key handling for the approval card: Esc minimizes while editing the
        // custom-reply field; Backspace minimizes when no text field is focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard case .approval = self.surface else { return event }
            let editingText = self.isEditingTextField
            // 53 = Escape (always minimizes), 51 = Delete/Backspace (only when no
            // text field is focused, so it doesn't hijack editing).
            if event.keyCode == 53 {
                self.minimizeCurrentApproval()
                return nil
            }
            if event.keyCode == 51 && !editingText {
                self.minimizeCurrentApproval()
                return nil
            }
            return event
        }
    }

    /// True when the key window's first responder is a text-editing view (the
    /// custom-reply field). Used to route Esc vs Backspace minimize.
    private var isEditingTextField: Bool {
        guard let responder = panel?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let view = responder as? NSView, view is NSTextField { return true }
        return false
    }

    /// Minimize the currently-shown approval card and suppress its re-pop, matching
    /// the chevron behavior.
    private func minimizeCurrentApproval() {
        guard case let .approval(agentId) = surface else { return }
        if let agent = relay.agents.first(where: { $0.id == agentId }) {
            dismissPrompt(agentId: agent.id, promptId: agent.promptId)
        }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        // Tall enough for the largest approval card (multi-question form: header
        // + 320pt scroll + submit + paddings), bounded to the visible screen.
        let maxH = min(560, screen.frame.height - 40)
        let width = min(580, screen.frame.width - 40)
        return NSSize(width: width, height: maxH)
    }

    private func makeHostingView(for screen: NSScreen) -> NotchHostingView<NotchPanelView> {
        let hasNotch = ScreenDetector.hasNotch(screen)
        let notchH = ScreenDetector.topBarHeight(for: screen)
        let notchW = ScreenDetector.notchWidth(for: screen)

        let rootView = NotchPanelView(
            relay: relay,
            controller: self,
            hasNotch: hasNotch,
            notchHeight: notchH,
            notchW: notchW,
            screenWidth: screen.frame.width
        )
        let view = NotchHostingView(rootView: rootView)
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }

    private func updatePosition() {
        guard let panel else { return }
        let screen = ScreenDetector.preferredScreen
        let size = panelSize(for: screen)
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func handleScreenChange() {
        let screen = ScreenDetector.preferredScreen
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView
        panel?.contentView = contentView
        updatePosition()
    }

    private func handleSpaceChange() {
        if isActiveSpaceFullscreen() {
            fullscreenLatch = true
            panel?.orderOut(nil)
        } else {
            if fullscreenLatch {
                fullscreenLatch = false
                panel?.orderFrontRegardless()
            }
        }
    }

    private func isActiveSpaceFullscreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let screen = ScreenDetector.preferredScreen
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid == frontApp.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat else { continue }
            if w >= screen.frame.width && h >= screen.frame.height { return true }
        }
        return false
    }

    deinit {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Island Surface (panel state machine)

enum IslandSurface: Equatable {
    case collapsed
    case sessionList
    case approval(agentId: String)

    var isExpanded: Bool { self != .collapsed }
}

// MARK: - Notch Animation Presets

enum NotchAnimation {
    /// Expand: slight bounce, organic feel
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Collapse: critically damped, no overshoot (prevents shape bottom from peeking)
    static let close = Animation.spring(response: 0.38, dampingFraction: 1.0)
    /// Notification pop: quick bounce for auto-expand on blocked
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.65)
    /// Micro-interaction: hover states, button highlights
    static let micro = Animation.easeOut(duration: 0.12)
}
