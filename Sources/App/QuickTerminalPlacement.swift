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
            // edge (fullFrame); the TOP anchors on visibleFrame.maxY — the area
            // below the menu bar. This self-adjusts: with the menu bar visible the
            // window sits just under it; when an app is fullscreen on the target
            // screen the menu bar is hidden so visibleFrame.maxY rises to the
            // physical top. Anchoring on frame.maxY pushed the window UNDER the
            // menu bar on the main screen.
            let frame = fullFrame ?? visibleFrame
            let topY = visibleFrame.maxY
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
        preferredHeightForScreen: (NSScreen) -> CGFloat? = { _ in nil }
    ) -> QuickTerminalPlacement? {
        guard let screen = preferredScreen() else { return nil }
        return placement(
            forVisibleFrame: screen.visibleFrame,
            fullFrame: screen.frame,
            preferredHeight: preferredHeightForScreen(screen),
            configuration: configuration
        )
    }

    /// Placement forced onto a specific screen — used at hide time so the window
    /// slides off *its own* screen instead of the mouse's (which, with stacked
    /// displays, made the hide animation drift across screens).
    static func current(
        on screen: NSScreen,
        configuration: QuickTerminalConfiguration = .current(),
        preferredHeight: CGFloat? = nil
    ) -> QuickTerminalPlacement {
        placement(
            forVisibleFrame: screen.visibleFrame,
            fullFrame: screen.frame,
            preferredHeight: preferredHeight,
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
