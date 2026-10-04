import CoreGraphics
import Foundation
import ImageIO

/// Golem, data-driven: `golem.json` plus stone sprites in the Avatar folder describe his poses
/// (stacks that sway, floating stones, an orbit ring), how he moves between them, and which pose
/// each mood plays. This file is the evaluator: given a time, it says where every stone is.
/// It mirrors the reference implementation the animations are designed with (golem_rig.py), so
/// what's previewed there is what plays here.
///
/// Rig px: y up from the ground, x from the centre line; angles in degrees, counter-clockwise
/// positive; seconds.
struct GolemRig {
    let spec: Spec
    let images: [String: CGImage]
    let eyeImages: [CGImage]

    /// Reads golem.json and its images from a folder; nil when there's no rig there.
    static func load(from folder: URL) -> GolemRig? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("golem.json")),
              let spec = try? JSONDecoder().decode(Spec.self, from: data) else { return nil }
        func image(_ name: String) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var images: [String: CGImage] = [:]
        for (name, stone) in spec.stones {
            guard let img = image(stone.image) else { return nil }
            images[name] = img
        }
        let eyes = spec.eyes.sprites.compactMap { image($0.image) }
        guard eyes.count == spec.eyes.sprites.count, spec.moods["idle"] != nil else { return nil }
        return GolemRig(spec: spec, images: images, eyeImages: eyes)
    }

    func height(_ stone: String) -> Double { spec.stones[stone]?.h ?? 0 }
    func nest(_ lower: String, _ upper: String) -> Double { spec.nest.k * min(height(lower), height(upper)) + spec.nest.c }
    func pose(forMood mood: String) -> String { spec.moods[mood] ?? spec.moods["idle"] ?? "" }

    // MARK: Evaluating poses

    func frame(pose name: String, at t: Double) -> GolemFrame {
        guard let pose = spec.poses[name] else { return GolemFrame(stones: [:]) }
        var out: [String: GolemStone] = [:]
        if let stack = pose.stack { evalStack(stack, t, &out) }
        if let float = pose.float { evalFloat(float, t, &out) }
        if let ring = pose.ring { evalRing(ring, t, &out) }
        let (gx, gy) = eyes(pose, t, out)
        return GolemFrame(stones: out, eyeX: gx, eyeY: gy, blink: blink(t))
    }

    private func lean(_ sw: Sway, _ f: Double, _ t: Double) -> Double {
        let ph = .tau * t / sw.period
        return sw.tip * sin(ph + (sw.tipPhase ?? 0))
            + sw.bend * pow(f, sw.bendExp) * sin(ph - sw.lag * f)
            + (sw.catch ?? 0) * f * f * sin(2 * ph - (sw.catchLag ?? 0) * f + (sw.catchPhase ?? 0))
    }

    private func evalStack(_ st: Stack, _ t: Double, _ out: inout [String: GolemStone]) {
        let sw = st.sway
        let total = st.order.reduce(0) { $0 + height($1.stone) }
        guard total > 0, let first = st.order.first else { return }
        var topX = sw.roll == true ? lean(sw, 0, t) * .pi / 180 * height(first.stone) / 2 : 0
        var topY = st.lift ?? 0
        var acc = 0.0
        var prev: String?
        for (i, entry) in st.order.enumerated() {
            let h = height(entry.stone)
            let ang = lean(sw, (acc + h / 2) / total, t)
            let a = ang * .pi / 180
            let n = prev.map { nest($0, entry.stone) } ?? 0
            let cx = topX + sin(a) * (h / 2 - n) + entry.dx * cos(a)
            let cy = topY + cos(a) * (h / 2 - n)
            topX = cx + sin(a) * h / 2
            topY = cy + cos(a) * h / 2
            out[entry.stone] = GolemStone(x: cx, y: cy, rot: -ang, depth: -0.01 * Double(i))
            prev = entry.stone
            acc += h
        }
        if let hs = st.headSwing, out["head"] != nil {
            out["head"]!.rot -= hs.amp * sin(.tau * t / sw.period - hs.phase)
        }
        if let br = st.breath, topY > 0 {
            for entry in st.order {
                guard var s = out[entry.stone] else { continue }
                let f = s.y / topY
                s.y += br.amp * f * (0.5 - 0.5 * cos(.tau * t / br.period - br.lag * f))
                out[entry.stone] = s
            }
        }
    }

    private func evalFloat(_ float: [String: Floater], _ t: Double, _ out: inout [String: GolemStone]) {
        for (name, p) in float {
            var s = GolemStone(x: p.x, y: p.y, rot: p.rot ?? 0, depth: -0.05)
            if let bob = p.bob {
                let ph = bob.phase ?? 0
                s.y += (bob.y ?? 0) * sin(.tau * t / bob.period + ph)
                s.rot += (bob.rot ?? 0) * sin(.tau * t / (bob.rotPeriod ?? bob.period) + ph)
            }
            if let pu = p.pulse {
                let v = max(0, sin(.tau * t / pu.period + (pu.phase ?? 0)))
                s.scale = 1 + pu.scale * v * v
            }
            out[name] = s
        }
    }

    private func evalRing(_ rg: Ring, _ t: Double, _ out: inout [String: GolemStone]) {
        guard let c = out[rg.around] else { return }
        let n = Double(rg.slots.count)
        for (i, name) in rg.slots.enumerated() {
            let a = Double(i) * .tau / n + .tau * t / rg.period
            let d = sin(a)
            out[name] = GolemStone(x: c.x + rg.rx * cos(a), y: c.y + rg.cy + rg.ry * d,
                                   rot: (rg.rock ?? 0) * sin(a + 0.5), scale: 1 - rg.depthScale * d,
                                   depth: d, shade: (rg.shade ?? 0) * max(0, d))
        }
    }

    private func eyes(_ pose: Pose, _ t: Double, _ stones: [String: GolemStone]) -> (Double, Double) {
        guard let e = pose.eyes else { return (0, 0) }
        var gx = 0.0, gy = 0.0
        if let look = e.look, look.count == 2 { gx += look[0]; gy += look[1] }
        if let k = e.followRing, let rg = pose.ring, let c = stones[rg.around],
           let front = rg.slots.min(by: { (stones[$0]?.depth ?? 0) < (stones[$1]?.depth ?? 0) }), let fs = stones[front] {
            gx += k * max(-1, min(1, (fs.x - c.x) / rg.rx))
        }
        if let sf = e.swayFollow, let stack = pose.stack {
            let v = sin(.tau * t / stack.sway.period - sf.lag)
            gx += sf.x * v
            gy += sf.y * abs(v)
        }
        if e.glances == true, let g = spec.eyes.glance {
            let n0 = floor(t / g.interval)
            for n in [n0 - 1, n0] {
                let tg = n * g.interval + Self.hash01(n, 3) * g.jitter
                let w = Self.window(t, tg, tg + g.hold, g.ramp)
                let side: Double = Self.hash01(n, 4) < 0.5 ? -1 : 1
                gx += side * g.x * w
                gy += g.y * w
            }
        }
        return (gx, gy)
    }

    func blink(_ t: Double) -> Double {
        guard let b = spec.eyes.blink else { return 0 }
        let n0 = floor(t / b.interval)
        var v = 0.0
        for n in [n0 - 1, n0] {
            let tb = n * b.interval + Self.hash01(n, 1) * b.jitter
            v = max(v, Self.pulse(t, tb, b.duration))
            if Self.hash01(n, 2) < b.doubleChance { v = max(v, Self.pulse(t, tb + b.doubleGap, b.duration)) }
        }
        return v
    }

    func transitionSpec(_ from: String, _ to: String) -> TransitionSpec {
        let base = spec.transitions["default"] ?? TransitionSpec()
        return spec.transitions["\(from)>\(to)"].map { base.overlaid(by: $0) } ?? base
    }

    // MARK: Easing (identical to the reference)

    static func clamp01(_ u: Double) -> Double { min(1, max(0, u)) }
    static func smooth(_ u: Double) -> Double { let u = clamp01(u); return u * u * (3 - 2 * u) }
    static func smoother(_ u: Double) -> Double { let u = clamp01(u); return u * u * u * (u * (6 * u - 15) + 10) }
    static func outBack(_ u: Double, _ k: Double = 1.9) -> Double { let u = clamp01(u) - 1; return 1 + u * u * ((k + 1) * u + k) }
    static func pulse(_ t: Double, _ at: Double, _ dur: Double) -> Double {
        let u = (t - at) / dur
        return (0...1).contains(u) ? pow(sin(.pi * u), 2) : 0
    }
    static func window(_ t: Double, _ a: Double, _ b: Double, _ ramp: Double) -> Double {
        smooth((t - a) / ramp) * (1 - smooth((t - (b - ramp)) / ramp))
    }
    static func hash01(_ n: Double, _ salt: Double) -> Double {
        let v = sin(n * 12.9898 + salt * 78.233) * 43758.5453
        return v - floor(v)
    }
}

