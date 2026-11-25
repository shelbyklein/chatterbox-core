import Foundation
import Observation

// MARK: - JSON Value

/// A JSON value stored in an A2UI data model or inline component literal.
enum A2UIValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([A2UIValue])
    case object([String: A2UIValue])
    case null

    init(jsonObject: Any) {
        if let dict = jsonObject as? [String: Any] {
            var mapped: [String: A2UIValue] = [:]
            mapped.reserveCapacity(dict.count)
            for (k, v) in dict { mapped[k] = A2UIValue(jsonObject: v) }
            self = .object(mapped)
        } else if let arr = jsonObject as? [Any] {
            self = .array(arr.map { A2UIValue(jsonObject: $0) })
        } else if let s = jsonObject as? String {
            self = .string(s)
        } else if let n = jsonObject as? NSNumber {
            // Distinguish JSON booleans from numeric 0/1.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        } else if jsonObject is NSNull {
            self = .null
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return Self.formatNumber(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var intValue: Int? {
        doubleValue.map { Int($0.rounded()) }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var arrayValue: [A2UIValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    var objectValue: [String: A2UIValue]? {
        if case .object(let obj) = self { return obj }
        return nil
    }

    var stringArrayValue: [String]? {
        switch self {
        case .array(let arr): return arr.compactMap(\.stringValue)
        case .string(let s) where !s.isEmpty: return [s]
        default: return nil
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        case .number, .bool: return false
        }
    }

    /// Compact human-readable rendering used when formatting userAction submissions.
    var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return Self.formatNumber(n)
        case .bool(let b): return b ? "Yes" : "No"
        case .array(let items):
            return items.map(\.displayString).filter { !$0.isEmpty }.joined(separator: ", ")
        case .object(let dict):
            return dict.keys.sorted().compactMap { key -> String? in
                guard let v = dict[key], !v.isEmpty else { return nil }
                return "\(key): \(v.displayString)"
            }.joined(separator: ", ")
        case .null:
            return ""
        }
    }

    static func formatNumber(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "0" }
        if value.rounded() == value, abs(value) < 1e12 {
            return String(Int64(value))
        }
        return String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Bindings & AST

/// A component property that may be a static literal, a JSON Pointer path into the data model,
/// or a path paired with an initial fallback value (as allowed by A2UI v0.8).
enum A2UIBinding: Hashable, Sendable {
    case literal(A2UIValue)
    case path(String)
    case pathWithFallback(String, A2UIValue)

    var boundPath: String? {
        switch self {
        case .path(let p), .pathWithFallback(let p, _): return p
        case .literal: return nil
        }
    }

    var fallbackValue: A2UIValue? {
        switch self {
        case .literal(let v), .pathWithFallback(_, let v): return v
        case .path: return nil
        }
    }

    static func parse(_ raw: Any?) -> A2UIBinding? {
        guard let raw else { return nil }
        if let dict = raw as? [String: Any] {
            let path = (dict["path"] as? String)?.trimmingCharacters(in: .whitespaces)
            let literal: A2UIValue? = {
                if let s = dict["literalString"] as? String { return .string(s) }
                if let n = dict["literalNumber"] as? NSNumber { return .number(n.doubleValue) }
                if let b = dict["literalBoolean"] as? Bool { return .bool(b) }
                if let arr = dict["literalArray"] { return A2UIValue(jsonObject: arr) }
                if let lit = dict["literal"] { return A2UIValue(jsonObject: lit) }
                return nil
            }()
            if let path, !path.isEmpty {
                if let literal { return .pathWithFallback(path, literal) }
                return .path(path)
            }
            if let literal { return .literal(literal) }
            return .literal(A2UIValue(jsonObject: dict))
        }
        return .literal(A2UIValue(jsonObject: raw))
    }
}

enum A2UIChildren: Hashable, Sendable {
    case explicit([String])
    case template(componentId: String, dataBinding: String)

    static let empty = A2UIChildren.explicit([])

    static func parse(_ raw: Any?) -> A2UIChildren {
        guard let raw else { return .empty }
        if let arr = raw as? [String] {
            return .explicit(arr)
        }
        if let arr = raw as? [Any] {
            return .explicit(arr.compactMap { $0 as? String })
        }
        if let dict = raw as? [String: Any] {
            if let explicit = dict["explicitList"] as? [String] {
                return .explicit(explicit)
            }
            if let explicit = dict["explicitList"] as? [Any] {
                return .explicit(explicit.compactMap { $0 as? String })
            }
            if let template = dict["template"] as? [String: Any],
               let componentId = (template["componentId"] as? String) ?? (template["component"] as? String),
               let binding = (template["dataBinding"] as? String) ?? (template["path"] as? String) {
                return .template(componentId: componentId, dataBinding: binding)
            }
            if let componentId = (dict["componentId"] as? String) ?? (dict["component"] as? String),
               let binding = (dict["dataBinding"] as? String) ?? (dict["path"] as? String) {
                return .template(componentId: componentId, dataBinding: binding)
            }
        }
        return .empty
    }
}

struct A2UITabItem: Hashable, Sendable {
    var title: A2UIBinding
    var child: String
}

struct A2UIChoiceOption: Hashable, Sendable {
    var label: A2UIBinding
    var value: String
}

struct A2UIActionContextEntry: Hashable, Sendable {
    var key: String
    var value: A2UIBinding
}

struct A2UIAction: Hashable, Sendable {
    var name: String
    var context: [A2UIActionContextEntry]

    static func parse(_ raw: Any?) -> A2UIAction? {
        if let name = raw as? String, !name.isEmpty {
            return A2UIAction(name: name, context: [])
        }
        guard let dict = raw as? [String: Any] else { return nil }
        let name = (dict["name"] as? String)
            ?? (dict["event"] as? [String: Any])?["name"] as? String
            ?? (dict["id"] as? String)
            ?? ""
        guard !name.isEmpty else { return nil }

        var entries: [A2UIActionContextEntry] = []
        let rawContext = dict["context"] ?? (dict["event"] as? [String: Any])?["context"]
        if let list = rawContext as? [[String: Any]] {
            for item in list {
                guard let key = item["key"] as? String, !key.isEmpty,
                      let value = A2UIBinding.parse(item["value"]) else { continue }
                entries.append(A2UIActionContextEntry(key: key, value: value))
            }
        } else if let map = rawContext as? [String: Any] {
            for key in map.keys.sorted() {
                guard let value = A2UIBinding.parse(map[key]) else { continue }
                entries.append(A2UIActionContextEntry(key: key, value: value))
            }
        }
        return A2UIAction(name: name, context: entries)
    }
}

enum A2UIChartType: String, Hashable, Sendable {
    case bar
    case line
    case area
    case pie
    case donut

    init(raw: String?) {
        switch (raw ?? "bar").lowercased().trimmingCharacters(in: .whitespaces) {
        case "line", "sparkline": self = .line
        case "area": self = .area
        case "pie": self = .pie
        case "donut", "doughnut", "ring": self = .donut
        default: self = .bar
        }
    }
}

struct A2UIComponent: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        // Layout
        case column(children: A2UIChildren, alignment: String?, distribution: String?, spacing: Double?)
        case row(children: A2UIChildren, alignment: String?, distribution: String?, spacing: Double?)
        case card(child: String?, children: [String]?, title: A2UIBinding?)
        case list(children: A2UIChildren, direction: String?)
        case tabs(items: [A2UITabItem])
        case divider(axis: String?)

        // Display
        case text(text: A2UIBinding, variant: String?)
        case icon(name: A2UIBinding, color: String?, size: Double?)
        case image(url: A2UIBinding, alt: A2UIBinding?, fit: String?, variant: String?)
        case badge(text: A2UIBinding, tone: String?)
        case progressBar(value: A2UIBinding, max: Double?, label: A2UIBinding?)

        // Inputs
        case textField(label: A2UIBinding?, text: A2UIBinding?, placeholder: A2UIBinding?, variant: String?)
        case checkBox(label: A2UIBinding?, value: A2UIBinding?, isSwitch: Bool)
        case choicePicker(label: A2UIBinding?, selections: A2UIBinding?, options: [A2UIChoiceOption], maxAllowedSelections: Int?, variant: String?)
        case slider(label: A2UIBinding?, value: A2UIBinding?, min: Double, max: Double, step: Double?)
        case dateTimeInput(label: A2UIBinding?, value: A2UIBinding?, enableDate: Bool, enableTime: Bool)

        // Native Charts
        case chart(title: A2UIBinding?, chartType: A2UIChartType, data: A2UIBinding, xKey: String, yKey: String, seriesKey: String?, xLabel: String?, yLabel: String?, height: Double?, showLegend: Bool)

        // Actions
        case button(child: String?, label: A2UIBinding?, variant: String?, action: A2UIAction?)

        // Graceful fallback for unknown future catalog components
        case unsupported(typeName: String)
    }

    var id: String
    var kind: Kind
    var weight: Double?
}

struct A2UISurface: Equatable, Sendable {
    var id: String
    var rootId: String
    var title: String?
    var components: [String: A2UIComponent]
    var initialData: [String: A2UIValue]
    var isDeleted: Bool
    var validMessageCount: Int
    var hasIncompleteTrailingLine: Bool

    var hasRenderableRoot: Bool {
        !isDeleted && components[rootId] != nil
    }
}

struct A2UIParseResult: Equatable, Sendable {
    var surfaces: [A2UISurface]
    var validMessageCount: Int
    var hasIncompleteTrailingLine: Bool

    var primarySurface: A2UISurface? {
        surfaces.first { $0.hasRenderableRoot } ?? surfaces.first { !$0.isDeleted && !$0.components.isEmpty }
    }

    var isValid: Bool {
        validMessageCount > 0 && primarySurface != nil
    }
}

// MARK: - Parser (v0.8 + v0.9/v1.0 JSONL & JSON)

enum A2UIParser {
    static let languages: Set<String> = ["a2ui", "a2ui-jsonl"]
    static let maxComponents = 200
    static let maxDepth = 32

    static func parse(_ source: String, closed: Bool = true) -> A2UIParseResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return A2UIParseResult(surfaces: [], validMessageCount: 0, hasIncompleteTrailingLine: !closed)
        }

        var builder = SurfaceBuilder()
        var validMessages = 0
        var hasIncompleteTrailingLine = false

        // First try line-by-line JSONL (standard A2UI streaming format).
        let lines = source.components(separatedBy: .newlines)
        let lastNonEmptyIndex = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let isStreamingTail = !closed && idx == lastNonEmptyIndex
            let parsed: Any? = parseJSONObject(line, balanceEnd: !isStreamingTail)
                ?? (isStreamingTail ? nil : salvageUpdateComponents(line))
            guard let obj = parsed else {
                // While streaming, an unfinished trailing line is expected and ignored until complete.
                if isStreamingTail {
                    hasIncompleteTrailingLine = true
                }
                continue
            }
            if let dict = obj as? [String: Any], builder.apply(message: dict) {
                validMessages += 1
            } else if let arr = obj as? [[String: Any]] {
                for dict in arr where builder.apply(message: dict) {
                    validMessages += 1
                }
            }
        }

        // Fallback for pretty-printed multi-line JSON array or single surface object.
        let fallbackObj: Any? = validMessages == 0
            ? (parseJSONObject(trimmed, balanceEnd: closed) ?? (closed ? salvageUpdateComponents(trimmed) : nil))
            : nil
        if let obj = fallbackObj {
            if let arr = obj as? [[String: Any]] {
                for dict in arr where builder.apply(message: dict) {
                    validMessages += 1
                }
            } else if let dict = obj as? [String: Any] {
                if builder.apply(message: dict) {
                    validMessages += 1
                }
            }
            if validMessages > 0 {
                hasIncompleteTrailingLine = false
            }
        }

        return A2UIParseResult(
            surfaces: builder.build(validMessageCount: validMessages, hasIncompleteTrailingLine: hasIncompleteTrailingLine),
            validMessageCount: validMessages,
            hasIncompleteTrailingLine: hasIncompleteTrailingLine
        )
    }

    // MARK: Tolerant JSON recovery (LLM typos on large JSONL lines)

    /// Attempts to decode a JSONL line (or whole payload), falling back to repairing common LLM
    /// typos (a missing property key like `"component":"Text":"..."`, trailing commas, or a
    /// missing closing brace at EOF). Returns `nil` for non-JSON text.
    private static func parseJSONObject(_ raw: String, balanceEnd: Bool) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return obj
        }
        let repaired = repairJSON(trimmed, balanceEnd: balanceEnd)
        guard repaired != trimmed,
              let data = repaired.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return obj
    }

    /// Fixes frequent single-character LLM JSON slips without corrupting string contents:
    /// 1. Missing default property key after `"component":"Text":"..."` (and Badge/Button/Icon/Image).
    /// 2. Trailing commas before `}` or `]`.
    /// 3. Unclosed (or extra) trailing `}` / `]` at the end of a completed line.
    private static func repairJSON(_ raw: String, balanceEnd: Bool) -> String {
        var text = raw

        let missingKeyPatterns: [(type: String, prop: String)] = [
            ("Text", "text"),
            ("Badge", "text"),
            ("Chip", "text"),
            ("Tag", "text"),
            ("Button", "label"),
            ("Icon", "name"),
            ("Image", "url"),
        ]
        for (type, prop) in missingKeyPatterns {
            let pattern = #""(component|type)"\s*:\s*"(\#(type))"\s*:\s*(?=["\[{0-9tfn-])"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = text as NSString
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: #""$1":"$2","\#(prop)":"#
                )
            }
        }

        var out: [Character] = []
        out.reserveCapacity(text.count + 4)
        var stack: [Character] = []
        var inString = false
        var escaped = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString {
                out.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if ch == "\"" {
                inString = true
                out.append(ch)
                i += 1
                continue
            }
            if ch == "," {
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") {
                    i += 1
                    continue
                }
            }
            if ch == "{" || ch == "[" {
                stack.append(ch)
                out.append(ch)
            } else if ch == "}" || ch == "]" {
                let expected: Character = ch == "}" ? "{" : "["
                if stack.last == expected {
                    stack.removeLast()
                    out.append(ch)
                } else if balanceEnd && stack.isEmpty {
                    // Drop stray extra closing delimiter at top level.
                } else {
                    out.append(ch)
                }
            } else {
                out.append(ch)
            }
            i += 1
        }

        if balanceEnd && !inString && !stack.isEmpty && stack.count <= 4 {
            for opener in stack.reversed() {
                out.append(opener == "{" ? "}" : "]")
            }
        }
        return String(out)
    }

    /// Last-resort salvage for a damaged `updateComponents` / `surfaceUpdate` line: extracts
    /// each individual `{...}` component object from `"components":[...]` so one broken entry
    /// never discards the rest of the surface.
    private static func salvageUpdateComponents(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{",
              let compsKeyRange = trimmed.range(of: #""components"\s*:\s*\["#, options: .regularExpression) else {
            return nil
        }

        let header = String(trimmed[..<compsKeyRange.lowerBound])
        func firstString(named key: String) -> String? {
            let pattern = #""\#(key)"\s*:\s*"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: (header as NSString).length)),
                  match.numberOfRanges > 1 else { return nil }
            return (header as NSString).substring(with: match.range(at: 1))
        }

        let surfaceId = firstString(named: "surfaceId") ?? "main"
        let rootId = firstString(named: "root")

        let arrayPart = Array(trimmed[compsKeyRange.upperBound...])
        var components: [[String: Any]] = []
        var i = 0
        var inString = false
        var escaped = false
        var objDepth = 0
        var objStart: Int? = nil

        while i < arrayPart.count {
            let ch = arrayPart[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                i += 1
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if objDepth == 0 { objStart = i }
                objDepth += 1
            } else if ch == "}" {
                if objDepth > 0 {
                    objDepth -= 1
                    if objDepth == 0, let start = objStart {
                        let slice = String(arrayPart[start...i])
                        if let dict = parseJSONObject(slice, balanceEnd: true) as? [String: Any] {
                            components.append(dict)
                        }
                        objStart = nil
                    }
                }
            } else if ch == "]" && objDepth == 0 {
                break
            }
            i += 1
        }

        guard !components.isEmpty else { return nil }
        var body: [String: Any] = ["surfaceId": surfaceId, "components": components]
        if let rootId { body["root"] = rootId }
        return ["updateComponents": body]
    }

    // MARK: Internal builder

    private struct MutableSurface {
        var id: String
        var rootId: String?
        var title: String?
        var components: [String: A2UIComponent] = [:]
        var firstComponentId: String?
        var data: [String: A2UIValue] = [:]
        var isDeleted = false
    }

    private struct SurfaceBuilder {
        var order: [String] = []
        var surfaces: [String: MutableSurface] = [:]

        mutating func surface(for id: String) -> String {
            let key = id.isEmpty ? "main" : id
            if surfaces[key] == nil {
                order.append(key)
                surfaces[key] = MutableSurface(id: key)
            }
            return key
        }

        @discardableResult
        mutating func apply(message dict: [String: Any]) -> Bool {
            var handled = false

            // v0.8 beginRendering
            if let begin = dict["beginRendering"] as? [String: Any] {
                let id = surface(for: (begin["surfaceId"] as? String) ?? (dict["surfaceId"] as? String) ?? "main")
                if let root = begin["root"] as? String, !root.isEmpty {
                    surfaces[id]?.rootId = root
                }
                if let title = begin["title"] as? String, !title.isEmpty {
                    surfaces[id]?.title = title
                }
                handled = true
            }

            // v0.9 / v1.0 createSurface
            if let create = dict["createSurface"] as? [String: Any] {
                let id = surface(for: (create["surfaceId"] as? String) ?? (dict["surfaceId"] as? String) ?? "main")
                if let root = (create["root"] as? String) ?? (create["rootComponentId"] as? String), !root.isEmpty {
                    surfaces[id]?.rootId = root
                }
                if let title = create["title"] as? String, !title.isEmpty {
                    surfaces[id]?.title = title
                }
                handled = true
            }

            // v0.8 surfaceUpdate / v0.9 updateComponents
            if let update = (dict["surfaceUpdate"] as? [String: Any]) ?? (dict["updateComponents"] as? [String: Any]) {
                let id = surface(for: (update["surfaceId"] as? String) ?? (dict["surfaceId"] as? String) ?? "main")
                if let root = update["root"] as? String, !root.isEmpty {
                    surfaces[id]?.rootId = root
                }
                if let comps = update["components"] as? [[String: Any]] {
                    addComponents(comps, to: id)
                }
                handled = true
            }

            // v0.8 dataModelUpdate / v0.9 updateDataModel
            if let dataUpdate = (dict["dataModelUpdate"] as? [String: Any]) ?? (dict["updateDataModel"] as? [String: Any]) {
                let id = surface(for: (dataUpdate["surfaceId"] as? String) ?? (dict["surfaceId"] as? String) ?? "main")
                applyDataUpdate(dataUpdate, to: id)
                handled = true
            }

            // deleteSurface
            if let del = dict["deleteSurface"] as? [String: Any] {
                let id = surface(for: (del["surfaceId"] as? String) ?? (dict["surfaceId"] as? String) ?? "main")
                surfaces[id]?.isDeleted = true
                handled = true
            } else if let delId = dict["deleteSurface"] as? String {
                let id = surface(for: delId)
                surfaces[id]?.isDeleted = true
                handled = true
            }

            // Compact single-object shorthand: {"root": "...", "components": [...], "data": {...}}
            if !handled, let comps = dict["components"] as? [[String: Any]] {
                let id = surface(for: (dict["surfaceId"] as? String) ?? "main")
                if let root = dict["root"] as? String, !root.isEmpty {
                    surfaces[id]?.rootId = root
                }
                if let title = dict["title"] as? String, !title.isEmpty {
                    surfaces[id]?.title = title
                }
                addComponents(comps, to: id)
                if let data = dict["data"] as? [String: Any] {
                    applyDataUpdate(["path": "/", "value": data], to: id)
                }
                handled = true
            }

            return handled
        }

        private mutating func addComponents(_ rawList: [[String: Any]], to surfaceId: String) {
            guard var s = surfaces[surfaceId] else { return }
            for raw in rawList {
                guard let parsed = parseComponent(raw) else { continue }
                if s.components[parsed.id] == nil && s.components.count >= A2UIParser.maxComponents {
                    continue
                }
                if s.firstComponentId == nil { s.firstComponentId = parsed.id }
                s.components[parsed.id] = parsed
            }
            surfaces[surfaceId] = s
        }

        private mutating func applyDataUpdate(_ update: [String: Any], to surfaceId: String) {
            guard var s = surfaces[surfaceId] else { return }
            let path = (update["path"] as? String) ?? "/"

            // v0.8 adjacency contents array: [{key, valueString/valueNumber/valueBoolean/valueMap/valueArray}]
            if let contents = update["contents"] as? [[String: Any]] {
                let map = parseV08Contents(contents)
                if path == "/" || path.isEmpty {
                    for (k, v) in map { s.data[k] = mergeValue(existing: s.data[k], incoming: v) }
                } else {
                    s.data = A2UIJSONPointer.setting(.object(map), at: path, in: s.data)
                }
            } else if let value = update["value"] {
                let converted = A2UIValue(jsonObject: value)
                if (path == "/" || path.isEmpty), case .object(let dict) = converted {
                    for (k, v) in dict { s.data[k] = mergeValue(existing: s.data[k], incoming: v) }
                } else {
                    s.data = A2UIJSONPointer.setting(converted, at: path, in: s.data)
                }
            }
            surfaces[surfaceId] = s
        }

        private func parseV08Contents(_ list: [[String: Any]]) -> [String: A2UIValue] {
            var out: [String: A2UIValue] = [:]
            for item in list {
                guard let key = item["key"] as? String, !key.isEmpty else { continue }
                if let s = item["valueString"] as? String {
                    out[key] = .string(s)
                } else if let n = item["valueNumber"] as? NSNumber {
                    out[key] = .number(n.doubleValue)
                } else if let b = item["valueBoolean"] as? Bool {
                    out[key] = .bool(b)
                } else if let map = item["valueMap"] as? [[String: Any]] {
                    out[key] = .object(parseV08Contents(map))
                } else if let arr = item["valueArray"] {
                    out[key] = A2UIValue(jsonObject: arr)
                } else if let raw = item["value"] {
                    out[key] = A2UIValue(jsonObject: raw)
                }
            }
            return out
        }

        private func mergeValue(existing: A2UIValue?, incoming: A2UIValue) -> A2UIValue {
            if case .object(var base) = existing, case .object(let patch) = incoming {
                for (k, v) in patch { base[k] = mergeValue(existing: base[k], incoming: v) }
                return .object(base)
            }
            return incoming
        }

        func build(validMessageCount: Int, hasIncompleteTrailingLine: Bool) -> [A2UISurface] {
            order.compactMap { id in
                guard let s = surfaces[id] else { return nil }
                let resolvedRoot = s.rootId
                    ?? (s.components["root"] != nil ? "root" : nil)
                    ?? s.firstComponentId
                    ?? "root"
                return A2UISurface(
                    id: s.id,
                    rootId: resolvedRoot,
                    title: s.title,
                    components: s.components,
                    initialData: s.data,
                    isDeleted: s.isDeleted,
                    validMessageCount: validMessageCount,
                    hasIncompleteTrailingLine: hasIncompleteTrailingLine
                )
            }
        }

        // MARK: Component Parsing

        private func parseComponent(_ raw: [String: Any]) -> A2UIComponent? {
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            let weight = (raw["weight"] as? NSNumber)?.doubleValue

            let typeName: String
            let props: [String: Any]

            if let nested = raw["component"] as? [String: Any], let first = nested.first {
                // v0.8 shape: {"id": "x", "component": {"Text": {...}}}
                typeName = first.key
                props = (first.value as? [String: Any]) ?? [:]
            } else if let flatType = (raw["component"] as? String) ?? (raw["type"] as? String) {
                // v0.9 / v1.0 flat shape: {"id": "x", "component": "Text", "text": "..."}
                typeName = flatType
                props = raw
            } else {
                return nil
            }

            let kind = parseKind(typeName: typeName, props: props)
            return A2UIComponent(id: id, kind: kind, weight: weight)
        }

        private func parseKind(typeName: String, props: [String: Any]) -> A2UIComponent.Kind {
            switch typeName.lowercased() {
            case "column", "vstack":
                return .column(
                    children: A2UIChildren.parse(props["children"]),
                    alignment: (props["alignment"] as? String) ?? (props["align"] as? String),
                    distribution: (props["distribution"] as? String) ?? (props["justify"] as? String),
                    spacing: (props["spacing"] as? NSNumber)?.doubleValue
                )

            case "row", "hstack":
                return .row(
                    children: A2UIChildren.parse(props["children"]),
                    alignment: (props["alignment"] as? String) ?? (props["align"] as? String),
                    distribution: (props["distribution"] as? String) ?? (props["justify"] as? String),
                    spacing: (props["spacing"] as? NSNumber)?.doubleValue
                )

            case "card":
                let singleChild = props["child"] as? String
                let listChildren: [String]? = {
                    if case .explicit(let ids) = A2UIChildren.parse(props["children"]), !ids.isEmpty { return ids }
                    return nil
                }()
                return .card(
                    child: singleChild,
                    children: listChildren,
                    title: A2UIBinding.parse(props["title"])
                )

            case "list":
                return .list(
                    children: A2UIChildren.parse(props["children"]),
                    direction: props["direction"] as? String
                )

            case "tabs":
                let rawTabs = (props["tabItems"] as? [[String: Any]]) ?? (props["tabs"] as? [[String: Any]]) ?? []
                let items: [A2UITabItem] = rawTabs.compactMap { item in
                    guard let title = A2UIBinding.parse(item["title"] ?? item["label"]),
                          let child = item["child"] as? String, !child.isEmpty else { return nil }
                    return A2UITabItem(title: title, child: child)
                }
                return .tabs(items: items)

            case "divider", "separator":
                return .divider(axis: props["axis"] as? String)

            case "text":
                let text = A2UIBinding.parse(props["text"] ?? props["value"] ?? props["label"]) ?? .literal(.string(""))
                let variant = (props["usageHint"] as? String) ?? (props["variant"] as? String) ?? (props["style"] as? String)
                return .text(text: text, variant: variant)

            case "icon":
                let name = A2UIBinding.parse(props["name"] ?? props["icon"]) ?? .literal(.string("sparkles"))
                let color = props["color"] as? String
                let size = (props["size"] as? NSNumber)?.doubleValue
                return .icon(name: name, color: color, size: size)

            case "image":
                let url = A2UIBinding.parse(props["url"] ?? props["src"]) ?? .literal(.string(""))
                let alt = A2UIBinding.parse(props["alt"] ?? props["description"])
                let fit = props["fit"] as? String
                let variant = (props["usageHint"] as? String) ?? (props["variant"] as? String)
                return .image(url: url, alt: alt, fit: fit, variant: variant)

            case "badge", "chip", "tag":
                let text = A2UIBinding.parse(props["text"] ?? props["label"] ?? props["value"]) ?? .literal(.string(""))
                let tone = (props["tone"] as? String) ?? (props["variant"] as? String) ?? (props["color"] as? String)
                return .badge(text: text, tone: tone)

            case "progressbar", "progress":
                let value = A2UIBinding.parse(props["value"]) ?? .literal(.number(0))
                let maxVal = (props["max"] as? NSNumber)?.doubleValue ?? (props["total"] as? NSNumber)?.doubleValue
                let label = A2UIBinding.parse(props["label"])
                return .progressBar(value: value, max: maxVal, label: label)

            case "textfield", "input", "textarea":
                let label = A2UIBinding.parse(props["label"])
                let text = A2UIBinding.parse(props["text"] ?? props["value"])
                let placeholder = A2UIBinding.parse(props["placeholder"])
                let variant = (props["textFieldType"] as? String)
                    ?? (props["variant"] as? String)
                    ?? (typeName.lowercased() == "textarea" ? "longText" : nil)
                return .textField(label: label, text: text, placeholder: placeholder, variant: variant)

            case "checkbox", "toggle", "switch":
                let label = A2UIBinding.parse(props["label"])
                let value = A2UIBinding.parse(props["value"] ?? props["checked"])
                let isSwitch = typeName.lowercased() != "checkbox" || (props["variant"] as? String)?.lowercased() == "switch"
                return .checkBox(label: label, value: value, isSwitch: isSwitch)

            case "multiplechoice", "choicepicker", "select", "radiogroup", "segmentedcontrol":
                let label = A2UIBinding.parse(props["label"])
                let selections = A2UIBinding.parse(props["selections"] ?? props["value"] ?? props["selection"])
                let rawOptions = (props["options"] as? [Any]) ?? []
                let options: [A2UIChoiceOption] = rawOptions.compactMap { rawOpt in
                    if let str = rawOpt as? String {
                        return A2UIChoiceOption(label: .literal(.string(str)), value: str)
                    }
                    guard let dict = rawOpt as? [String: Any] else { return nil }
                    let val = (dict["value"] as? String) ?? (dict["id"] as? String) ?? (dict["label"] as? String)
                    guard let val, !val.isEmpty else { return nil }
                    let lbl = A2UIBinding.parse(dict["label"]) ?? .literal(.string(val))
                    return A2UIChoiceOption(label: lbl, value: val)
                }
                let maxAllowed = (props["maxAllowedSelections"] as? NSNumber)?.intValue
                    ?? ((props["variant"] as? String)?.lowercased() == "mutuallyexclusive" ? 1 : nil)
                    ?? (typeName.lowercased() == "radiogroup" || typeName.lowercased() == "segmentedcontrol" || typeName.lowercased() == "select" ? 1 : nil)
                let variant = (props["variant"] as? String)
                    ?? (typeName.lowercased() == "segmentedcontrol" ? "segmented" : nil)
                return .choicePicker(label: label, selections: selections, options: options, maxAllowedSelections: maxAllowed, variant: variant)

            case "slider":
                let label = A2UIBinding.parse(props["label"])
                let value = A2UIBinding.parse(props["value"])
                let minVal = (props["minValue"] as? NSNumber)?.doubleValue ?? (props["min"] as? NSNumber)?.doubleValue ?? 0
                let maxVal = (props["maxValue"] as? NSNumber)?.doubleValue ?? (props["max"] as? NSNumber)?.doubleValue ?? 100
                let step = (props["step"] as? NSNumber)?.doubleValue
                return .slider(label: label, value: value, min: minVal, max: max(maxVal, minVal + 0.01), step: step)

            case "datetimeinput", "datepicker":
                let label = A2UIBinding.parse(props["label"])
                let value = A2UIBinding.parse(props["value"])
                let enableDate = (props["enableDate"] as? Bool) ?? true
                let enableTime = (props["enableTime"] as? Bool) ?? false
                return .dateTimeInput(label: label, value: value, enableDate: enableDate, enableTime: enableTime)

            case "chart", "barchart", "linechart", "areachart", "piechart", "donutchart":
                let inferredType: String? = {
                    if let explicit = (props["chartType"] as? String) ?? (props["variant"] as? String) ?? (props["mark"] as? String) {
                        return explicit
                    }
                    switch typeName.lowercased() {
                    case "linechart": return "line"
                    case "areachart": return "area"
                    case "piechart": return "pie"
                    case "donutchart": return "donut"
                    default: return "bar"
                    }
                }()
                let title = A2UIBinding.parse(props["title"] ?? props["label"])
                let data = A2UIBinding.parse(props["data"] ?? props["values"] ?? props["points"]) ?? .literal(.array([]))
                let xKey = (props["xKey"] as? String) ?? (props["xField"] as? String) ?? (props["labelKey"] as? String) ?? "label"
                let yKey = (props["yKey"] as? String) ?? (props["yField"] as? String) ?? (props["valueKey"] as? String) ?? "value"
                let seriesKey = (props["seriesKey"] as? String) ?? (props["seriesField"] as? String) ?? (props["groupKey"] as? String)
                let xLabel = props["xLabel"] as? String
                let yLabel = props["yLabel"] as? String
                let height = (props["height"] as? NSNumber)?.doubleValue
                let showLegend = (props["showLegend"] as? Bool) ?? true
                return .chart(
                    title: title,
                    chartType: A2UIChartType(raw: inferredType),
                    data: data,
                    xKey: xKey,
                    yKey: yKey,
                    seriesKey: seriesKey,
                    xLabel: xLabel,
                    yLabel: yLabel,
                    height: height,
                    showLegend: showLegend
                )

            case "button":
                let child = props["child"] as? String
                let label = A2UIBinding.parse(props["label"] ?? props["text"])
                let variant: String? = {
                    if let v = props["variant"] as? String { return v }
                    if let primary = props["primary"] as? Bool { return primary ? "primary" : "secondary" }
                    if let destructive = props["destructive"] as? Bool, destructive { return "destructive" }
                    return nil
                }()
                let action = A2UIAction.parse(props["action"])
                return .button(child: child, label: label, variant: variant, action: action)

            default:
                return .unsupported(typeName: typeName)
            }
        }
    }
}

