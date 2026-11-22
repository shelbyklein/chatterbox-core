#if canImport(SwiftUI)
import Charts
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders a fenced ```a2ui block as a native interactive SwiftUI surface on Mac and iOS,
/// supporting the A2UI standard catalog plus native Swift Charts.
struct A2UISurfaceView: View {
    let source: String
    let surface: A2UISurface
    let closed: Bool
    let paths: PathLinks

    @Environment(\.readerStyle) private var style
    @Environment(\.replyActions) private var replyActions
    @State private var store: A2UIDataStore
    @State private var showJSON = false
    @State private var copied = false
    @State private var submittedMessage: String?
    @State private var submittedButtonId: String?

    init(source: String, surface: A2UISurface, closed: Bool = true, paths: PathLinks = PathLinks(bases: [])) {
        self.source = source
        self.surface = surface
        self.closed = closed
        self.paths = paths
        self._store = State(initialValue: A2UIDataStore(initialData: surface.initialData))
    }

    private var actionState: ReplyActions.State {
        if let submittedMessage { return .used(submittedMessage) }
        guard closed, let replyActions else { return .stale }
        return replyActions.state
    }

    private var isInteractive: Bool {
        actionState == .live
    }

    private var accentTint: Color {
        replyActions?.tint ?? .highlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            if showJSON {
                rawJSONView
            } else {
                A2UINodeView(
                    componentId: surface.rootId,
                    surface: surface,
                    store: store,
                    paths: paths,
                    basePath: nil,
                    depth: 0,
                    visited: [],
                    isInteractive: isInteractive,
                    accentTint: accentTint,
                    submittedButtonId: submittedButtonId,
                    onSubmit: handleSubmit
                )
            }
            if submittedMessage != nil {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Sent")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !closed {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Building card\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .onChange(of: surface.initialData) { _, incoming in
            store.syncInitialData(incoming)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isInteractive ? "a2ui-surface-live" : "a2ui-surface-readonly")
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            if let title = surface.title, !title.isEmpty {
                Label(title, systemImage: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Interactive Card", systemImage: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: $showJSON) {
                Text("Preview").tag(false)
                Text("JSON").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Button(copied ? "Copied" : "Copy") {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
                #elseif canImport(UIKit)
                UIPasteboard.general.string = source
                #endif
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var rawJSONView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(style.code)
                .lineSpacing(style.lineSpacing * 0.5)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func handleSubmit(buttonId: String, action: A2UIAction, buttonLabel: String?, basePath: String?) {
        guard isInteractive, let replyActions else { return }
        let message = store.formatActionMessage(action: action, buttonLabel: buttonLabel, basePath: basePath)
        guard !message.isEmpty else { return }
        submittedButtonId = buttonId
        submittedMessage = message
        replyActions.send(message)
    }
}

// MARK: - Recursive Component Renderer

private struct A2UINodeView: View {
    let componentId: String
    let surface: A2UISurface
    let store: A2UIDataStore
    let paths: PathLinks
    let basePath: String?
    let depth: Int
    let visited: Set<String>
    let isInteractive: Bool
    let accentTint: Color
    let submittedButtonId: String?
    let onSubmit: (String, A2UIAction, String?, String?) -> Void

    @Environment(\.readerStyle) private var style

    var body: some View {
        if depth >= A2UIParser.maxDepth || visited.contains(componentId) {
            EmptyView()
        } else if let component = surface.components[componentId] {
            let nextVisited = visited.union([componentId])
            render(component, nextVisited: nextVisited)
        }
    }

    @ViewBuilder
    private func childNode(_ id: String, basePath: String? = nil, nextVisited: Set<String>) -> some View {
        A2UINodeView(
            componentId: id,
            surface: surface,
            store: store,
            paths: paths,
            basePath: basePath ?? self.basePath,
            depth: depth + 1,
            visited: nextVisited,
            isInteractive: isInteractive,
            accentTint: accentTint,
            submittedButtonId: submittedButtonId,
            onSubmit: onSubmit
        )
    }

    @ViewBuilder
    private func render(_ component: A2UIComponent, nextVisited: Set<String>) -> some View {
        switch component.kind {
        case .column(let children, let alignment, let distribution, let spacing):
            let resolvedSpacing = CGFloat(spacing ?? 10)
            let hAlign = horizontalAlignment(alignment)
            VStack(alignment: hAlign, spacing: resolvedSpacing) {
                renderChildren(children, distribution: distribution, nextVisited: nextVisited)
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: hAlign, vertical: .center))

        case .row(let children, let alignment, let distribution, let spacing):
            let resolvedSpacing = CGFloat(spacing ?? 10)
            let vAlign = verticalAlignment(alignment)
            HStack(alignment: vAlign, spacing: resolvedSpacing) {
                renderChildren(children, distribution: distribution, isRow: true, nextVisited: nextVisited)
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: .leading, vertical: vAlign))

        case .card(let child, let children, let title):
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    let heading = store.resolveString(title, basePath: basePath)
                    if !heading.isEmpty {
                        Text(heading)
                            .font(style.heading(3))
                            .textSelection(.enabled)
                    }
                }
                if let child {
                    childNode(child, nextVisited: nextVisited)
                } else if let children {
                    ForEach(children, id: \.self) { id in
                        childNode(id, nextVisited: nextVisited)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

        case .list(let children, let direction):
            if (direction ?? "vertical").lowercased() == "horizontal" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        renderChildren(children, nextVisited: nextVisited)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    renderChildren(children, nextVisited: nextVisited)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .tabs(let items):
            A2UITabsView(
                items: items,
                surface: surface,
                store: store,
                paths: paths,
                basePath: basePath,
                depth: depth + 1,
                visited: nextVisited,
                isInteractive: isInteractive,
                accentTint: accentTint,
                submittedButtonId: submittedButtonId,
                onSubmit: onSubmit
            )

        case .divider(let axis):
            if (axis ?? "horizontal").lowercased() == "vertical" {
                Divider().frame(maxHeight: 24)
            } else {
                Divider().padding(.vertical, 2)
            }

        case .text(let binding, let variant):
            let text = store.resolveString(binding, basePath: basePath)
            renderText(text, variant: variant)

        case .icon(let nameBinding, let colorName, let size):
            let rawName = store.resolveString(nameBinding, basePath: basePath)
            let symbol = A2UIIconMapper.sfSymbol(for: rawName)
            Image(systemName: symbol)
                .font(.system(size: CGFloat(size ?? 16), weight: .medium))
                .foregroundStyle(semanticColor(colorName) ?? .secondary)

        case .image(let urlBinding, let altBinding, let fit, let variant):
            let urlString = store.resolveString(urlBinding, basePath: basePath)
            let alt = store.resolveString(altBinding, basePath: basePath)
            A2UIImageView(urlString: urlString, alt: alt, fit: fit, variant: variant)

        case .badge(let textBinding, let tone):
            let label = store.resolveString(textBinding, basePath: basePath)
            let color = semanticColor(tone) ?? accentTint
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
                .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.8))

        case .progressBar(let valueBinding, let maxVal, let labelBinding):
            let current = store.resolve(valueBinding, basePath: basePath)?.doubleValue ?? 0
            let total = max(maxVal ?? (current > 1 ? 100 : 1), 0.0001)
            let fraction = min(max(current / total, 0), 1)
            let label = store.resolveString(labelBinding, basePath: basePath)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if !label.isEmpty {
                        Text(label).font(style.secondary).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: fraction)
                    .tint(accentTint)
            }

        case .textField(let label, let text, let placeholder, let variant):
            A2UITextFieldView(
                id: component.id,
                label: store.resolveString(label, basePath: basePath),
                binding: text,
                placeholder: store.resolveString(placeholder, basePath: basePath),
                variant: variant,
                store: store,
                basePath: basePath,
                isInteractive: isInteractive
            )

        case .checkBox(let label, let value, let isSwitch):
            A2UICheckBoxView(
                id: component.id,
                label: store.resolveString(label, basePath: basePath),
                binding: value,
                isSwitch: isSwitch,
                store: store,
                basePath: basePath,
                isInteractive: isInteractive,
                accentTint: accentTint
            )

        case .choicePicker(let label, let selections, let options, let maxAllowedSelections, let variant):
            A2UIChoicePickerView(
                id: component.id,
                label: store.resolveString(label, basePath: basePath),
                binding: selections,
                options: options,
                maxAllowedSelections: maxAllowedSelections,
                variant: variant,
                store: store,
                basePath: basePath,
                isInteractive: isInteractive,
                accentTint: accentTint
            )

        case .slider(let label, let value, let minVal, let maxVal, let step):
            A2UISliderView(
                id: component.id,
                label: store.resolveString(label, basePath: basePath),
                binding: value,
                minVal: minVal,
                maxVal: maxVal,
                step: step,
                store: store,
                basePath: basePath,
                isInteractive: isInteractive,
                accentTint: accentTint
            )

        case .dateTimeInput(let label, let value, let enableDate, let enableTime):
            A2UIDateTimeView(
                id: component.id,
                label: store.resolveString(label, basePath: basePath),
                binding: value,
                enableDate: enableDate,
                enableTime: enableTime,
                store: store,
                basePath: basePath,
                isInteractive: isInteractive
            )

        case .chart(let title, let chartType, let dataBinding, let xKey, let yKey, let seriesKey, let xLabel, let yLabel, let height, let showLegend):
            let resolvedData = store.resolve(dataBinding, basePath: basePath)
            let points = A2UIChartDatum.extract(from: resolvedData, xKey: xKey, yKey: yKey, seriesKey: seriesKey)
            A2UIChartView(
                title: store.resolveString(title, basePath: basePath),
                chartType: chartType,
                points: points,
                xLabel: xLabel ?? A2UIDataStore.humanizeKey(xKey),
                yLabel: yLabel ?? A2UIDataStore.humanizeKey(yKey),
                height: CGFloat(min(max(height ?? 200, 120), 420)),
                showLegend: showLegend,
                accentTint: accentTint
            )

        case .button(let child, let labelBinding, let variant, let action):
            renderButton(
                id: component.id,
                child: child,
                labelBinding: labelBinding,
                variant: variant,
                action: action,
                nextVisited: nextVisited
            )

        case .unsupported(let typeName):
            Text("Unsupported component: \(typeName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }

    @ViewBuilder
    private func renderChildren(_ children: A2UIChildren, distribution: String? = nil, isRow: Bool = false, nextVisited: Set<String>) -> some View {
        let spacedBetween = isRow && ["spacebetween", "space-between", "spaceevenly", "spacearound"].contains((distribution ?? "").lowercased())
        switch children {
        case .explicit(let ids):
            ForEach(Array(ids.enumerated()), id: \.offset) { idx, id in
                let weighted = (surface.components[id]?.weight ?? 0) > 0
                if weighted && isRow {
                    childNode(id, nextVisited: nextVisited)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    childNode(id, nextVisited: nextVisited)
                }
                if spacedBetween && idx < ids.count - 1 {
                    Spacer(minLength: 6)
                }
            }
        case .template(let templateId, let dataBinding):
            let resolvedPath = A2UIJSONPointer.resolvePath(dataBinding, basePath: basePath)
            if case .array(let items) = store.value(at: resolvedPath) {
                ForEach(0..<min(items.count, 50), id: \.self) { idx in
                    childNode(templateId, basePath: "\(resolvedPath)/\(idx)", nextVisited: nextVisited)
                }
            }
        }
    }

    @ViewBuilder
    private func renderText(_ text: String, variant: String?) -> some View {
        let lower = (variant ?? "body").lowercased()
        switch lower {
        case "h1":
            Text(MarkdownText.inline(text, style: style, paths: paths))
                .font(style.heading(1))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case "h2":
            Text(MarkdownText.inline(text, style: style, paths: paths))
                .font(style.heading(2))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case "h3", "h4", "h5", "subtitle":
            Text(MarkdownText.inline(text, style: style, paths: paths))
                .font(style.heading(3))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case "caption", "label", "secondary":
            Text(MarkdownText.inline(text, style: style, paths: paths))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case "code", "monospaced", "mono":
            Text(text)
                .font(style.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text(MarkdownText.inline(text, style: style, paths: paths))
                .font(style.body)
                .lineSpacing(style.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func renderButton(
        id: String,
        child: String?,
        labelBinding: A2UIBinding?,
        variant: String?,
        action: A2UIAction?,
        nextVisited: Set<String>
    ) -> some View {
        let resolvedLabel = extractButtonLabel(child: child, labelBinding: labelBinding)
        let styleKind = (variant ?? "secondary").lowercased()
        let isPrimary = styleKind == "primary" || styleKind == "prominent"
        let isDestructive = styleKind == "destructive" || styleKind == "danger"
        let chosen = submittedButtonId == id
        let tone: Color = isDestructive ? .red : accentTint

        Button {
            guard isInteractive, let action else { return }
            onSubmit(id, action, resolvedLabel, basePath)
        } label: {
            HStack(spacing: 6) {
                if chosen {
                    Image(systemName: "checkmark")
                }
                if let child, surface.components[child] != nil, labelBinding == nil {
                    childNode(child, nextVisited: nextVisited)
                } else {
                    Text(resolvedLabel ?? "Continue").lineLimit(1)
                }
            }
            .font(.callout.weight(isPrimary ? .semibold : .medium))
            .foregroundStyle(isPrimary && isInteractive ? Color.white : (isInteractive ? tone : Color.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isPrimary && isInteractive
                        ? tone
                        : tone.opacity(isInteractive ? 0.14 : 0.06)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isInteractive ? tone.opacity(isPrimary ? 0 : 0.7) : Color.secondary.opacity(0.35),
                    lineWidth: 1.1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive || action == nil)
        .opacity(isInteractive || chosen ? 1 : 0.6)
        .accessibilityIdentifier("a2ui-button-\(id)")
    }

    private func extractButtonLabel(child: String?, labelBinding: A2UIBinding?) -> String? {
        if let labelBinding {
            let s = store.resolveString(labelBinding, basePath: basePath)
            if !s.isEmpty { return s }
        }
        if let child, let comp = surface.components[child], case .text(let binding, _) = comp.kind {
            let s = store.resolveString(binding, basePath: basePath)
            if !s.isEmpty { return s }
        }
        return nil
    }

    private func horizontalAlignment(_ raw: String?) -> HorizontalAlignment {
        switch (raw ?? "start").lowercased() {
        case "center": return .center
        case "end", "trailing": return .trailing
        default: return .leading
        }
    }

    private func verticalAlignment(_ raw: String?) -> VerticalAlignment {
        switch (raw ?? "center").lowercased() {
        case "start", "top": return .top
        case "end", "bottom": return .bottom
        default: return .center
        }
    }

    private func semanticColor(_ raw: String?) -> Color? {
        guard let raw else { return nil }
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "accent", "primary": return accentTint
        case "success", "green", "positive": return .green
        case "warning", "orange", "amber", "yellow": return .orange
        case "danger", "destructive", "error", "red": return .red
        case "info", "blue": return .blue
        case "purple", "indigo": return .purple
        case "teal", "cyan": return .teal
        case "neutral", "gray", "grey", "secondary", "muted": return .secondary
        default:
            if raw.hasPrefix("#") { return ReaderStyle.bubbleColor(raw) }
            return nil
        }
    }
}

// MARK: - Tabs

private struct A2UITabsView: View {
    let items: [A2UITabItem]
    let surface: A2UISurface
    let store: A2UIDataStore
    let paths: PathLinks
    let basePath: String?
    let depth: Int
    let visited: Set<String>
    let isInteractive: Bool
    let accentTint: Color
    let submittedButtonId: String?
    let onSubmit: (String, A2UIAction, String?, String?) -> Void

    @State private var selectedIndex = 0

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            let clamped = min(max(selectedIndex, 0), items.count - 1)
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $selectedIndex) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, tab in
                        Text(store.resolveString(tab.title, basePath: basePath)).tag(idx)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                A2UINodeView(
                    componentId: items[clamped].child,
                    surface: surface,
                    store: store,
                    paths: paths,
                    basePath: basePath,
                    depth: depth,
                    visited: visited,
                    isInteractive: isInteractive,
                    accentTint: accentTint,
                    submittedButtonId: submittedButtonId,
                    onSubmit: onSubmit
                )
            }
        }
    }
}

// MARK: - Inputs

private struct A2UITextFieldView: View {
    let id: String
    let label: String
    let binding: A2UIBinding?
    let placeholder: String
    let variant: String?
    let store: A2UIDataStore
    let basePath: String?
    let isInteractive: Bool

    @Environment(\.readerStyle) private var style

    private var path: String {
        binding?.boundPath ?? "/_inputs/\(id)"
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                store.resolveString(binding ?? .path(path), basePath: basePath)
            },
            set: { newValue in
                store.setValue(.string(newValue), at: path, basePath: basePath)
            }
        )
    }

    var body: some View {
        let lower = (variant ?? "shorttext").lowercased()
        VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(style.secondary.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Group {
                if lower == "obscured" || lower == "password" {
                    SecureField(placeholder.isEmpty ? label : placeholder, text: textBinding)
                } else if lower == "longtext" || lower == "multiline" {
                    TextField(placeholder.isEmpty ? label : placeholder, text: textBinding, axis: .vertical)
                        .lineLimit(3...6)
                } else {
                    TextField(placeholder.isEmpty ? label : placeholder, text: textBinding)
                }
            }
            .textFieldStyle(.plain)
            .font(style.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .disabled(!isInteractive)
            .opacity(isInteractive ? 1 : 0.7)
        }
        .onAppear {
            store.registerInput(path: A2UIJSONPointer.resolvePath(path, basePath: basePath), label: label.isEmpty ? nil : label)
            if let fallback = binding?.fallbackValue, store.value(at: path, basePath: basePath) == nil {
                store.root = A2UIJSONPointer.setting(fallback, at: A2UIJSONPointer.resolvePath(path, basePath: basePath), in: store.root)
            }
        }
    }
}

private struct A2UICheckBoxView: View {
    let id: String
    let label: String
    let binding: A2UIBinding?
    let isSwitch: Bool
    let store: A2UIDataStore
    let basePath: String?
    let isInteractive: Bool
    let accentTint: Color

    @Environment(\.readerStyle) private var style

    private var path: String {
        binding?.boundPath ?? "/_inputs/\(id)"
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                store.resolve(binding ?? .path(path), basePath: basePath)?.boolValue ?? false
            },
            set: { newValue in
                store.setValue(.bool(newValue), at: path, basePath: basePath)
            }
        )
    }

    var body: some View {
        Group {
            #if os(macOS)
            if isSwitch {
                Toggle(label, isOn: boolBinding).toggleStyle(.switch)
            } else {
                Toggle(label, isOn: boolBinding).toggleStyle(.checkbox)
            }
            #else
            Toggle(label, isOn: boolBinding)
            #endif
        }
        .font(style.body)
        .tint(accentTint)
        .disabled(!isInteractive)
        .onAppear {
            store.registerInput(path: A2UIJSONPointer.resolvePath(path, basePath: basePath), label: label.isEmpty ? nil : label)
            if let fallback = binding?.fallbackValue, store.value(at: path, basePath: basePath) == nil {
                store.root = A2UIJSONPointer.setting(fallback, at: A2UIJSONPointer.resolvePath(path, basePath: basePath), in: store.root)
            }
        }
    }
}

private struct A2UIChoicePickerView: View {
    let id: String
    let label: String
    let binding: A2UIBinding?
    let options: [A2UIChoiceOption]
    let maxAllowedSelections: Int?
    let variant: String?
    let store: A2UIDataStore
    let basePath: String?
    let isInteractive: Bool
    let accentTint: Color

    @Environment(\.readerStyle) private var style

    private var path: String {
        binding?.boundPath ?? "/_inputs/\(id)"
    }

    private var isSingleSelect: Bool {
        maxAllowedSelections == 1 || (variant ?? "").lowercased() == "segmented"
    }

    private var currentSelections: [String] {
        store.resolve(binding ?? .path(path), basePath: basePath)?.stringArrayValue ?? []
    }

    private func toggle(_ value: String) {
        guard isInteractive else { return }
        if isSingleSelect {
            store.setValue(.array([.string(value)]), at: path, basePath: basePath)
            return
        }
        var current = currentSelections
        if let idx = current.firstIndex(of: value) {
            current.remove(at: idx)
        } else {
            if let limit = maxAllowedSelections, current.count >= limit {
                current.removeFirst()
            }
            current.append(value)
        }
        store.setValue(.array(current.map { .string($0) }), at: path, basePath: basePath)
    }

    var body: some View {
        let selected = Set(currentSelections)
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(style.secondary.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if isSingleSelect && options.count <= 4 && options.allSatisfy({ store.resolveString($0.label, basePath: basePath).count <= 16 }) {
                Picker("", selection: Binding(
                    get: { currentSelections.first ?? options.first?.value ?? "" },
                    set: { toggle($0) }
                )) {
                    ForEach(options, id: \.value) { opt in
                        Text(store.resolveString(opt.label, basePath: basePath)).tag(opt.value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!isInteractive)
            } else {
                A2UIFlowLayout(spacing: 8) {
                    ForEach(options, id: \.value) { opt in
                        let isSelected = selected.contains(opt.value)
                        Button {
                            toggle(opt.value)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isSingleSelect
                                      ? (isSelected ? "largecircle.fill.circle" : "circle")
                                      : (isSelected ? "checkmark.circle.fill" : "circle"))
                                    .font(.caption)
                                Text(store.resolveString(opt.label, basePath: basePath))
                                    .font(style.secondary.weight(isSelected ? .semibold : .regular))
                            }
                            .foregroundStyle(isSelected ? accentTint : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? accentTint.opacity(0.14) : Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? accentTint.opacity(0.7) : Color.primary.opacity(0.14), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isInteractive)
                    }
                }
            }
        }
        .onAppear {
            store.registerInput(path: A2UIJSONPointer.resolvePath(path, basePath: basePath), label: label.isEmpty ? nil : label)
            if let fallback = binding?.fallbackValue, store.value(at: path, basePath: basePath) == nil {
                store.root = A2UIJSONPointer.setting(fallback, at: A2UIJSONPointer.resolvePath(path, basePath: basePath), in: store.root)
            }
        }
    }
}

private struct A2UISliderView: View {
    let id: String
    let label: String
    let binding: A2UIBinding?
    let minVal: Double
    let maxVal: Double
    let step: Double?
    let store: A2UIDataStore
    let basePath: String?
    let isInteractive: Bool
    let accentTint: Color

    @Environment(\.readerStyle) private var style

    private var path: String {
        binding?.boundPath ?? "/_inputs/\(id)"
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: {
                let raw = store.resolve(binding ?? .path(path), basePath: basePath)?.doubleValue ?? minVal
                return min(max(raw, minVal), maxVal)
            },
            set: { newValue in
                store.setValue(.number(newValue), at: path, basePath: basePath)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !label.isEmpty {
                    Text(label).font(style.secondary.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(A2UIValue.formatNumber(doubleBinding.wrappedValue))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let step, step > 0 {
                Slider(value: doubleBinding, in: minVal...maxVal, step: step)
                    .tint(accentTint)
                    .disabled(!isInteractive)
            } else {
                Slider(value: doubleBinding, in: minVal...maxVal)
                    .tint(accentTint)
                    .disabled(!isInteractive)
            }
        }
        .onAppear {
            store.registerInput(path: A2UIJSONPointer.resolvePath(path, basePath: basePath), label: label.isEmpty ? nil : label)
            if let fallback = binding?.fallbackValue, store.value(at: path, basePath: basePath) == nil {
                store.root = A2UIJSONPointer.setting(fallback, at: A2UIJSONPointer.resolvePath(path, basePath: basePath), in: store.root)
            }
        }
    }
}

private struct A2UIDateTimeView: View {
    let id: String
    let label: String
    let binding: A2UIBinding?
    let enableDate: Bool
    let enableTime: Bool
    let store: A2UIDataStore
    let basePath: String?
    let isInteractive: Bool

    @Environment(\.readerStyle) private var style

    private var path: String {
        binding?.boundPath ?? "/_inputs/\(id)"
    }

    private var displayedComponents: DatePickerComponents {
        switch (enableDate, enableTime) {
        case (true, true): return [.date, .hourAndMinute]
        case (false, true): return [.hourAndMinute]
        default: return [.date]
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                let str = store.resolveString(binding ?? .path(path), basePath: basePath)
                return Self.parseDate(str) ?? Date()
            },
            set: { newDate in
                store.setValue(.string(Self.formatDate(newDate, enableDate: enableDate, enableTime: enableTime)), at: path, basePath: basePath)
            }
        )
    }

    var body: some View {
        DatePicker(label.isEmpty ? "Date" : label, selection: dateBinding, displayedComponents: displayedComponents)
            .font(style.body)
            .disabled(!isInteractive)
            .onAppear {
                store.registerInput(path: A2UIJSONPointer.resolvePath(path, basePath: basePath), label: label.isEmpty ? nil : label)
            }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "HH:mm"] {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    private static func formatDate(_ date: Date, enableDate: Bool, enableTime: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        switch (enableDate, enableTime) {
        case (true, true): df.dateFormat = "yyyy-MM-dd HH:mm"
        case (false, true): df.dateFormat = "HH:mm"
        default: df.dateFormat = "yyyy-MM-dd"
        }
        return df.string(from: date)
    }
}

// MARK: - Native Swift Charts

private struct A2UIChartView: View {
    let title: String
    let chartType: A2UIChartType
    let points: [A2UIChartDatum]
    let xLabel: String
    let yLabel: String
    let height: CGFloat
    let showLegend: Bool
    let accentTint: Color

    @Environment(\.readerStyle) private var style

    private var hasSeries: Bool {
        Set(points.compactMap(\.series)).count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(style.secondary.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if points.isEmpty {
                Text("Waiting for chart data\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                chartBody
                    .frame(height: height)
                    .chartLegend(showLegend && (hasSeries || chartType == .pie || chartType == .donut) ? .visible : .hidden)
                    .accessibilityIdentifier("a2ui-chart-\(chartType.rawValue)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }

    @ViewBuilder
    private var chartBody: some View {
        switch chartType {
        case .bar:
            Chart(points) { point in
                if let series = point.series, hasSeries {
                    BarMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(by: .value("Series", series))
                    .position(by: .value("Series", series))
                    .cornerRadius(4)
                } else {
                    BarMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(accentTint.gradient)
                    .cornerRadius(4)
                }
            }

        case .line:
            Chart(points) { point in
                if let series = point.series, hasSeries {
                    LineMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(by: .value("Series", series))
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(by: .value("Series", series))
                } else {
                    LineMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(accentTint)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(accentTint)
                }
            }

        case .area:
            Chart(points) { point in
                if let series = point.series, hasSeries {
                    AreaMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(by: .value("Series", series))
                    .opacity(0.28)
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(by: .value("Series", series))
                    .interpolationMethod(.catmullRom)
                } else {
                    AreaMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(LinearGradient(colors: [accentTint.opacity(0.35), accentTint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value(xLabel, point.label),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(accentTint)
                    .interpolationMethod(.catmullRom)
                }
            }

        case .pie, .donut:
            Chart(points) { point in
                SectorMark(
                    angle: .value(yLabel, max(0, point.value)),
                    innerRadius: .ratio(chartType == .donut ? 0.56 : 0),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(by: .value(xLabel, point.label))
            }
        }
    }
}

// MARK: - Image, Icons & Flow Layout

private struct A2UIImageView: View {
    let urlString: String
    let alt: String
    let fit: String?
    let variant: String?

    private var contentMode: ContentMode {
        (fit ?? "contain").lowercased() == "cover" ? .fill : .fit
    }

    private var maxHeight: CGFloat {
        switch (variant ?? "").lowercased() {
        case "avatar", "icon": return 44
        case "smallfeature": return 120
        case "mediumfeature": return 180
        case "header": return 220
        default: return 240
        }
    }

    var body: some View {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let local = localImage(for: trimmed) {
            local
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(maxWidth: variant?.lowercased() == "avatar" ? 44 : .infinity, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: variant?.lowercased() == "avatar" ? 22 : 8))
                .accessibilityLabel(alt)
        } else if let url = URL(string: trimmed), url.scheme?.lowercased() == "https" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(maxWidth: variant?.lowercased() == "avatar" ? 44 : .infinity, maxHeight: maxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: variant?.lowercased() == "avatar" ? 22 : 8))
                case .failure:
                    placeholder
                default:
                    ProgressView().frame(height: 60)
                }
            }
            .accessibilityLabel(alt)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            if !alt.isEmpty { Text(alt).lineLimit(1) }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func localImage(for path: String) -> Image? {
        let resolved: String
        if path.hasPrefix("file://"), let url = URL(string: path) {
            resolved = url.path
        } else if path.hasPrefix("/") {
            resolved = path
        } else if path.hasPrefix("~/") {
            resolved = (path as NSString).expandingTildeInPath
        } else {
            return nil
        }
        #if canImport(AppKit)
        guard let nsImage = NSImage(contentsOfFile: resolved) else { return nil }
        return Image(nsImage: nsImage)
        #elseif canImport(UIKit)
        guard let uiImage = UIImage(contentsOfFile: resolved) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

enum A2UIIconMapper {
    static func sfSymbol(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "sparkles" }
        // Pass through explicit SF Symbol names (contain a dot like "chart.bar.fill").
        if trimmed.contains(".") { return trimmed }
        switch trimmed.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "check", "checkmark", "done", "success": return "checkmark.circle.fill"
        case "close", "cancel", "clear", "xmark": return "xmark.circle"
        case "warning", "alert": return "exclamationmark.triangle.fill"
        case "error", "danger": return "exclamationmark.octagon.fill"
        case "info", "information": return "info.circle"
        case "search": return "magnifyingglass"
        case "settings", "gear", "tune": return "gearshape"
        case "calendar", "event", "date": return "calendar"
        case "clock", "time", "schedule": return "clock"
        case "star", "favorite": return "star.fill"
        case "heart", "like": return "heart.fill"
        case "mail", "email", "envelope": return "envelope"
        case "send", "paperplane": return "paperplane.fill"
        case "home", "house": return "house"
        case "person", "user", "account": return "person.circle"
        case "chart", "analytics", "trendingup", "bar": return "chart.bar.fill"
        case "linechart": return "chart.xyaxis.line"
        case "piechart": return "chart.pie.fill"
        case "folder": return "folder"
        case "file", "doc", "document", "description": return "doc.text"
        case "trash", "delete": return "trash"
        case "add", "plus": return "plus.circle"
        case "edit", "pencil": return "pencil"
        case "lock": return "lock.fill"
        case "bolt", "flash", "fast": return "bolt.fill"
        case "sparkles", "ai", "magic": return "sparkles"
        case "cart", "shoppingcart": return "cart"
        case "location", "pin", "map": return "mappin.and.ellipse"
        case "phone", "call": return "phone"
        case "link": return "link"
        case "download": return "arrow.down.circle"
        case "upload": return "arrow.up.circle"
        case "refresh", "sync": return "arrow.clockwise"
        default: return trimmed
        }
    }
}

/// Simple wrapping horizontal flow layout for multi-select choice chips.
private struct A2UIFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(usedWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
