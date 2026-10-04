import Foundation

/// Versioned, explicit runtime preferences. Window geometry and UI-only settings never
/// cross this boundary. Existing app defaults are copied only by the adoption tool.
enum RuntimePreferences {
    static let keys:Set<String>=[
        "defaultBackend","defaultModel","defaultEffort","defaultPersonality","claudePath","codexPath","codexFolder",
        "codexDefaultModel","codexDefaultEffort","claudeDefaultMode","codexDefaultMode","remoteControlClaudeChats","easyCLIProxyEnabled",
        "companionEnabled","companionDevices","pins","openWebsitePinsInApp",
        "plugin.nextSteps.enabled","plugin.nextSteps.minAnswerChars","plugin.nextSteps.suggestCommands",
        "mobilePushEnabled","mobilePushLastStatus"
        ,"dotDefaultBackend","dotDefaultModel","dotApplyDefault","dotSeenItem","mobilePushConfigured","mobilePushPreviews","mobilePushSound"
    ]
    static var file:URL{RuntimePaths.data.appendingPathComponent("runtime-preferences.plist")}
    static func load() throws {
        guard FileManager.default.fileExists(atPath:file.path) else{return}
        let raw=try PropertyListSerialization.propertyList(from:Data(contentsOf:file),format:nil) as? [String:Any] ?? [:]
        for (key,value) in raw where keys.contains(key){AppPreferences.defaults.set(value,forKey:key)}
    }
    static func update(_ values:[String:JSON]) throws {
        guard Set(values.keys).isSubset(of:keys.subtracting(["companionDevices"])) else{throw RuntimeFailure("unsupported_preference")}
        var existing=AppPreferences.defaults.dictionaryRepresentation().filter{keys.contains($0.key)}
        for (key,value) in values {
            switch value {
            case .string(let x):existing[key]=x
            case .bool(let x):existing[key]=x
            case .number(let x):existing[key]=x
            case .null:existing.removeValue(forKey:key)
            default:throw RuntimeFailure("invalid_preference_value")
            }
        }
        let data=try PropertyListSerialization.data(fromPropertyList:existing.filter{keys.contains($0.key)},format:.binary,options:0)
        try data.write(to:file,options:.atomic)
        for key in values.keys{AppPreferences.defaults.set(existing[key],forKey:key)}
    }
    static func persistCurrent() throws {
        let values=AppPreferences.defaults.dictionaryRepresentation().filter{keys.contains($0.key)}
        try PropertyListSerialization.data(fromPropertyList:values,format:.binary,options:0).write(to:file,options:.atomic)
    }
}
