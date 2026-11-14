import SwiftUI

/// AppKit reports scroll changes and lets us restore a recording's position after layout.
struct ScriptTextEditor: NSViewRepresentable {
    let projectID: UUID
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.font = .systemFont(ofSize: 16)
        view.isRichText = false
        view.drawsBackground = false
        scroll.drawsBackground = false
        view.setAccessibilityLabel("完整文章编辑区")
        view.delegate = context.coordinator
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        let changed = coordinator.projectID != projectID
        if changed {
            coordinator.switchRecording(to: projectID)
        }
        if view.string != text {
            view.string = text
        }
        if changed {
            DispatchQueue.main.async { coordinator.restore(scroll, for: projectID) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>?
        private(set) var projectID: UUID?
        private var token: NSObjectProtocol?
        private var restoring = false
        private var lastOffset: Double?
        private var storedOffset: Double?
        private var key: String? { projectID.map { "KongVox.scriptScroll." + $0.uuidString } }

        func switchRecording(to id: UUID) {
            if let key, let lastOffset { UserDefaults.standard.set(lastOffset, forKey: key) }
            projectID = id
            lastOffset = nil
            storedOffset = nil
            restoring = true
        }

        func observe(_ scroll: NSScrollView) {
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.restoring, let scroll, let key = self.key else { return }
                    let y = Double(scroll.contentView.bounds.origin.y)
                    self.lastOffset = y
                    let stored = self.storedOffset ?? UserDefaults.standard.double(forKey: key)
                    if abs(stored - y) >= 8 || y == 0 {
                        UserDefaults.standard.set(y, forKey: key)
                        self.storedOffset = y
                    }
                }
            }
        }

        func restore(_ scroll: NSScrollView, for id: UUID) {
            guard projectID == id, let key else { return }
            let offset = UserDefaults.standard.double(forKey: key)
            if let textView = scroll.documentView as? NSTextView, let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            restoring = false
        }

        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text?.wrappedValue = view.string }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