private extension Double { static let tau = Double.pi * 2 }

struct GolemStone {
    var x: Double
    var y: Double
    var rot: Double = 0
    var scale: Double = 1
    /// + flatter (the bottom stays put), - stretched.
    var squash: Double = 0
    /// + farther away, drawn first.
    var depth: Double = 0
    /// 0…1 darkening.
    var shade: Double = 0
}

struct GolemFrame {
    var stones: [String: GolemStone]
    var eyeX = 0.0
    var eyeY = 0.0
    var blink = 0.0
}

// MARK: - Transitions

/// Any pose (or a frozen moment, when re-routing mid-move) to any pose.
struct GolemTransition {
    let rig: GolemRig
    let from: String
    let to: String
    let start: Double
    let spec: TransitionSpec.Resolved
    let snapshot: GolemFrame?
    private(set) var duration = 0.0
    private var departRank: [String: Int] = [:]
    private var arriveRank: [String: Int] = [:]
    private var aRank: [String: Int] = [:]
    private var base = ""
    private var dist: [String: Double] = [:]
    private var side: [String: Double] = [:]
    private var schedule: [String: (start: Double, duration: Double, outBack: Bool)] = [:]
    private var stackAbove: [String] = []
    private var landing: Set<String> = []

    init(rig: GolemRig, from: String, to: String, start: Double, spec: TransitionSpec, snapshot: GolemFrame? = nil) {
        self.rig = rig; self.from = from; self.to = to; self.start = start; self.spec = spec.resolved; self.snapshot = snapshot
        let a = snapshot ?? rig.frame(pose: from, at: start)
        let b = rig.frame(pose: to, at: start)
        let names = b.stones.keys.sorted()
        func y(_ f: GolemFrame, _ s: String) -> Double { f.stones[s]?.y ?? 0 }
        for (i, s) in names.sorted(by: { y(a, $0) > y(a, $1) }).enumerated() { departRank[s] = i }
        for (i, s) in names.sorted(by: { y(b, $0) < y(b, $1) }).enumerated() { arriveRank[s] = i }
        for (i, s) in names.sorted(by: { y(a, $0) < y(a, $1) }).enumerated() { aRank[s] = i }
        base = names.min(by: { y(a, $0) - rig.height($0) / 2 < y(a, $1) - rig.height($1) / 2 }) ?? ""
        let sp = self.spec
        for s in names {
            let sa = a.stones[s] ?? GolemStone(x: 0, y: 0), sb = b.stones[s] ?? sa
            dist[s] = hypot(sb.x - sa.x, sb.y - sa.y)
            let dx = sb.x - sa.x
            let alternate: Double = departRank[s]! % 2 == 1 ? 1 : -1
            side[s] = sp.sides == "alternate" || abs(dx) <= 40 ? alternate : (dx > 0 ? 1 : -1)
            if let lead = sp.lead, lead.stone == s {
                schedule[s] = (lead.start, lead.duration, lead.ease == "outBack")
            } else if sp.mode == "launch" {
                schedule[s] = (sp.antic + sp.hold + Double(arriveRank[s]!) * sp.arriveGap, sp.fallIn, false)
            } else {
                let dep = sp.antic + Double(departRank[s]!) * sp.departGap
                let end = sp.antic + sp.arriveStart + Double(arriveRank[s]!) * sp.arriveGap + sp.fly
                schedule[s] = (dep, max(0.45, end - dep), false)
            }
        }
        duration = (schedule.values.map { $0.start + $0.duration }.max() ?? 0) + sp.landDuration
        if snapshot == nil, let order = rig.spec.poses[from]?.stack?.order { stackAbove = order.dropFirst().map(\.stone) }
        landing = Set(rig.spec.poses[to]?.stack?.order.map(\.stone) ?? [])
    }

