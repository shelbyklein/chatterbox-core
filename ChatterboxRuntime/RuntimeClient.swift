import Foundation
import Observation
import Darwin

/// A UI projection transport: no provider processes or store writes live here.
@MainActor @Observable final class RuntimeClient {
    static let shared=RuntimeClient()
    static var usesDaemon:Bool {
        if ProcessInfo.processInfo.environment["CHATTERBOX_LEGACY_RUNTIME"] == "1" {return false}
        // Legacy native regression harnesses opt into their own isolated in-process fixture.
        return ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] == nil || ProcessInfo.processInfo.environment["CHATTERBOX_DAEMON_CLIENT"] == "1"
    }
    private(set) var connected=false
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
                        _ = try await self.request("hello",body:["role":.string(self.role)])
                        let replay=try await self.request("subscribe",body:["after":.number(Double(self.cursor))])
                        self.connected=true;self.problem=nil;delay=1
                        if let events=try replay["events"]?.decode([RuntimeEvent].self){for event in events{self.deliver(event)}}
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
            var buffer=Data(),bytes=[UInt8](repeating:0,count:65536)
            while true {
                let n=Darwin.read(connection.fd,&bytes,bytes.count)
                if n<0,errno==EINTR{continue};if n<=0{break}
                buffer.append(contentsOf:bytes.prefix(n));if buffer.count>16*1024*1024{break}
                while let end=buffer.firstIndex(of:10){
                    let line=buffer.subdata(in:buffer.startIndex..<end);buffer.removeSubrange(buffer.startIndex...end)
                    let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
                    guard let reply=try? d.decode(RuntimeReply.self,from:line) else{continue}
                    DispatchQueue.main.async {MainActor.assumeIsolated {guard self?.generation==generation else{return};self?.receive(reply)}}
                }
            }
            DispatchQueue.main.async {MainActor.assumeIsolated {guard self?.generation==generation else{return};self?.problem="Background service disconnected";self?.disconnect()}}
        }.start()
    }
    private func disconnect(){
        generation += 1;connected=false
        socket?.stop();socket=nil
        let pending=waiters;waiters.removeAll()
        for w in pending.values{w.resume(throwing:RuntimeFailure("Connection lost; command delivery may be uncertain. Reconnect and inspect before resending."))}
    }
    func request(_ operation:String,body:JSON=[:],id:String=UUID().uuidString) async throws -> JSON {
        guard let connection=socket,connection.active else{throw RuntimeFailure("Background service disconnected; nothing was sent")}
        let request=RuntimeRequest(id:id,operation:operation,body:body)
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
                try? await Task.sleep(for:.seconds(15))
                if let w=self?.waiters.removeValue(forKey:id){w.resume(throwing:RuntimeFailure("Runtime request timed out; inspect the chat before retrying"))}
            }
        }
    }
    func command(_ operation:String,body:JSON=[:]){
        Task {do{_ = try await request(operation,body:body)}catch{problem=error.localizedDescription}}
    }
    func clearProblem(){problem=nil}
    private func receive(_ reply:RuntimeReply){
        if let event=reply.event{deliver(event);return}
        guard let id=reply.id,let waiter=waiters.removeValue(forKey:id) else{return}
        if let error=reply.error{waiter.resume(throwing:RuntimeFailure(error))}else{waiter.resume(returning:reply.result ?? .null)}
    }
    private func deliver(_ event:RuntimeEvent){cursor=max(cursor,event.sequence);onEvent?(event)}
}
