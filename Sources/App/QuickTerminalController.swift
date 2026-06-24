import AppKit
import Foundation

@MainActor
final class QuickTerminalController {
    @MainActor
    struct Dependencies {
        var createMainWindow: @MainActor (AppDelegate, QuickTerminalPlacement, SessionWindowSnapshot?) -> UUID
        var windowForMainWindowId: @MainActor (AppDelegate, UUID) -> CmuxMainWindow?
        var focusQuickTerminalWindow: @MainActor (AppDelegate, CmuxMainWindow) -> Bool
        var beep: @MainActor () -> Void

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
    /// Tracks whether the in-progress hide restored a previous app, so
    /// completeHide() knows whether to NSApp.hide as a fallback. Reset per hide.
    private var restoredPreviousAppForCurrentHide = false
    private let configurationProvider: @MainActor () -> QuickTerminalConfiguration
    private let placementProvider: @MainActor (QuickTerminalConfiguration, Bool, @escaping (NSScreen) -> CGFloat?) -> QuickTerminalPlacement?
    private let dependencies: Dependencies
    /// User-adjusted height, remembered between toggles per display (full-width
    /// top dropdown: width/position are fixed, only height varies). Keyed by
    /// NSScreen.cmuxDisplayID so each monitor keeps its own size. Empty → use
    /// screenFraction.
    private var rememberedHeightByScreen: [UInt32: CGFloat] = [:]

    init(
        appDelegate: AppDelegate,
        configurationProvider: @escaping @MainActor () -> QuickTerminalConfiguration = { QuickTerminalConfiguration.current() },
        placementProvider: @escaping @MainActor (QuickTerminalConfiguration, Bool, @escaping (NSScreen) -> CGFloat?) -> QuickTerminalPlacement? = { configuration, overlayingFullscreen, heightForScreen in
            QuickTerminalPlacement.current(
                configuration: configuration,
                overlayingFullscreen: overlayingFullscreen,
                preferredHeightForScreen: heightForScreen
            )
        },
        dependencies: Dependencies? = nil
    ) {
        self.appDelegate = appDelegate
        self.configurationProvider = configurationProvider
        self.placementProvider = placementProvider
        self.dependencies = dependencies ?? Dependencies.live
    }

    func toggle() {
        let configuration = configurationProvider()
        guard let appDelegate,
              let placement = resolvePlacement(configuration) else {
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

        if var pendingSnapshot {
            pendingSnapshot.isQuickTerminal = true
            pendingSessionSnapshot = pendingSnapshot
        }
    }

    func hideFromCloseShortcut(_ window: CmuxMainWindow) {
        let configuration = configurationProvider()
        guard let placement = resolvePlacement(configuration) else {
            let restored = restorePreviousApp()
            window.orderOut(nil)
            window.setSoftHiddenForVisibilityController(true)
            if !restored { NSApp.hide(nil) }
            restoredPreviousAppForCurrentHide = false
            return
        }
        hide(window, placement: placement, configuration: configuration)
    }

    private func shouldHide(_ window: NSWindow) -> Bool {
        isShown(window)
    }

    private func rememberedHeight(for screen: NSScreen) -> CGFloat? {
        guard let id = screen.cmuxDisplayID else { return nil }
        return rememberedHeightByScreen[id]
    }

    private func resolvePlacement(_ configuration: QuickTerminalConfiguration) -> QuickTerminalPlacement? {
        placementProvider(configuration, isOverlayingThirdPartyApp()) { [weak self] screen in
            self?.rememberedHeight(for: screen)
        }
    }

    /// Heuristic for "the quake is dropping over a third-party (likely
    /// fullscreen) app": the frontmost app is not cmux. Used to anchor the quake
    /// on the physical top edge, since NSScreen keeps reporting the desktop
    /// Space's menu-bar inset even when the app underneath is fullscreen.
    private func isOverlayingThirdPartyApp() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost != .current
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

        // No slide: the slide starts from hiddenFrame (positioned above the target
        // screen), which on a vertically-stacked multi-monitor setup lands inside
        // the *other* screen and flashes there. Show the window directly at its
        // final visible frame on the target screen instead — no cross-screen flash.
        window.orderOut(nil)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        window.setFrame(placement.visibleFrame, display: false)
        NSAnimationContext.endGrouping()
        window.setSoftHiddenForVisibilityController(false)
        _ = dependencies.focusQuickTerminalWindow(appDelegate, window)
#if DEBUG
        cmuxDebugLog("quickTerminal.show visible={\(NSStringFromRect(placement.visibleFrame))}")
#endif
    }

    private func hide(
        _ window: CmuxMainWindow,
        placement givenPlacement: QuickTerminalPlacement,
        configuration: QuickTerminalConfiguration
    ) {
        // Restore focus to the previously-frontmost app BEFORE hiding, so macOS
        // hands the Space back to it (e.g. the fullscreen app) instead of pulling
        // a cmux window forward and switching to the desktop. Must happen before
        // orderOut for the same reason Ghostty does it pre-animation.
        restorePreviousApp()

        // Compute the hide placement on the window's OWN screen, not the mouse's.
        // With stacked displays the mouse can be on another screen, which made the
        // window slide off across screens. window.frame.height keeps its size.
        let placement: QuickTerminalPlacement
        if let screen = window.screen {
            placement = QuickTerminalPlacement.current(
                on: screen,
                configuration: configuration,
                preferredHeight: window.frame.height
            )
        } else {
            placement = givenPlacement
        }

        // Remember the height per display, so reopening on the same monitor
        // restores its size (width/position are fixed for the top dropdown).
        if let id = window.screen?.cmuxDisplayID {
            rememberedHeightByScreen[id] = window.frame.height
        }

        // No slide: hiding directly avoids the off-screen hiddenFrame (above the
        // target screen) which flashes on the other monitor when displays stack.
#if DEBUG
        cmuxDebugLog("quickTerminal.hide direct")
#endif
        completeHide(window, placement: placement)
    }

    private func completeHide(_ window: CmuxMainWindow, placement: QuickTerminalPlacement) {
        window.orderOut(nil)
        window.setFrame(placement.visibleFrame, display: false)
        window.setSoftHiddenForVisibilityController(true)
        // If no previous app was restored, hiding just the window leaves cmux
        // frontmost-but-invisible (it keeps focus while hidden). Hide the whole
        // app so macOS hands focus to whatever is behind it.
        if !restoredPreviousAppForCurrentHide {
            NSApp.hide(nil)
        }
        restoredPreviousAppForCurrentHide = false
    }

    @discardableResult
    private func restorePreviousApp() -> Bool {
        guard let previousApp else { return false }
        self.previousApp = nil
        guard !previousApp.isTerminated else { return false }
        previousApp.activate()
        restoredPreviousAppForCurrentHide = true
        return true
    }
}