    func isDone(at t: Double) -> Bool { t - start >= duration }

    private func squash(_ tau: Double) -> Double {
        guard spec.antic > 0 else { return 0 }
        return spec.squash * GolemRig.smooth(tau / spec.antic) * (1 - GolemRig.smooth((tau - spec.antic) / 0.06))
    }

    func frame(at t: Double) -> GolemFrame {
        typealias R = GolemRig
        let tau = t - start
        let a = snapshot ?? rig.frame(pose: from, at: t)
        let b = rig.frame(pose: to, at: t)
        let sp = spec
        var out: [String: GolemStone] = [:]
        for (s, sb) in b.stones {
            var sa = a.stones[s] ?? sb
            if sp.antic > 0 && snapshot == nil {
                if s == base {
                    sa.squash += squash(tau)
                } else if let i = stackAbove.firstIndex(of: s) {
                    let lag = 0.045 * Double(i + 1)
                    let drop = tau < sp.antic + 0.1 ? rig.height(base) * max(0, squash(tau - lag)) : 0
                    sa.y -= drop * (1 + 0.22 * Double(i))
                    let u = (tau - sp.antic + 0.12 - lag) / 0.2
                    if (0...1).contains(u) && tau < sp.antic { sa.y += 6 * Double(i + 1) * sin(.pi * u) }
                }
            }
            if sp.mode == "launch", sp.lead?.stone != s, let L = sp.launch {
                let tl = tau - sp.antic
                if tl > 0 {
                    let r = Double(max(0, aRank[s, default: 0] - 1))
                    let ta = L.tApex + L.tApexPerRank * r, ap = L.apex + L.apexPerRank * r
                    let g = 2 * ap / (ta * ta)
                    sa.y += g * ta * tl - 0.5 * g * tl * tl
                    sa.x += side[s, default: 1] * L.spread * R.smoother(tl / (ta + 0.3))
                    sa.rot += side[s, default: 1] * -40 * R.smoother(tl / (ta + 0.4))
                }
            }
            let sched = schedule[s] ?? (0, 1, false)
            let u = (tau - sched.start) / sched.duration
            var m = sched.outBack ? R.outBack(u) : R.smoother(u)
            if tau < sched.start { m = 0 }
            let k = min(1, dist[s, default: 0] / sp.arcDistance)
            let bump = u > 0 && u < 1 ? sin(.pi * R.clamp01(u)) : 0
            let mc = R.clamp01(m)
            var st = GolemStone(x: sa.x + (sb.x - sa.x) * m + side[s, default: 1] * sp.fling * k * bump,
                                y: sa.y + (sb.y - sa.y) * m + sp.arc * k * bump,
                                rot: sa.rot + (sb.rot - sa.rot) * m,
                                scale: sa.scale + (sb.scale - sa.scale) * m,
                                squash: sa.squash * (1 - mc),
                                depth: sa.depth + (sb.depth - sa.depth) * mc,
                                shade: sa.shade + (sb.shade - sa.shade) * mc)
            if sched.outBack && sp.mode == "launch" {
                let v = (tau - sched.start) / 0.32
                if (0...1).contains(v) { st.squash -= 0.08 * sin(.pi * v) * (1 - 0.4 * v) }
            }
            let since = tau - (sched.start + sched.duration)
            if landing.contains(s) && since >= 0 && since <= sp.landDuration {
                st.squash += sp.landSquash * sin(.pi * since / sp.landDuration)
            }
            st.y = max(st.y, rig.height(s) * st.scale / 2)   // nothing sinks below the ground
            out[s] = st
        }
        let p = R.smoother(tau / duration)
        let squint = sp.antic > 0 ? 0.55 * R.smooth(tau / sp.antic) * (1 - R.smooth((tau - sp.antic) / 0.1)) : 0
        return GolemFrame(stones: out, eyeX: a.eyeX + (b.eyeX - a.eyeX) * p, eyeY: a.eyeY + (b.eyeY - a.eyeY) * p,
                     blink: max(rig.blink(t), squint))
    }
}

