import AppKit
import Observation
import SwiftUI

struct CommandCenterSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var sessionID: UUID
}

/// Saved UUID references only. Managing the grid never mutates a chat or its folder.
@MainActor @Observable
final class CommandCenterLayout {
    private(set) var slots: [CommandCenterSlot]
    var activeID: UUID?
    var singleRow: Bool { didSet { defaults.set(singleRow, forKey: "commandCenterSingleRow") } }
    var columns: Int { didSet { defaults.set(columns, forKey: "commandCenterColumns") } }
    var tileHeight: Double { didSet { defaults.set(tileHeight, forKey: "commandCenterTileHeight") } }
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var sessions = Set<UUID>()
        var ids = Set<UUID>()
        let saved = defaults.data(forKey: "commandCenterSlots").flatMap { try? JSONDecoder().decode([CommandCenterSlot].self, from: $0) } ?? []
        let restored = saved.filter { sessions.insert($0.sessionID).inserted && ids.insert($0.id).inserted }
        slots = restored
        activeID = restored.first?.id
        singleRow = defaults.bool(forKey: "commandCenterSingleRow")
        columns = min(4, max(1, defaults.object(forKey: "commandCenterColumns") as? Int ?? 2))
        tileHeight = min(900, max(400, defaults.object(forKey: "commandCenterTileHeight") as? Double ?? 560))
    }
    @discardableResult func add(_ sessionID: UUID) -> UUID {
        if let existing = slots.first(where: { $0.sessionID == sessionID }) { activeID = existing.id; return existing.id }
        let slot = CommandCenterSlot(sessionID: sessionID)
        slots.append(slot); activeID = slot.id; save()
        return slot.id
    }
    @discardableResult func replace(_ slotID: UUID, with sessionID: UUID) -> Bool {
        guard let index = slots.firstIndex(where: { $0.id == slotID }),
              !slots.contains(where: { $0.id != slotID && $0.sessionID == sessionID }) else { return false }
        slots[index].sessionID = sessionID; activeID = slotID; save(); return true
    }
    func remove(_ slotID: UUID) {
        slots.removeAll { $0.id == slotID }
        if activeID == slotID { activeID = slots.first?.id }
        save()
    }
    func reconcile(available: Set<UUID>) {
        let missing = slots.filter { !available.contains($0.sessionID) }.map(\.id)
        for id in missing { remove(id) }
    }
    static func fittingColumns(requested: Int, width: CGFloat) -> Int {
        min(max(1, requested), max(1, Int((width - 32 + 16) / (400 + 16))))
    }
    private func save() { if let data = try? JSONEncoder().encode(slots) { defaults.set(data, forKey: "commandCenterSlots") } }
}

struct CommandCenterTileContext {
    let isActive: Bool
    let activate: () -> Void
}
private struct CommandCenterTileKey: EnvironmentKey { static let defaultValue: CommandCenterTileContext? = nil }
extension EnvironmentValues {
    var commandCenterTile: CommandCenterTileContext? {
        get { self[CommandCenterTileKey.self] }
        set { self[CommandCenterTileKey.self] = newValue }
    }
}

private struct ThreadChoice: Identifiable {
    var id = UUID()
    var slotID: UUID?
}

struct CommandCenterView: View {
    @Environment(AppModel.self) private var model
    @Bindable var layout: CommandCenterLayout
    @State private var choice: ThreadChoice?

    var body: some View {
        GeometryReader { geometry in
            let columns = CommandCenterLayout.fittingColumns(requested: layout.columns, width: geometry.size.width)
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack { heading; Spacer(); controls }
                    VStack(alignment: .leading, spacing: 12) { heading; controls }
                }.padding(16)
                Divider()
                if layout.slots.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.split.2x2").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Your chats, side by side").font(.title2.weight(.semibold))
                        Text("Add projects or threads. Each keeps its own conversation and message box.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Add chat", systemImage: "plus") { choice = ThreadChoice() }.buttonStyle(.borderedProminent)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { area in
                        ScrollViewReader { proxy in
                            ScrollView(layout.singleRow ? .horizontal : .vertical) {
                                if layout.singleRow {
                                    HStack(spacing: 16) {
                                        tiles(width: max(400, (area.size.width - 32 - CGFloat(max(0, layout.slots.count - 1)) * 16) / CGFloat(max(1, layout.slots.count))),
                                              height: max(0, area.size.height - 32))
                                    }.padding(16)
                                } else {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: columns), spacing: 16) {
                                        tiles(width: nil, height: layout.tileHeight)
                                    }.padding(16)
                                }
                            }
                            .onChange(of: layout.slots.map(\.id)) { old, new in
                                if new.count > old.count, let added = layout.activeID { proxy.scrollTo(added, anchor: .center) }
                            }
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Command Center")
        .onAppear { layout.reconcile(available: Set(model.activeSessions.map(\.id))) }
        .onChange(of: model.activeSessions.map(\.id)) { _, ids in layout.reconcile(available: Set(ids)) }
        .sheet(item: $choice) { request in
            CommandCenterThreadChooser(excluded: Set(layout.slots.filter { $0.id != request.slotID }.map(\.sessionID))) { session in
                if let id = request.slotID { _ = layout.replace(id, with: session.id) } else { layout.add(session.id) }
                choice = nil
            }
        }
    }
    @ViewBuilder private func tiles(width: CGFloat?, height: CGFloat) -> some View {
        ForEach(layout.slots) { slot in
            if let session = model.sessions.first(where: { $0.id == slot.sessionID }) {
                CommandCenterTile(session: session, active: layout.activeID == slot.id,
                    activate: { layout.activeID = slot.id },
                    switchThread: { choice = ThreadChoice(slotID: slot.id) },
                    remove: { layout.remove(slot.id) })
                    .frame(width: width, height: height)
                    .id(slot.id)
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Command Center").font(.title.weight(.bold))
            Text("\(layout.slots.count) chats · Click a message box to focus that thread")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Arrangement", selection: $layout.singleRow) {
                    Text("Grid").tag(false)
                    Text("Single row · Fill height").tag(true)
                }
                Picker("Columns", selection: $layout.columns) {
                    ForEach(1...4, id: \.self) { Text("\($0) columns").tag($0) }
                }
                .disabled(layout.singleRow)
                Picker("Tile height", selection: $layout.tileHeight) {
                    Text("Compact").tag(420.0)
                    Text("Roomy").tag(560.0)
                    Text("Tall").tag(800.0)
                }
                .disabled(layout.singleRow)
            } label: { Label("Layout", systemImage: "rectangle.split.2x2") }
            Button("Add chat", systemImage: "plus") { choice = ThreadChoice() }
                .accessibilityLabel("Add Command Center chat")
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CommandCenterDebug.add = $0 }
                #endif
            Button("Home", systemImage: "house") { model.showingHome = true }
        }
    }
}

