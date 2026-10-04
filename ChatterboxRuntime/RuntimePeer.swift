import Foundation
import Darwin
import Security
import CryptoKit

/// Only signed user-facing apps can obtain approval/answer capabilities.
/// Other same-user peers receive the agent role and can suggest but never approve.
enum RuntimePeerIdentity {
    static func permitsUIRole(_ role:String,fd:Int32,root:URL)->Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CHATTERBOX_TEST_TRUST_UI"]=="1",root.path.hasPrefix("/tmp/golem-"){return true}
        #endif
        var pid:pid_t=0;var size=socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size)==0 else{return false}
        var code:SecCode?;var info:CFDictionary?;var staticCode:SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,[],&code)==errSecSuccess,let code,
              SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,let data=info as? [String:Any],
              let id=data[kSecCodeInfoIdentifier as String] as? String else{return false}
        return (role=="ui" && id=="com.shelbyklein.Chatterbox") || (role=="golem-ui" && id=="com.shelbyklein.Golem")
    }
    static func trustedUI(_ fd:Int32, root:URL,allowDaemon:Bool=false) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CHATTERBOX_TEST_TRUST_UI"] == "1",root.path.hasPrefix("/tmp/golem-") {return true}
        #endif
        var pid:pid_t=0;var size=socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size)==0 else {return false}
        var code:SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,[],&code)==errSecSuccess,let code else{return false}
        var info:CFDictionary?
        var staticCode:SecStaticCode?
        let validity=SecCodeCheckValidity(code,[],nil)
        let extraction=SecCodeCopyStaticCode(code,[],&staticCode)
        guard let staticCode else{return false}
        let signing=SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)
        guard validity==errSecSuccess,extraction==errSecSuccess,signing==errSecSuccess,
              let data=info as? [String:Any],let id=data[kSecCodeInfoIdentifier as String] as? String,
              let team=data[kSecCodeInfoTeamIdentifier as String] as? String,team=="9F3MKVW9C5" else {return false}
        return ["com.shelbyklein.Chatterbox","com.shelbyklein.Golem"].contains(id) || (allowDaemon && id=="com.shelbyklein.Chatterbox.Daemon")
    }
}

final class RuntimePeer: @unchecked Sendable {
    let fd:Int32
    let isTrustedUI:Bool
    let id=UUID()
    private let writes=DispatchQueue(label:"chatterboxd.peer.write")
    private let lock=NSLock()
    private var closed=false
    private var pendingBytes=0
    init(fd:Int32,trustedUI:Bool){self.fd=fd;isTrustedUI=trustedUI}
    func send(_ reply:RuntimeReply){
        let e=JSONEncoder();e.dateEncodingStrategy = .iso8601
        guard var data=try? e.encode(reply) else{return};data.append(10)
        lock.lock()
        guard !closed else {lock.unlock();return}
        pendingBytes += data.count
        if pendingBytes>8*1024*1024 {lock.unlock();stop();return}
        lock.unlock()
        let bytes=data
        writes.async { [self] in
            bytes.withUnsafeBytes { raw in
                var offset=0
                while offset<raw.count {
                    let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                    if n<0,errno==EINTR {continue}
                    guard n>0 else {stop();break};offset += n
                }
            }
            lock.lock();pendingBytes -= bytes.count;lock.unlock()
        }
    }
    func stop(){lock.lock();if !closed {closed=true;shutdown(fd,SHUT_RDWR)};lock.unlock()}
    deinit {Darwin.close(fd)}
}