/// The runtime state machine: set a mood whenever; it plays the right transition, or re-routes
/// from wherever the stones are if the mood changes mid-move.
final class GolemPlayer {
    private(set) var rig: GolemRig
    private(set) var pose: String
    private var transition: GolemTransition?

    init(rig: GolemRig, mood: String) {
        self.rig = rig
        pose = rig.pose(forMood: mood)
    }

    /// A reloaded rig takes over without a jump when the current pose still exists.
    func replace(rig: GolemRig, mood: String) {
        self.rig = rig
        transition = nil
        pose = rig.pose(forMood: mood)
    }

    func setMood(_ mood: String, at t: Double) {
        let target = rig.pose(forMood: mood)
        if let current = transition {
            guard target != current.to else { return }
            transition = GolemTransition(rig: rig, from: current.to, to: target, start: t,
                                         spec: rig.transitionSpec("*", "*"), snapshot: current.frame(at: t))
        } else {
            guard target != pose else { return }
            transition = GolemTransition(rig: rig, from: pose, to: target, start: t, spec: rig.transitionSpec(pose, target))
        }
        pose = target
    }

    func frame(at t: Double) -> GolemFrame {
        if let current = transition, current.isDone(at: t) { transition = nil }
        return transition?.frame(at: t) ?? rig.frame(pose: pose, at: t)
    }
}