struct CommandCenterTile: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    let active: Bool
    let activate: () -> Void
    let switchThread: () -> Void
    let remove: () -> Void
    private var title: String { session.record.projectFolder != nil ? session.projectName : session.title }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(session.record.backend.iconName).resizable().scaledToFit().frame(width: 15, height: 15)
                    .foregroundStyle(session.record.backend == .codex ? Color.green : Color.orange)
                Button(action: switchThread) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }.buttonStyle(.plain).help("Switch this tile to another project or thread")
                    .accessibilityLabel("Switch thread in \(title) tile")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CommandCenterDebug.switches[session.id] = $0 }
                    #endif
                Spacer(minLength: 4)
                if session.isWaitingOnYou { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).help("Needs you") }
                else if session.isRunning { ActivitySpinner(color: session.record.backend == .codex ? .green : .orange).frame(width: 12, height: 12) }
                Button { model.selectedID = session.id } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Open this thread in the full chat view").accessibilityLabel("Expand \(title)")
                Button(action: remove) { Image(systemName: "xmark") }
                    .help("Remove tile; keep the thread and any running reply").accessibilityLabel("Remove \(title) tile")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CommandCenterDebug.removes[session.id] = $0 }
                    #endif
            }.buttonStyle(.borderless).padding(12).frame(height: 44)
            Divider()
            if session.isDot && model.showingDot {
                VStack(spacing: 12) {
                    #if GOLEM_APP
                    GolemHead(size: 40)
                    #else
                    Image(systemName: "bubble.left").font(.largeTitle)
                    #endif
                    Text("\(model.dotName) is in the mini window")
                    Button("Bring Chat Here") { model.showingDot = false }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatView(session: session).id(session.id)
                    .environment(\.compactChat, true)
                    .environment(\.commandCenterTile, CommandCenterTileContext(isActive: active, activate: activate))
                    .environment(\.chatSwitchCoordinator, nil)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: active ? 2 : 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) chat tile")
        .accessibilityValue(active ? "Active" : "Inactive")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CommandCenterDebug.tiles[session.id] = $0 }
        #endif
    }
}

struct CommandCenterThreadChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let excluded: Set<UUID>
    let select: (ChatSession) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose a project or thread").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            TextField("Search projects, Studios and chats", text: $search).textFieldStyle(.roundedBorder)
            List {
                let groups = HomeThreads.groups(model, search: search)
                if groups.isEmpty { Text("No matching projects or threads").foregroundStyle(.secondary) }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.threads) { session in
                            Button { select(session) } label: {
                                HStack {
                                    Image(session.record.backend.iconName).resizable().scaledToFit().frame(width: 15, height: 15)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.record.projectFolder != nil ? session.projectName : session.title).lineLimit(1)
                                        if let branch = session.record.worktreeBranch { Label(branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary) }
                                        else if session.record.sidechatOf != nil { Text("Temporary Sidechat").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if excluded.contains(session.id) { Text("Already in grid").font(.caption).foregroundStyle(.secondary) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(excluded.contains(session.id))
                            #if DEBUG
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CommandCenterDebug.choices[session.id] = $0 }
                            #endif
                        }
                    }
                }
            }
        }.padding(20).frame(width: 540, height: 560).background(Color(nsColor: .windowBackgroundColor))
        #if DEBUG
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { CommandCenterDebug.chooserOrigin = $0 }
        #endif
    }
}

#if DEBUG
@MainActor enum CommandCenterDebug {
    static var tiles: [UUID: CGRect] = [:]
    static var choices: [UUID: CGRect] = [:]
    static var switches: [UUID: CGRect] = [:]
    static var removes: [UUID: CGRect] = [:]
    static var add: CGRect = .zero
    static var chooserOrigin: CGPoint = .zero
}
#endif

/// Embedded chats supply their tile header, without competing for the window title.
struct ChatWindowTitle: ViewModifier {
    let title: String
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content } else { content.navigationTitle(title) }
    }
}
