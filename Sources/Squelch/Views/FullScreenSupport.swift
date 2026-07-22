import SwiftUI
import AppKit

/// Full-screen: auto-hide the toolbar (and menu bar) so the map runs
/// edge-to-edge instead of sitting under a standing opaque toolbar band.
/// Mousing to the top reveals menu bar + toolbar together.
///
/// Implemented as a delegate proxy: SwiftUI owns the window delegate, so we
/// forward everything to it and answer only the full-screen presentation
/// options question ourselves.
final class FullScreenPresentationProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideToolbar, .autoHideMenuBar, .autoHideDock]
    }
}

/// Invisible view that grabs the hosting NSWindow, installs the proxy, and
/// tracks full-screen state for layout decisions (e.g. the titlebar drag
/// strip is pointless and click-stealing in full screen).
struct WindowAccessor: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    final class Coordinator {
        let proxy = FullScreenPresentationProxy()
        var observers: [NSObjectProtocol] = []
        var installedOn: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, context.coordinator.installedOn !== window else { return }
            context.coordinator.installedOn = window
            context.coordinator.proxy.original = window.delegate
            window.delegate = context.coordinator.proxy
            isFullScreen = window.styleMask.contains(.fullScreen)
            let center = NotificationCenter.default
            context.coordinator.observers = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                   object: window, queue: .main) { _ in isFullScreen = true },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                   object: window, queue: .main) { _ in isFullScreen = false },
            ]
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