// MARK: - golem.json

extension GolemRig {
    struct Spec: Decodable {
        var pixelScale: Double
        var stage: Stage
        var stones: [String: Stone]
        var eyes: Eyes
        var nest: Nest
        var poses: [String: Pose]
        var moods: [String: String]
        var transitions: [String: TransitionSpec]
    }
    struct Stage: Decodable { var size: Double; var groundFromTop: Double }
    struct Stone: Decodable { var image: String; var w: Double; var h: Double }
    struct Nest: Decodable { var k: Double; var c: Double }
    struct Eyes: Decodable {
        var on: String
        var sprites: [EyeSprite]
        var blink: Blink?
        var glance: Glance?
    }
    struct EyeSprite: Decodable { var image: String; var x: Double; var y: Double; var w: Double; var h: Double }
    struct Blink: Decodable { var interval, jitter, duration, doubleChance, doubleGap: Double }
    struct Glance: Decodable { var interval, jitter, hold, ramp, x, y: Double }

    struct Pose: Decodable {
        var stack: Stack?
        var float: [String: Floater]?
        var ring: Ring?
        var eyes: PoseEyes?
    }
    struct Stack: Decodable {
        var order: [OrderEntry]
        var sway: Sway
        var breath: Breath?
        var headSwing: HeadSwing?
        var lift: Double?
    }
    /// `["belly", -6]`: a stone and its sideways nudge.
    struct OrderEntry: Decodable {
        var stone: String
        var dx: Double
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            stone = try c.decode(String.self)
            dx = c.isAtEnd ? 0 : try c.decode(Double.self)
        }
    }
    struct Sway: Decodable {
        var period, tip, bend, bendExp, lag: Double
        var tipPhase, `catch`, catchLag, catchPhase: Double?
        var roll: Bool?
    }
    struct Breath: Decodable { var amp, period, lag: Double }
    struct HeadSwing: Decodable { var amp, phase: Double }
    struct Floater: Decodable {
        var x, y: Double
        var rot: Double?
        var bob: Bob?
        var pulse: Pulse?
    }
    struct Bob: Decodable { var y, rot: Double?; var period: Double; var rotPeriod, phase: Double? }
    struct Pulse: Decodable { var scale, period: Double; var phase: Double? }
    struct Ring: Decodable {
        var around: String
        var cy, rx, ry, period, depthScale: Double
        var shade, rock: Double?
        var slots: [String]
    }
    struct PoseEyes: Decodable {
        var look: [Double]?
        var followRing: Double?
        var swayFollow: SwayFollow?
        var glances: Bool?
    }
    struct SwayFollow: Decodable { var x, y, lag: Double }
}

