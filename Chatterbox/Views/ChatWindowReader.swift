import AppKit
import SwiftUI

struct ChatWindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader { let view = Reader(); view.onWindow = onWindow; return view }
    func updateNSView(_ view: Reader, context: Context) { view.onWindow = onWindow }
    final class Reader: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { if let window { onWindow?(window) } }
    }
}
