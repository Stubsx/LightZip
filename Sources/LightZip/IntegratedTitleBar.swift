import AppKit
import SwiftUI

/// Keep the native title and window controls while letting the two pane colors
/// continue behind the title bar. The content still respects its safe area.
struct IntegratedTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarView { TitleBarView() }

    func updateNSView(_ view: TitleBarView, context: Context) {
        view.configureWindow()
    }

    final class TitleBarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            // SwiftUI applies its scene style during attachment; finish after it
            // so the native title remains visible over our full-window background.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
            }
        }
    }
}
