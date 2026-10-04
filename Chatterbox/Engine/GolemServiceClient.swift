#if GOLEM_APP
import Foundation
import Observation
import Darwin

@MainActor @Observable final class GolemServiceClient {
    static let shared=GolemServiceClient()
    let transport=RuntimeClient(socketName:"golem.sock")
    var paused=false
    var problem:String?
    var checkInTimes:[Int]=[480,900]
    var emailThrough:Date?
    var sweeping=false
    func refresh() async {
        transport.start()
        guard transport.connected else{problem=transport.problem;return}
        do {
            let health=try await transport.request("health");paused=health["paused"]?.bool ?? false;problem=health["problem"]?.string
            checkInTimes=(try? health["checkInTimes"]?.decode([Int].self)) ?? [480,900]
            emailThrough=health["emailThrough"]?.string.flatMap{ISO8601DateFormatter().date(from:$0)}
            sweeping=health["sweeping"]?.bool ?? false
            for (key,value) in health["preferences"]?.object ?? [:]{if let enabled=value.bool{AppPreferences.defaults.set(enabled,forKey:key)}}
        }
        catch{problem=error.localizedDescription}
    }
    func command(_ op:String,_ body:JSON=[:]){transport.command(op,body:body)}
    func startInstalledService() {
        guard ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] == nil else {
            problem="Isolated builds do not start installed services.";return
        }
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/launchctl")
        process.arguments=["kickstart","gui/\(getuid())/com.shelbyklein.golemd"]
        let output=Pipe();process.standardError=output;process.standardOutput=output
        do {
            try process.run()
            process.terminationHandler={ [weak self] process in
                Task { @MainActor in
                    if process.terminationStatus != 0 {self?.problem="Golem’s background service has not been enabled. Complete the approved service setup first."}
                    else {self?.transport.stop();self?.transport.start()}
                }
            }
        }catch{problem=error.localizedDescription}
    }
}


#endif
