import Foundation
import Observation
import Darwin

/// A UI projection transport: no provider processes or store writes live here.
@MainActor @Observable final class RuntimeClient {
    static let shared=RuntimeClient()
    static var usesDaemon:Bool {
        let env=ProcessInfo.processInfo.environment
        if env["CHATTERBOX_LEGACY_RUNTIME"] == "1" {return false}
        if env["CHATTERBOX_DAEMON_CLIENT"] == "1" {return true}
        guard let dir=env["CHATTERBOX_DATA_DIR"] else {return true}
        #if CHATTERBOX_HEADLESS
        // The services are given their data folder and run its conversations themselves.
        return false
        #else
        // Legacy native regression harnesses opt into their own isolated in-process fixture. A
        // window app handed the background service's own store instead (launched from a chat's
        // shell, which carries the service's environment) uses the service: in-process it would
        // refuse that store and show no chats at all.
        return FileManager.default.fileExists(atPath:URL(fileURLWithPath:dir).appendingPathComponent("runtime-owner.json").path)
        #endif
    }
    private(set) var connected=false
    private(set) var supportsPriorityList=false
    private(set) var supportsNavigationSummaries=false
    /// The service's "metadata" op takes only the fields that changed (RuntimeOutbox).
    private(set) var supportsMetadataFields=false
    private(set) var problem:String?
    var onEvent:((RuntimeEvent)->Void)?
    @ObservationIgnored private var socket:RuntimeSocket?
    @ObservationIgnored private var generation=0
    @ObservationIgnored private var waiters:[String:CheckedContinuation<JSON,Error>]=[:]
    @ObservationIgnored private let writes=DispatchQueue(label:"chatterbox.runtime.client.write")
    @ObservationIgnored private var connectionTask:Task<Void,Never>?
    @ObservationIgnored private var role="ui"
    @ObservationIgnored private var cursor=0
    @ObservationIgnored private let socketName:String
    init(socketName:String="daemon.sock"){self.socketName=socketName}
    func start(role:String="ui") {
        self.role=role
        guard connectionTask==nil else{return}
        connectionTask=Task { [weak self] in
            var delay=1.0
            while !Task.isCancelled {
                guard let self else{return}
                if self.socket==nil {
                    do {
                        try self.connect()
                        let hello = try await self.request("hello",body:["role":.string(self.role)])
                        self.supportsPriorityList = hello["priorityList"]?.bool == true
                        self.supportsNavigationSummaries = hello["navigationSummaries"]?.bool == true
                        self.supportsMetadataFields = hello["metadataFields"]?.bool == true
                        let replay=try await self.request("subscribe",body:["after":.number(Double(self.cursor))])
                        self.connected=true;self.problem=nil;delay=1
                        // A full snapshot replaces expired/initial history. Replaying it first
                        // launched thousands of redundant refreshes before the list could load.
                        if self.cursor > 0, replay["resync"]?.bool != true,
                           let events=try replay["events"]?.decode([RuntimeEvent].self) {
                            for event in events { self.deliver(event) }
                        }
                        self.cursor=max(self.cursor,replay["sequence"]?.int ?? 0)
                        self.onEvent?(RuntimeEvent(sequence:self.cursor,revision:0,kind:"runtime.resync"))
                    }catch{self.problem=error.localizedDescription;self.disconnect()}
                }
                try? await Task.sleep(for:.seconds(delay));delay=min(30,delay*1.5)
            }
        }
    }
    func stop(){connectionTask?.cancel();connectionTask=nil;disconnect()}
    private func connect() throws {
        let socket=RuntimePaths.data.appendingPathComponent(socketName)
        guard let fd=UnixSocket.connect(to:socket) else{throw RuntimeFailure("Chatterbox's background service is unavailable. Start it in service settings.")}
        var uid:uid_t=0,gid:gid_t=0
        guard getpeereid(fd,&uid,&gid)==0,uid==getuid() else{Darwin.close(fd);throw RuntimeFailure("Unexpected runtime identity")}
        let connection=RuntimeSocket(fd);self.socket=connection;generation += 1;let generation=self.generation
        Thread { [weak self,connection] in
            // `scanned`: bytes already known to hold no newline. Looking through the whole buffer
            // again for each chunk made a multi-megabyte reply take tens of seconds to read.
            var buffer=Data(),bytes=[UInt8](repeating:0,count:65536),scanned=0
            while true {
                let n=Darwin.read(connection.fd,&bytes,bytes.count)
                if n<0,errno==EINTR{continue};if n<=0{break}
                buffer.append(contentsOf:bytes.prefix(n));if buffer.count>16*1024*1024{break}
                defer{scanned=buffer.count}
                while let end=buffer[(buffer.startIndex+scanned)...].firstIndex(of:10){
                    let line=buffer.subdata(in:buffer.startIndex..<end);buffer.removeSubrange(buffer.startIndex...end);scanned=0
                    let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
                    guard let reply=try? d.decode(RuntimeReply.self,from:line) else{continue}
                    DispatchQueue.main.async {MainActor.assumeIsolated {guard self?.generation==generation else{return};self?.receive(reply)}}
                }
            }
            DispatchQueue.main.async {MainActor.assumeIsolated {guard self?.generation==generation else{return};self?.problem="Background service disconnected";self?.disconnect()}}
        }.start()
    }
    /// What each request was, for the breadcrumbs: which operation, for which session, since when.
    private struct Asked { let operation:String; let chat:String?; let started:ContinuousClock.Instant }
    private var asked:[String:Asked]=[:]
    /// Requests that timed out, kept so a late reply can say how long the service really took.
    private var late:[String:Asked]=[:]
    /// The session's name for a breadcrumb (set by the app), else its ID.
    static var chatName:(UUID)->String? = { _ in nil }
    /// A reply slower than this is noted even when it arrived in time.
    private static let slowReply:Duration = .seconds(5)

