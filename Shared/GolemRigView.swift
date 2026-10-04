import SwiftUI
#if os(macOS)
import AppKit
#endif

#if DEBUG
private struct GolemTestReduceMotion:EnvironmentKey {static let defaultValue=false}
extension EnvironmentValues {
    var golemTestReduceMotion:Bool {get{self[GolemTestReduceMotion.self]} set{self[GolemTestReduceMotion.self]=newValue}}
}
#endif

/// A timer schedule performs no display-link work between character frames.
private struct GolemSchedule:TimelineSchedule {
    let interval:TimeInterval
    let paused:Bool
    func entries(from startDate:Date,mode:Mode)->AnySequence<Date> {
        AnySequence {
            var date=startDate
            var first=true
            return AnyIterator<Date> {
                guard first || !paused else{return nil}
                first=false;defer{date.addTimeInterval(interval)};return date
            }
        }
    }
}

/// Golem drawn live from his rig: five stones and two eyes on a Canvas, moved by `GolemPlayer`.
/// Square, transparent around him, on the same stage the old videos used (2.7 heads wide, his
/// base 85% of the way down), so he sits in the same spot. Changing `mood` plays the transition.
struct GolemRigView: View {
    let rig: GolemRig
    let mood: String
    @State private var player: GolemPlayer?
    @State private var clockStart = Date()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    #if DEBUG
    @Environment(\.golemTestReduceMotion) private var testReduceMotion
    private var reduceMotion:Bool{systemReduceMotion || testReduceMotion}
    #else
    private var reduceMotion:Bool{systemReduceMotion}
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible=false
    @State private var windowVisible=true
    private var sceneHidden:Bool {
        #if os(macOS)
        // The mini is an AppKit NSHostingView outside a SwiftUI Scene. Its
        // default scenePhase is background even while its panel is visible.
        return false
        #else
        return scenePhase == .background
        #endif
    }

    var body: some View {
        TimelineView(GolemSchedule(interval:mood == "idle" ? 1 / 12 : 1 / 24,paused:reduceMotion || !visible || !windowVisible || sceneHidden)){timeline in
            let t=reduceMotion ? 0:timeline.date.timeIntervalSince(clockStart)
            if let player,visible,windowVisible,!sceneHidden {GolemFrameCanvas(rig:rig,frame:player.frame(at:t))}
        }
        .aspectRatio(1, contentMode: .fit)
        #if os(macOS)
        .background(GolemWindowVisibility(visible:$windowVisible))
        #endif
        .onAppear {
            visible=true
            if player == nil { player = GolemPlayer(rig: rig, mood: mood) }
        }
        .onDisappear{visible=false}
        .onChange(of: mood) { _, newMood in
            player?.setMood(newMood, at: Date().timeIntervalSince(clockStart))
        }
        .accessibilityLabel("Golem, \(mood)")
    }
}

#if os(macOS)
/// SwiftUI onDisappear does not fire when an attached Mac window is minimized
/// or covered. Observe this rig's own window, including floating mini panels.
private struct GolemWindowVisibility:NSViewRepresentable {
    @Binding var visible:Bool
    func makeNSView(context:Context)->ObserverView {
        let view=ObserverView();view.changed={value in
            DispatchQueue.main.async {self.visible=value}
        };return view
    }
    func updateNSView(_ view:ObserverView,context:Context){view.refresh()}
    final class ObserverView:NSView {
        var changed:((Bool)->Void)?
        private var observers:[NSObjectProtocol]=[]
        private var lastVisibility:Bool?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers{NotificationCenter.default.removeObserver(observer)}
            observers=[]
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){[weak self] _ in
                        MainActor.assumeIsolated {self?.refresh()}
                    })
                }
            }
            refresh()
        }
        func refresh(){
            let value=window.map{$0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)} ?? false
            guard value != lastVisibility else{return}
            lastVisibility=value;changed?(value)
        }
        deinit{for observer in observers{NotificationCenter.default.removeObserver(observer)}}
    }
}
#endif

/// One moment of Golem, drawn: stones back to front by depth, the eyes on his head.
struct GolemFrameCanvas: View {
    let rig: GolemRig
    let frame: GolemFrame

    var body: some View {
        Canvas { context, size in draw(frame, in: &context, size: size) }
    }

    private func draw(_ frame: GolemFrame, in context: inout GraphicsContext, size: CGSize) {
        #if DEBUG && os(macOS)
        GolemRenderMetrics.shared.record()
        #endif
        let side = min(size.width, size.height)
        let unit = side / rig.spec.stage.size
        let ground = side * rig.spec.stage.groundFromTop
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        for (name, s) in frame.stones.sorted(by: { $0.value.depth > $1.value.depth }) {
            guard let stone = rig.spec.stones[name], let image = rig.images[name] else { continue }
            let w = stone.w, h = stone.h
            let sx = unit * s.scale * (1 + s.squash * 0.6), sy = unit * s.scale * (1 - s.squash)
            // Squash keeps the bottom of the stone where it was.
            let cy = s.y - h * s.scale * s.squash / 2
            var g = context
            g.translateBy(x: origin.x + side / 2 + s.x * unit, y: origin.y + ground - cy * unit)
            g.rotate(by: .degrees(-s.rot))
            g.scaleBy(x: sx, y: sy)
            if s.shade > 0 { g.addFilter(.colorMultiply(Color(white: 1 - s.shade))) }
            g.draw(Image(decorative: image, scale: 1).interpolation(.high), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            if name == rig.spec.eyes.on {
                let open = max(0.08, 1 - frame.blink * 0.95)
                for (sprite, eye) in zip(rig.spec.eyes.sprites, rig.eyeImages) {
                    let ex = sprite.x - w / 2 + frame.eyeX
                    let ey = sprite.y - h / 2 + frame.eyeY + frame.blink * 4
                    let eh = sprite.h * open
                    g.draw(Image(decorative: eye, scale: 1).interpolation(.high),
                           in: CGRect(x: ex - sprite.w / 2, y: ey - eh / 2, width: sprite.w, height: eh))
                }
            }
        }
    }
}

#if DEBUG && os(macOS)
final class GolemRenderMetrics:@unchecked Sendable {
    static let shared=GolemRenderMetrics()
    private let lock=NSLock()
    private var count=0
    func record(){lock.lock();count += 1;lock.unlock()}
    var draws:Int{lock.lock();defer{lock.unlock()};return count}
}
#endif
