import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MainWindowVisibilityControllerTests: XCTestCase {
    func testFocusDeminiaturizesAndActivatesThroughSingleOwner() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var miniaturizedWindows: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activeWindows: [NSWindow] = []
        var deminiaturizedWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var unhideCount = 0
        var appActivations: [NSApplication.ActivationOptions] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { activeWindows.append($0) },
                isApplicationHidden: { true },
                unhideApplication: { unhideCount += 1 },
                activateRunningApplication: { appActivations.append($0) },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { miniaturizedWindows.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedWindows.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKeyAndOrderFront: { madeKeyWindows.append($0) }
                )
            )
        )

        XCTAssertTrue(
            controller.focus(
                window,
                reason: .focusMainWindow,
                activation: .runningApplication([.activateAllWindows])
            )
        )
        XCTAssertTrue(activeWindows.first === window)
        XCTAssertTrue(deminiaturizedWindows.first === window)
        XCTAssertTrue(madeKeyWindows.first === window)
        XCTAssertEqual(unhideCount, 1)
        XCTAssertEqual(appActivations, [[.activateAllWindows]])
    }

    func testFocusSuppressionOnlyUpdatesActiveContext() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var activeWindows: [NSWindow] = []
        var deminiaturizedCount = 0
        var madeKeyCount = 0
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { true },
                setActiveMainWindow: { activeWindows.append($0) },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { _ in true },
                    deminiaturize: { _ in deminiaturizedCount += 1 },
                    makeKeyAndOrderFront: { _ in madeKeyCount += 1 }
                )
            )
        )

        XCTAssertTrue(controller.focus(window, reason: .focusMainWindow))
        XCTAssertTrue(activeWindows.first === window)
        XCTAssertEqual(deminiaturizedCount, 0)
        XCTAssertEqual(madeKeyCount, 0)
        XCTAssertEqual(activationCount, 0)
    }

    func testHotkeyRestoreUsesCapturedVisibleTargetsWithoutDeminiaturizingMiniaturizedWindows() {
        let visibleWindow = makeWindow()
        let miniaturizedWindow = makeWindow()
        defer {
            visibleWindow.orderOut(nil)
            miniaturizedWindow.orderOut(nil)
        }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(visibleWindow)]
        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(miniaturizedWindow)]
        var isAppActive = true
        var isAppHidden = false
        var hideCount = 0
        var unhideCount = 0
        var deminiaturizedWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationActive: { isAppActive },
                isApplicationHidden: { isAppHidden },
                hideApplication: {
                    hideCount += 1
                    isAppActive = false
                    isAppHidden = true
                },
                unhideApplication: {
                    unhideCount += 1
                    isAppHidden = false
                },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) }
                )
            )
        )

        controller.toggleApplicationVisibility(
            windows: [visibleWindow, miniaturizedWindow],
            reason: .globalHotkey
        )
        XCTAssertEqual(hideCount, 1)

        controller.toggleApplicationVisibility(
            windows: [visibleWindow, miniaturizedWindow],
            reason: .globalHotkey
        )

        XCTAssertEqual(unhideCount, 1)
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(madeKeyWindows.contains { $0 === visibleWindow })
        XCTAssertFalse(deminiaturizedWindows.contains { $0 === miniaturizedWindow })
    }

    func testShowApplicationWindowsStillRestoresMiniaturizedWindowsWhenNoHiddenTargetsWereCaptured() {
        let miniaturizedWindow = makeWindow()
        defer { miniaturizedWindow.orderOut(nil) }

        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(miniaturizedWindow)]
        var deminiaturizedWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) }
                )
            )
        )

        _ = controller.showApplicationWindows(windows: [miniaturizedWindow], reason: .globalHotkey)

        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(deminiaturizedWindows.contains { $0 === miniaturizedWindow })
        XCTAssertTrue(madeKeyWindows.contains { $0 === miniaturizedWindow })
    }

    func testDismissWindowsSoftHidesVisibleTargetsAndRestoresWithoutDeminiaturizing() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var softHiddenWindows: [NSWindow] = [], orderedRegardlessWindows: [NSWindow] = []
        var deminiaturizedWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    deminiaturize: { deminiaturizedWindows.append($0) },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) },
                    softHide: { softHiddenWindows.append($0) }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        _ = controller.showApplicationWindows(windows: [window], reason: .applicationReopen)

        XCTAssertTrue(softHiddenWindows.contains { $0 === window })
        XCTAssertTrue(orderedRegardlessWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.contains { $0 === window })
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(deminiaturizedWindows.isEmpty)
    }

    func testDismissedWindowDoesNotRestoreWhileAnotherWindowIsVisible() {
        let dismissedWindow = makeWindow()
        let visibleWindow = makeWindow()
        defer {
            dismissedWindow.orderOut(nil)
            visibleWindow.orderOut(nil)
        }

        var visibleIds: Set<ObjectIdentifier> = [
            ObjectIdentifier(dismissedWindow),
            ObjectIdentifier(visibleWindow)
        ]
        var madeKeyWindows: [NSWindow] = []
        var softHiddenWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    makeKey: { madeKeyWindows.append($0) },
                    softHide: { window in
                        visibleIds.remove(ObjectIdentifier(window))
                        softHiddenWindows.append(window)
                    }
                )
            )
        )

        controller.dismissWindows(
            windows: [dismissedWindow],
            reason: .titlebarDismiss
        )
        _ = controller.showApplicationWindows(
            windows: [dismissedWindow, visibleWindow],
            reason: .menuBar
        )

        XCTAssertTrue(softHiddenWindows.contains { $0 === dismissedWindow })
        XCTAssertTrue(madeKeyWindows.contains { $0 === visibleWindow })
        XCTAssertFalse(madeKeyWindows.contains { $0 === dismissedWindow })
    }

    func testPassiveRevealWithoutKeyTransferDoesNotActivateApplication() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activationCount = 0
        var orderedRegardlessWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) }
                )
            )
        )

        _ = controller.showApplicationWindows(
            windows: [window],
            reason: .applicationReopen,
            makeKey: false
        )

        XCTAssertEqual(
            activationCount,
            0,
            "Ordering a visible cmux window without transferring key focus must not make cmux the Launch Services frontmost app."
        )
        XCTAssertTrue(orderedRegardlessWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.isEmpty)
    }

    func testPassiveRevealWithoutKeyTransferDoesNotDeminiaturizeWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activationCount = 0
        var deminiaturizedWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { _ in false },
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) }
                )
            )
        )

        let revealedWindow = controller.showApplicationWindows(
            windows: [window],
            reason: .applicationReopen,
            makeKey: false
        )

        XCTAssertNil(
            revealedWindow,
            "A passive reveal must not unminiaturize a background cmux window because AppKit can mark the app frontmost."
        )
        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(deminiaturizedWindows.isEmpty)
        XCTAssertTrue(orderedRegardlessWindows.isEmpty)
        XCTAssertTrue(madeKeyWindows.isEmpty)
    }

    func testHiddenAppRestoreFallsBackToSoftDismissedTargets() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var isAppHidden = false
        var unhideCount = 0
        var softShownWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { isAppHidden },
                unhideApplication: {
                    unhideCount += 1
                    isAppHidden = false
                },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    makeKey: { madeKeyWindows.append($0) },
                    softHide: { visibleIds.remove(ObjectIdentifier($0)) },
                    softShow: { softShownWindows.append($0) }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        isAppHidden = true
        _ = controller.showApplicationWindows(windows: [window], reason: .applicationReopen)

        XCTAssertEqual(unhideCount, 1)
        XCTAssertTrue(softShownWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.contains { $0 === window })
    }

    func testApplicationActivationRestoreOrdersBeforeActivationThenMakesKeyAfterActivation() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activeWindows: [NSWindow] = [], softShownWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { activeWindows.append($0) },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) },
                    softHide: { visibleIds.remove(ObjectIdentifier($0)) },
                    softShow: { window in
                        visibleIds.insert(ObjectIdentifier(window))
                        softShownWindows.append(window)
                    }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        XCTAssertTrue(visibleIds.isEmpty)

        let preActivationWindow = controller.orderFrontApplicationWindowsBeforeActivation(
            windows: [window],
            reason: .applicationWillBecomeActive
        )
        XCTAssertTrue(preActivationWindow === window)
        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(orderedRegardlessWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.isEmpty)

        let restoredWindow = controller.finishPendingApplicationActivationRestore(
            windows: [window],
            reason: .applicationDidBecomeActive
        )
        XCTAssertTrue(restoredWindow === window)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(activeWindows.filter { $0 === window }.count, 2)
        XCTAssertEqual(softShownWindows.filter { $0 === window }.count, 2)
        XCTAssertEqual(orderedRegardlessWindows.filter { $0 === window }.count, 2)
        XCTAssertEqual(madeKeyWindows.filter { $0 === window }.count, 1)
    }

    func testPassiveActivationDoesNotRestoreOnlyMiniaturizedWindows() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var deminiaturizedWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) }
                )
            )
        )

        XCTAssertNil(
            controller.orderFrontApplicationWindowsBeforeActivation(
                windows: [window],
                reason: .applicationWillBecomeActive
            )
        )
        XCTAssertNil(
            controller.restoreApplicationWindowsAfterActivation(
                windows: [window],
                reason: .applicationDidBecomeActive
            )
        )
        XCTAssertTrue(deminiaturizedWindows.isEmpty)
        XCTAssertTrue(orderedRegardlessWindows.isEmpty)
        XCTAssertTrue(madeKeyWindows.isEmpty)
        XCTAssertEqual(activationCount, 0)
    }

    func testQuickTerminalPlacementIsFullWidthAnchoredOnTop() {
        // Default .top: full-width, anchored on visibleFrame.maxY (no overlay),
        // height = screenFraction (0.46) of the available band. hiddenFrame sits
        // just above the top edge for the (now removed) slide geometry.
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertEqual(placement.visibleFrame.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.origin.y, 432, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.width, 1000, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.height, 368, accuracy: 0.001)
        XCTAssertEqual(placement.hiddenFrame.origin.x, placement.visibleFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(placement.hiddenFrame.origin.y, 800, accuracy: 0.001)
    }

    func testQuickTerminalPlacementClampsHeightToSmallScreen() {
        // On a 300pt-tall band, 0.46 fraction = 138pt (above the 120pt floor),
        // still full-width and anchored on the visible top edge.
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 10, y: 20, width: 500, height: 300)
        )

        XCTAssertEqual(placement.visibleFrame.origin.x, 10, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.origin.y, 182, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.width, 500, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.height, 138, accuracy: 0.001)
        XCTAssertEqual(placement.hiddenFrame.origin.x, placement.visibleFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(placement.hiddenFrame.origin.y, 320, accuracy: 0.001)
    }

    func testQuickTerminalPlacementAnchorsToPhysicalTopWhenOverlayingFullscreen() {
        // Overlaying a fullscreen app: NSScreen still reports the desktop Space's
        // visibleFrame (here 30pt shorter than the physical frame). The window
        // must anchor on the *physical* top (fullFrame.maxY) to avoid a menu-bar
        // gap, since the menu bar is hidden underneath a fullscreen app.
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 770),
            fullFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            overlayingFullscreen: true
        )

        // topY = fullFrame.maxY = 800, height = 0.46 * 800 = 368.
        XCTAssertEqual(placement.visibleFrame.maxY, 800, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.origin.y, 432, accuracy: 0.001)
        XCTAssertEqual(placement.visibleFrame.width, 1000, accuracy: 0.001)
    }

    func testQuickTerminalPlacementSubtractsNotchWhenOverlayingFullscreen() {
        // On a notched display the physical top hosts the notch; anchoring there
        // would slide content under it. topY = fullFrame.maxY - safeAreaInset.
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 770),
            fullFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            overlayingFullscreen: true,
            topSafeAreaInset: 32
        )

        // topY = 800 - 32 = 768 (clears the notch, still covers the menu-bar band).
        XCTAssertEqual(placement.visibleFrame.maxY, 768, accuracy: 0.001)
    }

    func testQuickTerminalPlacementIgnoresNotchWhenNotOverlaying() {
        // Without an overlay the menu bar is visible, so the notch inset is moot:
        // anchoring stays on visibleFrame.maxY regardless of topSafeAreaInset.
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 770),
            fullFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            overlayingFullscreen: false,
            topSafeAreaInset: 32
        )

        XCTAssertEqual(placement.visibleFrame.maxY, 770, accuracy: 0.001)
    }

    func testModalHostRecognizesQuickTerminalAndMainWindows() {
        let quake = NSWindow()
        quake.identifier = NSUserInterfaceItemIdentifier("cmux.quickTerminal")
        XCTAssertTrue(quake.isCmuxQuickTerminalWindow)
        XCTAssertTrue(quake.isCmuxModalHostWindow)
        XCTAssertFalse(quake.isCmuxMainWindow)

        let main = NSWindow()
        main.identifier = NSUserInterfaceItemIdentifier("cmux.main.42")
        XCTAssertTrue(main.isCmuxMainWindow)
        XCTAssertTrue(main.isCmuxModalHostWindow)
        XCTAssertFalse(main.isCmuxQuickTerminalWindow)

        let other = NSWindow()
        other.identifier = NSUserInterfaceItemIdentifier("something.else")
        XCTAssertFalse(other.isCmuxModalHostWindow)
    }

    func testQuickTerminalKeepsPendingSnapshotWhenCreatedWindowCannotBeRetrieved() {
        let appDelegate = AppDelegate()
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let snapshot = makeQuickTerminalWindowSnapshot()
        var createdSnapshots: [SessionWindowSnapshot?] = []
        var beepCount = 0
        let controller = QuickTerminalController(
            appDelegate: appDelegate,
            configurationProvider: { .fallback },
            placementProvider: { _, _, _ in placement },
            dependencies: makeQuickTerminalDependencies(
                createMainWindow: { _, _, snapshot in
                    createdSnapshots.append(snapshot)
                    return UUID()
                },
                windowForMainWindowId: { _, _ in nil },
                beep: {
                    beepCount += 1
                }
            )
        )

        controller.restoreSession(snapshot)
        controller.toggle()

        XCTAssertEqual(createdSnapshots.count, 1)
        XCTAssertEqual(createdSnapshots.first??.isQuickTerminal, true)
        XCTAssertEqual(controller.pendingSessionSnapshotForPersistence()?.isQuickTerminal, true)
        XCTAssertEqual(beepCount, 1)
    }

    func testQuickTerminalUnregisterClearsTrackedWindowIdAndKeepsSnapshotForPersistence() {
        let appDelegate = AppDelegate()
        let placement = QuickTerminalPlacement.placement(
            forVisibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeCmuxWindow(frame: placement.visibleFrame)
        let secondWindow = makeCmuxWindow(frame: placement.visibleFrame)
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }
        var pendingCreateIds = [firstWindowId, secondWindowId]
        var liveWindowIds: Set<UUID> = []
        let windowsById = [
            firstWindowId: firstWindow,
            secondWindowId: secondWindow
        ]
        var createdSnapshots: [SessionWindowSnapshot?] = []
        let controller = QuickTerminalController(
            appDelegate: appDelegate,
            configurationProvider: { .fallback },
            placementProvider: { _, _, _ in placement },
            dependencies: makeQuickTerminalDependencies(
                createMainWindow: { _, _, snapshot in
                    createdSnapshots.append(snapshot)
                    let id = pendingCreateIds.removeFirst()
                    liveWindowIds.insert(id)
                    return id
                },
                windowForMainWindowId: { _, id in
                    liveWindowIds.contains(id) ? windowsById[id] : nil
                }
            )
        )

        controller.toggle()
        XCTAssertNil(controller.pendingSessionSnapshotForPersistence())

        liveWindowIds.remove(firstWindowId)
        controller.handleWindowUnregistered(
            windowId: firstWindowId,
            pendingSnapshot: makeQuickTerminalWindowSnapshot()
        )

        XCTAssertEqual(controller.pendingSessionSnapshotForPersistence()?.isQuickTerminal, true)

        controller.toggle()

        XCTAssertEqual(createdSnapshots.count, 2)
        XCTAssertEqual(createdSnapshots.last??.isQuickTerminal, true)
        XCTAssertNil(controller.pendingSessionSnapshotForPersistence())
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeCmuxWindow(frame: NSRect) -> CmuxMainWindow {
        let window = CmuxMainWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeQuickTerminalWindowSnapshot() -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 0, y: 0, width: 800, height: 600),
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: 220),
            isQuickTerminal: true
        )
    }

    private func makeQuickTerminalDependencies(
        createMainWindow: @escaping @MainActor (AppDelegate, QuickTerminalPlacement, SessionWindowSnapshot?) -> UUID = { _, _, _ in UUID() },
        windowForMainWindowId: @escaping @MainActor (AppDelegate, UUID) -> CmuxMainWindow? = { _, _ in nil },
        focusQuickTerminalWindow: @escaping @MainActor (AppDelegate, CmuxMainWindow) -> Bool = { _, _ in true },
        beep: @escaping @MainActor () -> Void = {}
    ) -> QuickTerminalController.Dependencies {
        QuickTerminalController.Dependencies(
            createMainWindow: createMainWindow,
            windowForMainWindowId: windowForMainWindowId,
            focusQuickTerminalWindow: focusQuickTerminalWindow,
            beep: beep
        )
    }

    private func makeWindowOperations(
        isVisible: @escaping (NSWindow) -> Bool = { _ in true },
        isMiniaturized: @escaping (NSWindow) -> Bool = { _ in false },
        isKeyWindow: @escaping (NSWindow) -> Bool = { _ in false },
        canBecomeMain: @escaping (NSWindow) -> Bool = { _ in true },
        canBecomeKey: @escaping (NSWindow) -> Bool = { _ in true },
        deminiaturize: @escaping (NSWindow) -> Void = { _ in },
        makeKeyAndOrderFront: @escaping (NSWindow) -> Void = { _ in },
        makeKey: @escaping (NSWindow) -> Void = { _ in },
        orderFront: @escaping (NSWindow) -> Void = { _ in },
        orderFrontRegardless: @escaping (NSWindow) -> Void = { _ in },
        softHide: @escaping (NSWindow) -> Void = { _ in },
        softShow: @escaping (NSWindow) -> Void = { _ in }
    ) -> MainWindowVisibilityController.WindowOperations {
        MainWindowVisibilityController.WindowOperations(
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isKeyWindow: isKeyWindow,
            canBecomeMain: canBecomeMain,
            canBecomeKey: canBecomeKey,
            deminiaturize: deminiaturize,
            makeKeyAndOrderFront: makeKeyAndOrderFront,
            makeKey: makeKey,
            orderFront: orderFront,
            orderFrontRegardless: orderFrontRegardless,
            orderOut: { _ in },
            softHide: softHide,
            softShow: softShow
        )
    }
}
