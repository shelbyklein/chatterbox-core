import SwiftUI

/// How hard the Mac is working, from the chat list (Companion.Pressure): in the Activity header
/// a dot and "Mac busy" or "Mac overloaded" while it's under pressure; tapped, the readings and
/// what Chatterbox is holding back.
extension Companion.Pressure {
    var color: Color { level == "overloaded" ? .red : level == "busy" ? .orange : .green }
}

struct MobilePressurePill: View {
    let pressure: Companion.Pressure
    var stale = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(stale ? Color.secondary : pressure.color).frame(width: 8, height: 8)
            Text(pressure.isOK ? pressure.reading : "\(pressure.label) · \(pressure.reading)").monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(stale ? Color.secondary : pressure.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(pressure.color.opacity(stale ? 0.06 : 0.14)))
    }
}

struct MobilePressureSheet: View {
    let pressure: Companion.Pressure
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(pressure.color).frame(width: 10, height: 10)
                        Text(pressure.label).font(.headline)
                        Spacer()
                        if let since = pressure.since, !pressure.isOK {
                            Text("since \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !pressure.isOK { Text(pressure.summary).font(.subheadline) }
                }
                Section("Holding back") {
                    if pressure.holding.isEmpty {
                        Text("Nothing").foregroundStyle(.secondary)
                    }
                    ForEach(pressure.holding, id: \.self) { line in
                        Label(line, systemImage: "pause.circle")
                    }
                }
                Section("Readings") {
                    LabeledContent("Load", value: "\(Self.number(pressure.load1)) · \(Self.number(pressure.load5)) · \(Self.number(pressure.load15)) on \(pressure.cores) cores")
                    LabeledContent("Memory", value: pressure.memory.capitalized + (pressure.compressedGB.map { ", \(Self.number($0)) GB compressed" } ?? ""))
                    LabeledContent("Swap", value: "\(Self.number(pressure.swapUsedGB)) GB" + (pressure.swapGrowthGB > 0 ? ", +\(Self.number(pressure.swapGrowthGB)) GB in 5 min" : ""))
                    LabeledContent("Thermal", value: pressure.thermal.capitalized)
                }
                Section {
                    Text("Chatterbox on the Mac holds its own work back while the Mac is under pressure: builds, simulators and work threads. A running build or reply is never stopped.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mac load").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    static func number(_ value: Double) -> String { value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value) }
}
