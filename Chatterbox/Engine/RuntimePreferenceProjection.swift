import Foundation
import CoreFoundation

@MainActor final class RuntimePreferenceProjection {
    static let shared=RuntimePreferenceProjection()
    private var observer:NSObjectProtocol?
    private var last:[String:JSON]=[:]
    private var updating=false
    func start() async {
        do {
            let prefs=try await RuntimeClient.shared.request("getPreferences").object ?? [:]
            updating=true
            // A setting changed here that the service hasn't confirmed keeps this Mac's value.
            let pending=RuntimeOutbox.shared.pendingPreferences()
            for (key,value) in prefs where key != ModelPresets.syncedKey && !pending.contains(key) {
                switch value{case .string(let x):AppPreferences.defaults.set(x,forKey:key);case .bool(let x):AppPreferences.defaults.set(x,forKey:key);case .number(let x):AppPreferences.defaults.set(x,forKey:key)
                case .array(let xs):AppPreferences.defaults.set(xs.compactMap(\.string),forKey:key);default:break}
            }
            last=values();updating=false
            // Settings the service has never had (a list it couldn't store before) go to it now.
            let missing=last.filter{prefs[$0.key]==nil && $0.key != ModelPresets.syncedKey}
            if !missing.isEmpty {RuntimeOutbox.shared.enqueue(nil,op:"preferences",values:missing)}
            // Presets are edited only here: the app's own copy is the one to keep.
            if let local=last[ModelPresets.syncedKey],prefs[ModelPresets.syncedKey] != local {
                RuntimeOutbox.shared.enqueue(nil,op:"preferences",values:[ModelPresets.syncedKey:local])
            }
            if observer==nil {
                observer=NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.changed()}}
            }
        }catch{Diagnostics.note(error.localizedDescription)}
    }
    private func values()->[String:JSON]{
        var values:[String:JSON]=[:]
        let keys=RuntimePreferences.keys.subtracting(["companionDevices","pins","companionEnabled"])
        for key in keys{
            guard let value=AppPreferences.defaults.object(forKey:key) else{continue}
            if let string=value as? String{values[key] = .string(string)}
            else if let number=value as? NSNumber{values[key]=CFGetTypeID(number)==CFBooleanGetTypeID() ? .bool(number.boolValue):.number(number.doubleValue)}
            else if let list=value as? [String]{values[key] = .array(list.map(JSON.string))}
        }
        return values
    }
    private func changed(){
        guard !updating else{return}
        let fresh=values();var changes=fresh.filter{last[$0.key] != $0.value}
        for key in last.keys where fresh[key]==nil{changes[key] = .null}
        guard !changes.isEmpty else{return}
        last=fresh;RuntimeOutbox.shared.enqueue(nil,op:"preferences",values:changes)
    }
}
