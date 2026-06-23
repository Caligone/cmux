import AppKit

@MainActor
struct QuickTerminalPlacement: Equatable {
    static let defaultTopInsetRange: ClosedRange<CGFloat> = 8...16

    let visibleFrame: NSRect
    let hiddenFrame: NSRect

    static func placement(
        forVisibleFrame visibleFrame: NSRect,
        fullFrame: NSRect? = nil,
        preferredHeight: CGFloat? = nil,
        overlayingFullscreen: Bool = false,
        topSafeAreaInset: CGFloat = 0,
        configuration: QuickTerminalConfiguration = .fallback
    ) -> QuickTerminalPlacement {
        let topInset = min(max(visibleFrame.height * 0.015, defaultTopInsetRange.lowerBound), defaultTopInsetRange.upperBound)
        let preferredHorizontalInset = min(max(visibleFrame.width * 0.06, 32), 96)
        let horizontalInset = min(preferredHorizontalInset, max(0, (visibleFrame.width - 1) / 2))
        let verticalInset = min(max(visibleFrame.height * 0.04, 24), 96)

        let shown: NSRect
        let hidden: NSRect
        switch configuration.position {
        case .top:
            // Full-width quake dropdown. Width spans the physical screen edge to
            // edge (fullFrame). The TOP normally anchors on visibleFrame.maxY (just
            // below the menu bar) — anchoring on frame.maxY would push the window
            // UNDER the menu bar on the main screen.
            // Exception: when overlaying a third-party fullscreen app, NSScreen
            // still reports the desktop Space's visibleFrame (menu-bar inset
            // included), so visibleFrame.maxY leaves a menu-bar-height gap above
            // the window. There the menu bar is hidden, so anchor higher — but on
            // a notched display stop at the safe-area top (frame.maxY minus the
            // notch height), otherwise content would slide under the notch.
            let frame = fullFrame ?? visibleFrame
            let topY = overlayingFullscreen ? (frame.maxY - topSafeAreaInset) : visibleFrame.maxY
            let width = frame.width
            let maxHeight = topY - frame.minY
            let defaultHeight = maxHeight * configuration.screenFraction
            let height = min(max(preferredHeight ?? defaultHeight, 120), maxHeight)
            let x = frame.minX
            let y = topY - height
            shown = NSRect(x: x, y: y, width: width, height: height)
            hidden = NSRect(x: x, y: topY, width: width, height: height)
        case .bottom:
            let width = max(1, visibleFrame.width - horizontalInset * 2)
            let maxHeight = max(1, visibleFrame.height - topInset)
            let minHeight = min(420, maxHeight)
            let height = min(max(minHeight, visibleFrame.height * configuration.screenFraction), maxHeight)
            let x = visibleFrame.minX + (visibleFrame.width - width) / 2
            let y = visibleFrame.minY + topInset
            shown = NSRect(x: x, y: y, width: width, height: height)
            hidden = NSRect(x: x, y: visibleFrame.minY - height - topInset, width: width, height: height)
        case .left:
            let maxWidth = max(1, visibleFrame.width - horizontalInset)
            let width = min(max(420, visibleFrame.width * configuration.screenFraction), maxWidth)
            let height = max(1, visibleFrame.height - verticalInset * 2)
            let y = visibleFrame.minY + verticalInset
            shown = NSRect(x: visibleFrame.minX + topInset, y: y, width: width, height: height)
            hidden = NSRect(x: visibleFrame.minX - width - topInset, y: y, width: width, height: height)
        case .right:
            let maxWidth = max(1, visibleFrame.width - horizontalInset)
            let width = min(max(420, visibleFrame.width * configuration.screenFraction), maxWidth)
            let height = max(1, visibleFrame.height - verticalInset * 2)
            let y = visibleFrame.minY + verticalInset
            shown = NSRect(x: visibleFrame.maxX - width - topInset, y: y, width: width, height: height)
            hidden = NSRect(x: visibleFrame.maxX + topInset, y: y, width: width, height: height)
        case .center:
            let width = max(1, visibleFrame.width * 0.82)
            let height = max(1, visibleFrame.height * 0.82)
            shown = NSRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
            hidden = shown
        }
        return QuickTerminalPlacement(visibleFrame: shown, hiddenFrame: hidden)
    }

    /// `preferredHeightForScreen` is resolved against the screen the quake will
    /// actually open on, so the height can be remembered per display.
    static func current(
        configuration: QuickTerminalConfiguration = .current(),
        overlayingFullscreen: Bool = false,
        preferredHeightForScreen: (NSScreen) -> CGFloat? = { _ in nil }
    ) -> QuickTerminalPlacement? {
        guard let screen = preferredScreen() else { return nil }
        return placement(
            forVisibleFrame: screen.visibleFrame,
            fullFrame: screen.frame,
            preferredHeight: preferredHeightForScreen(screen),
            overlayingFullscreen: overlayingFullscreen,
            topSafeAreaInset: screen.safeAreaInsets.top,
            configuration: configuration
        )
    }

    /// Placement forced onto a specific screen — used at hide time so the window
    /// slides off *its own* screen instead of the mouse's (which, with stacked
    /// displays, made the hide animation drift across screens).
    static func current(
        on screen: NSScreen,
        configuration: QuickTerminalConfiguration = .current(),
        preferredHeight: CGFloat? = nil,
        overlayingFullscreen: Bool = false
    ) -> QuickTerminalPlacement {
        placement(
            forVisibleFrame: screen.visibleFrame,
            fullFrame: screen.frame,
            preferredHeight: preferredHeight,
            overlayingFullscreen: overlayingFullscreen,
            topSafeAreaInset: screen.safeAreaInsets.top,
            configuration: configuration
        )
    }

    static func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        if let mainScreen = NSScreen.main {
            return mainScreen
        }
        return NSScreen.screens.first
    }
}
