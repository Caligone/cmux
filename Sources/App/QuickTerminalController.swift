import AppKit
import Foundation

@MainActor
final class QuickTerminalController {
    private enum AnimationPhase {
        case idle
        case showing
        case hiding
    }

    private enum PendingAnimationIntent {
        case show
        case hide
    }

    @MainActor
    struct Dependencies {
        var createMainWindow: @MainActor (AppDelegate, QuickTerminalPlacement, SessionWindowSnapshot?) -> UUID
        var windowForMainWindowId: @MainActor (AppDelegate, UUID) -> CmuxMainWindow?
        var focusQuickTerminalWindow: @MainActor (AppDelegate, CmuxMainWindow) -> Bool
        var beep: @MainActor () -> Void
        var animateFrame: @MainActor (
            NSWindow,
            NSRect,
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void

        static let live = Dependencies(
            createMainWindow: { appDelegate, placement, snapshot in
                appDelegate.createMainWindow(
                    initialWorkspaceTitle: String(localized: "quickTerminal.windowTitle", defaultValue: "Quick Terminal"),
                    sessionWindowSnapshot: snapshot,
                    shouldActivate: false,
                    initialFrame: placement.visibleFrame,
                    initialSidebarVisible: false,
                    shouldOrderFrontWhenNotActivating: false,
                    isQuickTerminal: true
                )
            },
            windowForMainWindowId: { appDelegate, windowId in
                appDelegate.windowForMainWindowId(windowId) as? CmuxMainWindow
            },
            focusQuickTerminalWindow: { appDelegate, window in
                appDelegate.focusQuickTerminalWindow(window)
            },
            beep: {
                NSSound.beep()
            },
            animateFrame: { window, frame, duration, completion in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.allowsImplicitAnimation = true
                    window.animator().setFrame(frame, display: true)
                } completionHandler: {
                    Task { @MainActor in
                        completion()
                    }
                }
            }
        )
    }

    private weak var appDelegate: AppDelegate?
    private var quickTerminalWindowId: UUID?
    private var pendingSessionSnapshot: SessionWindowSnapshot?
    /// App that was frontmost when the quick terminal was shown (e.g. a
    /// fullscreen app). Restored on hide so macOS hands focus back to it instead
    /// of pulling a cmux window forward — which would switch away from the
    /// fullscreen Space (the "ramène au bureau" bug).
    private var previousApp: NSRunningApplication?
    private var animationPhase = AnimationPhase.idle
    private var pendingAnimationIntent: PendingAnimationIntent?
    private let configurationProvider: @MainActor () -> QuickTerminalConfiguration
    private let placementProvider: @MainActor (QuickTerminalConfiguration, CGFloat?) -> QuickTerminalPlacement?
    private let dependencies: Dependencies
    /// User-adjusted height, remembered between toggles (full-width top dropdown:
    /// width/position are fixed, only height varies). nil → use screenFraction.
    private var rememberedHeight: CGFloat?

    init(
        appDelegate: AppDelegate,
        configurationProvider: @escaping @MainActor () -> QuickTerminalConfiguration = { QuickTerminalConfiguration.current() },
        placementProvider: @escaping @MainActor (QuickTerminalConfiguration, CGFloat?) -> QuickTerminalPlacement? = { configuration, preferredHeight in
            QuickTerminalPlacement.current(configuration: configuration, preferredHeight: preferredHeight)
        },
        dependencies: Dependencies? = nil
    ) {
        self.appDelegate = appDelegate
        self.configurationProvider = configurationProvider
        self.placementProvider = placementProvider
        self.dependencies = dependencies ?? Dependencies.live
    }

    func toggle() {
        if queueToggleIfAnimating() {
            return
        }

        let configuration = configurationProvider()
        guard let appDelegate,
              let placement = placementProvider(configuration, rememberedHeight) else {
            return
        }

        guard let window = quickTerminalWindow(appDelegate: appDelegate, placement: placement) else {
            dependencies.beep()
            return
        }

        if shouldHide(window) {
            hide(window, placement: placement, configuration: configuration)
        } else {
            show(window, placement: placement, configuration: configuration, appDelegate: appDelegate)
        }
    }

    func restoreSession(_ snapshot: SessionWindowSnapshot) {
        pendingSessionSnapshot = snapshot
    }

    func pendingSessionSnapshotForPersistence() -> SessionWindowSnapshot? {
        guard quickTerminalWindowId == nil else { return nil }
        return pendingSessionSnapshot
    }

    func handleWindowUnregistered(windowId: UUID, pendingSnapshot: SessionWindowSnapshot?) {
        guard quickTerminalWindowId == windowId else { return }
        quickTerminalWindowId = nil
        pendingAnimationIntent = nil
        animationPhase = .idle

        if var pendingSnapshot {
            pendingSnapshot.isQuickTerminal = true
            pendingSessionSnapshot = pendingSnapshot
        }
    }

    func hideFromCloseShortcut(_ window: CmuxMainWindow) {
        if queueHideIfAnimating() {
            return
        }

        let configuration = configurationProvider()
        guard let placement = placementProvider(configuration, rememberedHeight) else {
            restorePreviousApp()
            window.orderOut(nil)
            window.setSoftHiddenForVisibilityController(true)
            return
        }
        hide(window, placement: placement, configuration: configuration)
    }

    private func shouldHide(_ window: NSWindow) -> Bool {
        isShown(window)
    }

