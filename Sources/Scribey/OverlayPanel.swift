import AppKit
import SwiftUI

final class OverlayPanel {
    private var panel: NSPanel?
    private let state: RecordingState

    init(state: RecordingState) {
        self.state = state
        setupPanel()
    }

    private func setupPanel() {
        let view = OverlayView(state: state)
        let hostingView = NSHostingView(rootView: view)
        let contentRect = NSRect(x: 0, y: 0, width: 260, height: 50)
        hostingView.frame = contentRect
        // Keep the panel at a fixed size. By default the hosting view resizes the
        // window to the content measured at creation (idle, empty label), which
        // left too little room and truncated "Transcribing…" to "Transc…".
        hostingView.sizingOptions = []

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        positionBottomCenter(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionBottomCenter(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.minY + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