// MARK: - JSON Pointer

enum A2UIJSONPointer {
    static func resolvePath(_ path: String, basePath: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return basePath ?? "/" }
        if trimmed.hasPrefix("/") { return trimmed }
        let cleaned = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        guard let basePath, !basePath.isEmpty, basePath != "/" else {
            return "/" + cleaned
        }
        let normalizedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return normalizedBase + "/" + cleaned
    }

    static func tokens(for path: String) -> [String] {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !normalized.isEmpty else { return [] }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0)
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }

    static func get(_ path: String, in root: [String: A2UIValue]) -> A2UIValue? {
        let parts = tokens(for: path)
        if parts.isEmpty { return .object(root) }
        var current: A2UIValue = .object(root)
        for part in parts {
            switch current {
            case .object(let dict):
                guard let next = dict[part] else { return nil }
                current = next
            case .array(let arr):
                guard let idx = Int(part), arr.indices.contains(idx) else { return nil }
                current = arr[idx]
            default:
                return nil
            }
        }
        return current
    }

    static func setting(_ newValue: A2UIValue, at path: String, in root: [String: A2UIValue]) -> [String: A2UIValue] {
        let parts = tokens(for: path)
        guard !parts.isEmpty else {
            if case .object(let dict) = newValue { return dict }
            return root
        }
        let updated = setRecursive(newValue, tokens: parts[...], in: .object(root))
        if case .object(let dict) = updated { return dict }
        return root
    }

    private static func setRecursive(_ newValue: A2UIValue, tokens: ArraySlice<String>, in current: A2UIValue) -> A2UIValue {
        guard let head = tokens.first else { return newValue }
        let tail = tokens.dropFirst()

        if let idx = Int(head), case .array(var arr) = current {
            while arr.count <= idx { arr.append(.null) }
            arr[idx] = tail.isEmpty ? newValue : setRecursive(newValue, tokens: tail, in: arr[idx])
            return .array(arr)
        }

        var dict: [String: A2UIValue]
        if case .object(let existing) = current {
            dict = existing
        } else {
            dict = [:]
        }
        let existingChild = dict[head] ?? .object([:])
        dict[head] = tail.isEmpty ? newValue : setRecursive(newValue, tokens: tail, in: existingChild)
        return .object(dict)
    }
}

