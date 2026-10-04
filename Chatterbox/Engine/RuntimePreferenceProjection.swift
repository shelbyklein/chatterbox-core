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
            for (key,value) in prefs {
                switch value{case .string(let x):AppPreferences.defaults.set(x,forKey:key);case .bool(let x):AppPreferences.defaults.set(x,forKey:key);case .number(let x):AppPreferences.defaults.set(x,forKey:key);default:break}
            }
            last=values();updating=false
            if observer==nil {
                observer=NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.changed()}}
            }
        }catch{Diagnostics.note(error.localizedDescription)}
    }
    private func values()->[String:JSON]{
        var values:[String:JSON]=[:]
        #if GOLEM_APP
        let keys:Set<String>=["dotDefaultBackend","dotDefaultModel","dotApplyDefault","dotSeenItem"]
        #else
        let keys=RuntimePreferences.keys.subtracting(["companionDevices","pins","companionEnabled"])
        #endif
        for key in keys{
            guard let value=AppPreferences.defaults.object(forKey:key) else{continue}
            if let string=value as? String{values[key] = .string(string)}
            else if let number=value as? NSNumber{values[key]=CFGetTypeID(number)==CFBooleanGetTypeID() ? .bool(number.boolValue):.number(number.doubleValue)}
        }
        return values
    }
    private func changed(){
        guard !updating else{return}
        let fresh=values();var changes=fresh.filter{last[$0.key] != $0.value}
        for key in last.keys where fresh[key]==nil{changes[key] = .null}
        guard !changes.isEmpty else{return}
        last=fresh;RuntimeClient.shared.command("preferences",body:.object(changes))
    }
}
