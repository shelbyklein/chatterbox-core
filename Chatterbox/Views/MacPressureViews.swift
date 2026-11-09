import SwiftUI

/// How hard the Mac is working, as the background service sees it (PressureMonitor), for the
/// toolbar's status area and the menu bar panel: a dot (and, under pressure, "Mac busy" or "Mac
/// overloaded"); click for the readings and what Chatterbox is holding back. The service sends
/// "pressure.changed" when the level or what's held changes; the app asks once on connecting.
@MainActor
@Observable
final class MacPressureModel {
    static let shared = MacPressureModel()
    private(set) var pressure: Companion.Pressure?

    /// From AppModel.runtimeEvent: every event the service sends the app.
    func runtimeEvent(_ event: RuntimeEvent) {
        switch event.kind {
        case "pressure.changed":
            if let pressure = try? event.payload?.decode(Companion.Pressure.self) { self.pressure = pressure }
        case "runtime.resync":
            refresh()
        default:
            break
        }
    }

    func refresh() {
        Task { @MainActor in
            guard let reply = try? await RuntimeClient.shared.request("pressure", timeout: .seconds(5)) else { return }
            pressure = try? reply.decode(Companion.Pressure.self)
        }
    }

    /// For render tests and previews.
    func show(_ pressure: Companion.Pressure?) { self.pressure = pressure }
}

extension Companion.Pressure {
    var color: Color { level == "overloaded" ? .red : level == "busy" ? .orange : .green }
}

/// The dot, with "Mac busy"/"Mac overloaded" beside it under pressure; a click shows the readings.
struct MacPressureBadge: View {
    var model = MacPressureModel.shared
    /// The menu bar panel's row shows the label always ("Mac OK" too).
    var alwaysLabelled = false
    @State private var open = false

    var body: some View {
        if let pressure = model.pressure {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Circle().fill(pressure.color).frame(width: 8, height: 8)
                    // Always a reading, so the Mac's load is visible at a glance; the level's name too when it isn't OK.
                    Text(alwaysLabelled || !pressure.isOK ? "\(pressure.label) · \(pressure.reading)" : pressure.reading)
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(pressure.isOK ? Color.secondary : pressure.color)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(pressure.label): \(pressure.summary)")
            .accessibilityLabel("\(pressure.label), \(pressure.summary)")
            .accessibilityIdentifier("mac-pressure")
            .popover(isPresented: $open, arrowEdge: .bottom) { MacPressureDetails(pressure: pressure).padding(14).frame(width: 320) }
        }
    }
}

/// The readings and what's held back.
struct MacPressureDetails: View {
    let pressure: Companion.Pressure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(pressure.color).frame(width: 9, height: 9)
                Text(pressure.label).font(.headline)
                Spacer()
                if let since = pressure.since, !pressure.isOK {
                    Text("since \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !pressure.isOK { Text(pressure.summary).font(.callout) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Load", "\(Self.number(pressure.load1)) · \(Self.number(pressure.load5)) · \(Self.number(pressure.load15)) on \(pressure.cores) cores")
                if let cpu = pressure.cpuPercent { row("CPU", "\(cpu)% in use") }
                row("Memory", (pressure.memoryPercent.map { "\($0)% used, pressure " + pressure.memory } ?? pressure.memory.capitalized)
                    + (pressure.compressedGB.map { ", \(Self.number($0)) GB compressed" } ?? ""))
                row("Swap", "\(Self.number(pressure.swapUsedGB)) GB used" + (pressure.swapGrowthGB > 0 ? ", +\(Self.number(pressure.swapGrowthGB)) GB in 5 min" : ""))
                row("Thermal", pressure.thermal.capitalized)
            }
            .font(.caption)
            if !pressure.holding.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Holding back").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(pressure.holding, id: \.self) { line in
                        Label(line, systemImage: "pause.circle").font(.caption)
                    }
                }
            } else {
                Text("Nothing held back.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
    }

    static func number(_ value: Double) -> String { value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value) }
}