// MARK: - Observable Data Store

@MainActor
@Observable
final class A2UIDataStore {
    var root: [String: A2UIValue]
    private(set) var userEditedPaths: Set<String> = []
    /// Tracks paths bound by interactive input controls so default action payloads know what fields exist.
    private var inputPaths: [String] = []
    private var inputLabels: [String: String] = [:]

    init(initialData: [String: A2UIValue] = [:]) {
        self.root = initialData
    }

    /// Merges updated initial data from streaming chunks without clobbering any path the user already edited.
    func syncInitialData(_ incoming: [String: A2UIValue]) {
        mergeIncoming(incoming, prefix: "")
    }

    private func mergeIncoming(_ incoming: [String: A2UIValue], prefix: String) {
        for (key, value) in incoming {
            let fullPath = prefix + "/" + key
            if userEditedPaths.contains(fullPath) { continue }
            if case .object(let nested) = value,
               case .object = A2UIJSONPointer.get(fullPath, in: root) {
                mergeIncoming(nested, prefix: fullPath)
            } else {
                root = A2UIJSONPointer.setting(value, at: fullPath, in: root)
            }
        }
    }

    func registerInput(path: String, label: String?) {
        if !inputPaths.contains(path) {
            inputPaths.append(path)
        }
        if let label, !label.isEmpty {
            inputLabels[path] = label
        }
    }

