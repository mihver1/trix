import AppKit
import SwiftUI

struct WindowViewportConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.configureWindowIfNeeded(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configureWindowIfNeeded(for: nsView)
        }
    }

    final class Coordinator {
        private var configuredWindowNumber: Int?

        @MainActor
        func configureWindowIfNeeded(for view: NSView) {
            guard let window = view.window else {
                return
            }

            if configuredWindowNumber != window.windowNumber {
                configuredWindowNumber = window.windowNumber
                configure(window: window)
                return
            }

            clamp(window: window)
        }

        @MainActor
        private func configure(window: NSWindow) {
            window.minSize = NSSize(width: 960, height: 620)
            clamp(window: window)
        }

        @MainActor
        private func clamp(window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else {
                return
            }

            let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            var frame = window.frame

            frame.size.width = min(frame.size.width, visible.width)
            frame.size.height = min(frame.size.height, visible.height)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.size.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.size.height)

            if frame != window.frame {
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}