    private func queueToggleIfAnimating() -> Bool {
        switch animationPhase {
        case .idle:
            return false
        case .showing:
            pendingAnimationIntent = .hide
            return true
        case .hiding:
            pendingAnimationIntent = .show
            return true
        }
    }

    private func queueHideIfAnimating() -> Bool {
        switch animationPhase {
        case .idle:
            return false
        case .showing:
            pendingAnimationIntent = .hide
            return true
        case .hiding:
            pendingAnimationIntent = nil
            return true
        }
    }

    private func runPendingAnimationIntent() {
        guard let pendingAnimationIntent else { return }
        self.pendingAnimationIntent = nil

        let configuration = configurationProvider()
        guard let appDelegate,
              let placement = placementProvider(configuration, rememberedHeight) else {
            return
        }

        guard let window = quickTerminalWindow(appDelegate: appDelegate, placement: placement) else {
            dependencies.beep()
            return
        }

        switch pendingAnimationIntent {
        case .show:
            show(window, placement: placement, configuration: configuration, appDelegate: appDelegate)
        case .hide:
            hide(window, placement: placement, configuration: configuration)
        }
    }

    private func isShown(_ window: NSWindow) -> Bool {
        window.isVisible &&
            !window.isMiniaturized &&
            window.alphaValue > 0.001
    }

    private func quickTerminalWindow(
        appDelegate: AppDelegate,
        placement: QuickTerminalPlacement
    ) -> CmuxMainWindow? {
        if let quickTerminalWindowId,
           let window = appDelegate.windowForMainWindowId(quickTerminalWindowId) as? CmuxMainWindow {
            configure(window)
            return window
        }

        let snapshot = pendingSessionSnapshot
        let windowId = dependencies.createMainWindow(appDelegate, placement, snapshot)
        guard let window = dependencies.windowForMainWindowId(appDelegate, windowId) else {
            return nil
        }
        pendingSessionSnapshot = nil
        quickTerminalWindowId = windowId
        configure(window)
        window.setSoftHiddenForVisibilityController(true)
        window.orderOut(nil)
#if DEBUG
        cmuxDebugLog("quickTerminal.create windowId=\(String(windowId.uuidString.prefix(8))) frame={\(NSStringFromRect(placement.visibleFrame))}")
#endif
        return window
    }

    private func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.quickTerminal")
        // Non-activating panel recipe (validated standalone): a floating panel
        // with .nonactivatingPanel styleMask overlays a third-party fullscreen
        // Space without switching the app's Space. .floating level is enough here
        // — the non-activating panel is what does the work, not a high level.
        if let panel = window as? NSPanel {
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
        }
        window.level = .floating
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary])
        window.isExcludedFromWindowsMenu = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func show(
        _ window: CmuxMainWindow,
        placement: QuickTerminalPlacement,
        configuration: QuickTerminalConfiguration,
        appDelegate: AppDelegate
    ) {
        configure(window)
        // Remember who was frontmost (e.g. a fullscreen app) so hide() can hand
        // focus back. Skip if it's already us — then there's nothing to restore.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost != .current {
            previousApp = frontmost
        }
        if isShown(window) {
            window.setSoftHiddenForVisibilityController(false)
            _ = dependencies.focusQuickTerminalWindow(appDelegate, window)
            return
        }

        animationPhase = .showing
        window.setFrame(placement.hiddenFrame, display: false)
        window.setSoftHiddenForVisibilityController(false)
        _ = dependencies.focusQuickTerminalWindow(appDelegate, window)
#if DEBUG
        cmuxDebugLog("quickTerminal.show frame={\(NSStringFromRect(placement.visibleFrame))}")
#endif
        dependencies.animateFrame(window, placement.visibleFrame, configuration.animationDuration) { [weak self] in
            guard let self else { return }
            self.animationPhase = .idle
            self.runPendingAnimationIntent()
        }
    }

    private func hide(
        _ window: CmuxMainWindow,
        placement: QuickTerminalPlacement,
        configuration: QuickTerminalConfiguration
    ) {
        // Restore focus to the previously-frontmost app BEFORE hiding, so macOS
        // hands the Space back to it (e.g. the fullscreen app) instead of pulling
        // a cmux window forward and switching to the desktop. Must happen before
        // orderOut for the same reason Ghostty does it pre-animation.
        restorePreviousApp()

        // Remember the height the user left the window at, so the next toggle
        // reopens at the same size (width/position are fixed for the top dropdown).
        rememberedHeight = window.frame.height

        if placement.hiddenFrame.equalTo(placement.visibleFrame) {
            completeHide(window, placement: placement)
            return
        }

        animationPhase = .hiding
#if DEBUG
        cmuxDebugLog("quickTerminal.hide frame={\(NSStringFromRect(placement.hiddenFrame))}")
#endif
        dependencies.animateFrame(window, placement.hiddenFrame, configuration.animationDuration * 0.8) { [weak self, window] in
            guard let self else { return }
            self.completeHide(window, placement: placement)
            self.runPendingAnimationIntent()
        }
    }

    private func completeHide(_ window: CmuxMainWindow, placement: QuickTerminalPlacement) {
        window.orderOut(nil)
        window.setFrame(placement.visibleFrame, display: false)
        window.setSoftHiddenForVisibilityController(true)
        animationPhase = .idle
    }

    private func restorePreviousApp() {
        guard let previousApp else { return }
        self.previousApp = nil
        guard !previousApp.isTerminated else { return }
        previousApp.activate()
    }
}