    func value(at path: String, basePath: String? = nil) -> A2UIValue? {
        let resolved = A2UIJSONPointer.resolvePath(path, basePath: basePath)
        return A2UIJSONPointer.get(resolved, in: root)
    }

    func setValue(_ value: A2UIValue, at path: String, basePath: String? = nil) {
        let resolved = A2UIJSONPointer.resolvePath(path, basePath: basePath)
        userEditedPaths.insert(resolved)
        root = A2UIJSONPointer.setting(value, at: resolved, in: root)
    }

    func resolve(_ binding: A2UIBinding?, basePath: String? = nil) -> A2UIValue? {
        guard let binding else { return nil }
        switch binding {
        case .literal(let v):
            return v
        case .path(let p):
            return value(at: p, basePath: basePath)
        case .pathWithFallback(let p, let fallback):
            if let existing = value(at: p, basePath: basePath), !existing.isEmpty {
                return existing
            }
            return fallback
        }
    }

    func resolveString(_ binding: A2UIBinding?, basePath: String? = nil) -> String {
        resolve(binding, basePath: basePath)?.stringValue ?? ""
    }

    /// Formats a button's `userAction` into a clean, readable chat message with key-value details.
    func formatActionMessage(action: A2UIAction, buttonLabel: String?, basePath: String? = nil) -> String {
        let title: String = {
            if let buttonLabel, !buttonLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return buttonLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return Self.humanizeKey(action.name)
        }()

        var pairs: [(String, String)] = []
        if !action.context.isEmpty {
            for entry in action.context {
                guard let resolved = resolve(entry.value, basePath: basePath), !resolved.isEmpty else { continue }
                pairs.append((Self.humanizeKey(entry.key), resolved.displayString))
            }
        } else if !inputPaths.isEmpty {
            for path in inputPaths {
                guard let val = value(at: path), !val.isEmpty else { continue }
                let key = inputLabels[path] ?? Self.humanizeKey(A2UIJSONPointer.tokens(for: path).last ?? path)
                pairs.append((key, val.displayString))
            }
        }

        let formatted: String
        if pairs.isEmpty {
            formatted = title
        } else if pairs.count <= 4 && pairs.allSatisfy({ !$0.1.contains("\n") && $0.1.count <= 60 }) {
            let summary = pairs.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
            formatted = "\(title) — \(summary)"
        } else {
            let lines = pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            formatted = "\(title)\n\(lines)"
        }
        return String(formatted.prefix(2_000))
    }