/// One transition's numbers. Pair entries ("cairn>balance") only list what differs from "default".
struct TransitionSpec: Decodable {
    var mode: String?
    var antic, squash: Double?
    var departGap, arriveStart, arriveGap, fly: Double?
    var arc, fling, arcDistance: Double?
    var hold, fallIn: Double?
    var sides: String?
    var lead: Lead?
    var launch: Launch?
    var land: Land?

    struct Lead: Decodable { var stone: String; var start: Double; var duration: Double; var ease: String? }
    struct Launch: Decodable { var apex, apexPerRank, tApex, tApexPerRank, spread: Double }
    struct Land: Decodable { var squash, duration: Double }

    func overlaid(by o: TransitionSpec) -> TransitionSpec {
        TransitionSpec(mode: o.mode ?? mode, antic: o.antic ?? antic, squash: o.squash ?? squash,
                       departGap: o.departGap ?? departGap, arriveStart: o.arriveStart ?? arriveStart,
                       arriveGap: o.arriveGap ?? arriveGap, fly: o.fly ?? fly, arc: o.arc ?? arc, fling: o.fling ?? fling,
                       arcDistance: o.arcDistance ?? arcDistance, hold: o.hold ?? hold, fallIn: o.fallIn ?? fallIn,
                       sides: o.sides ?? sides, lead: o.lead ?? lead, launch: o.launch ?? launch, land: o.land ?? land)
    }

    struct Resolved {
        var mode: String, antic, squash, departGap, arriveStart, arriveGap, fly, arc, fling, arcDistance, hold, fallIn: Double
        var sides: String?, lead: Lead?, launch: Launch?, landSquash, landDuration: Double
        init(_ s: TransitionSpec) {
            mode = s.mode ?? "sequence"; antic = s.antic ?? 0; squash = s.squash ?? 0
            departGap = s.departGap ?? 0.12; arriveStart = s.arriveStart ?? 0.35; arriveGap = s.arriveGap ?? 0.22
            fly = s.fly ?? 0.85; arc = s.arc ?? 110; fling = s.fling ?? 70; arcDistance = max(1, s.arcDistance ?? 400)
            hold = s.hold ?? 0.24; fallIn = s.fallIn ?? 0.8; sides = s.sides; lead = s.lead; launch = s.launch
            landSquash = s.land?.squash ?? 0.06; landDuration = s.land?.duration ?? 0.3
        }
    }
    var resolved: Resolved { Resolved(self) }
}
