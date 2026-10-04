import AppKit
import Observation

/// A launch/status adapter; it contains no assistant rendering or automation.
@MainActor @Observable final class GolemIntegration {
    static let shared=GolemIntegration()
    private(set) var enabled=true
    private(set) var problem:String?
    private var applicationURL:URL? {
        #if DEBUG
        if RuntimePaths.data.path.hasPrefix("/tmp/golem-"),let path=ProcessInfo.processInfo.environment["GOLEM_TEST_APP_PATH"] {
            return FileManager.default.fileExists(atPath:path) ? URL(fileURLWithPath:path):nil
        }
        #endif
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.shelbyklein.Golem")
    }
    var installed:Bool{applicationURL != nil}
    func refresh() async {
        do{let health=try await RuntimeClient.shared.request("health");enabled=health["integrationEnabled"]?.bool ?? false;problem=nil}
        catch{problem=error.localizedDescription}
    }
    func setEnabled(_ value:Bool){Task{
        do{_ = try await RuntimeClient.shared.request("integration",body:["enabled":.bool(value)]);await refresh()}
        catch{problem=error.localizedDescription}
    }}
    func open(){
        guard let url=applicationURL else{problem="Golem is not installed.";return}
        let configuration=NSWorkspace.OpenConfiguration()
        if ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] != nil {
            configuration.createsNewApplicationInstance=true
            configuration.arguments=["-ApplePersistenceIgnoreState","YES"]
            configuration.environment=ProcessInfo.processInfo.environment
        }
        NSWorkspace.shared.openApplication(at:url,configuration:configuration){[weak self] _,error in
            if let error{Task{@MainActor in self?.problem=error.localizedDescription}}
        }
    }
}