    static func humanizeKey(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        // Split snake_case, kebab-case, and camelCase into readable words.
        var words: [String] = []
        var current = ""
        for ch in cleaned {
            if ch == "_" || ch == "-" || ch == "/" || ch == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else if ch.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.enumerated().map { idx, word in
            if idx == 0 {
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            return word
        }.joined(separator: " ")
    }
}

// MARK: - Chart Data Extraction

struct A2UIChartDatum: Identifiable, Hashable, Sendable {
    var id: Int
    var label: String
    var value: Double
    var series: String?
}

extension A2UIChartDatum {
    static func extract(from value: A2UIValue?, xKey: String, yKey: String, seriesKey: String?) -> [A2UIChartDatum] {
        guard case .array(let items) = value else { return [] }
        var out: [A2UIChartDatum] = []
        out.reserveCapacity(items.count)
        for (idx, item) in items.enumerated() {
            guard case .object(let dict) = item else { continue }
            let label = dict[xKey]?.stringValue
                ?? dict["label"]?.stringValue
                ?? dict["x"]?.stringValue
                ?? dict["name"]?.stringValue
                ?? dict["category"]?.stringValue
                ?? "#\(idx + 1)"
            guard let numeric = dict[yKey]?.doubleValue
                ?? dict["value"]?.doubleValue
                ?? dict["y"]?.doubleValue
                ?? dict["amount"]?.doubleValue
                ?? dict["count"]?.doubleValue else { continue }
            let series = seriesKey.flatMap { dict[$0]?.stringValue }
                ?? dict["series"]?.stringValue
                ?? dict["group"]?.stringValue
            out.append(A2UIChartDatum(id: idx, label: label, value: numeric, series: series))
        }
        return out
    }
}