    private static func label(_ asked:Asked)->String{
        guard let chat=asked.chat else{return asked.operation}
        let name=UUID(uuidString:chat).flatMap(chatName) ?? chat
        return "\(asked.operation) in \u{201C}\(name)\u{201D}"
    }
    private static func seconds(_ d:Duration)->String{String(format:"%.1f s",Double(d.components.seconds)+Double(d.components.attoseconds)/1e18)}

    private func disconnect(){
        generation += 1;connected=false
        asked.removeAll();late.removeAll()
        socket?.stop();socket=nil
        let pending=waiters;waiters.removeAll()
        for w in pending.values{w.resume(throwing:RuntimeFailure("Connection lost; command delivery may be uncertain. Reconnect and inspect before resending."))}
    }
    /// `timeout`: how long to wait for the reply. A request that waits on you (a system
    /// prompt) needs longer than the usual 15 seconds.
    func request(_ operation:String,body:JSON=[:],id:String=UUID().uuidString,timeout:Duration = .seconds(15)) async throws -> JSON {
        guard let connection=socket,connection.active else{throw RuntimeFailure("Background service disconnected; nothing was sent")}
        let request=RuntimeRequest(id:id,operation:operation,body:body)
        let chat=body["chatID"]?.string ?? body["chat"]?.string ?? (operation=="get" || operation=="fork" ? nil : body["id"]?.string)
        asked[id]=Asked(operation:operation,chat:chat,started:.now)
        var data=try JSONEncoder().encode(request);data.append(10)
        let generation=self.generation,bytes=data
        return try await withCheckedThrowingContinuation { continuation in
            guard waiters[id]==nil else{continuation.resume(throwing:RuntimeFailure("Request ID is already pending"));return}
            waiters[id]=continuation
            writes.async {
                var succeeded=connection.active
                bytes.withUnsafeBytes {raw in
                    var offset=0
                    while succeeded && offset<raw.count {
                        let n=Darwin.write(connection.fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                        if n<0,errno==EINTR{continue};if n<=0{succeeded=false;break};offset += n
                    }
                }
                if !succeeded{DispatchQueue.main.async {MainActor.assumeIsolated {guard self.generation==generation else{return};self.disconnect()}}}
            }
            Task { [weak self] in
                try? await Task.sleep(for:timeout)
                guard let self,let w=self.waiters.removeValue(forKey:id) else{return}
                if let a=self.asked.removeValue(forKey:id){
                    self.late[id]=a
                    if self.late.count>100,let oldest=self.late.min(by:{$0.value.started<$1.value.started})?.key{self.late[oldest]=nil}
                    RuntimeHooks.note("Timed out after \(Self.seconds(timeout)): \(Self.label(a)), with \(self.waiters.count) other request\(self.waiters.count==1 ? "" : "s") waiting on the service")
                }
                w.resume(throwing:RuntimeFailure("Runtime request timed out; inspect the session before retrying"))
            }
        }
    }
    func command(_ operation:String,body:JSON=[:]){
        Task {
            do{_ = try await request(operation,body:body)}
            catch{
                // Drafts are re-sent until confirmed, and session metadata, settings, pins,
                // Studios and preferences go through RuntimeOutbox (kept until confirmed), so a
                // slow reply to one isn't worth interrupting you; failed commands still show.
                if Self.backgroundSyncs.contains(operation){NSLog("Chatterbox: background sync \(operation) failed: \(error.localizedDescription)")}
                else{problem=error.localizedDescription}
            }
        }
    }
    func clearProblem(){problem=nil}
    /// A failure worth showing that didn't come from `command` (RuntimeOutbox gives up on a change).
    func report(_ problem:String){self.problem=problem}
    private static let backgroundSyncs:Set<String>=["setDraft","metadata","preferences","pins","studios"]
    private func receive(_ reply:RuntimeReply){
        if let event=reply.event{deliver(event);return}
        guard let id=reply.id else{return}
        guard let waiter=waiters.removeValue(forKey:id) else{
            // Answered after we stopped waiting: how long the service really took.
            if let a=late.removeValue(forKey:id){
                RuntimeHooks.note("The service answered \(Self.label(a)) after \(Self.seconds(a.started.duration(to:.now))), too late\(reply.error.map{": \($0)"} ?? "")")
            }
            return
        }
        if let a=asked.removeValue(forKey:id){
            let took=a.started.duration(to:.now)
            if took>Self.slowReply{RuntimeHooks.note("Slow reply: \(Self.label(a)) took \(Self.seconds(took))")}
        }
        if let error=reply.error{waiter.resume(throwing:RuntimeFailure(error))}else{waiter.resume(returning:reply.result ?? .null)}
    }
    private func deliver(_ event:RuntimeEvent){cursor=max(cursor,event.sequence);onEvent?(event)}
}
