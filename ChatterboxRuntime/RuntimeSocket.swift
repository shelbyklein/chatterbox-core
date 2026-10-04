import Foundation
import Darwin

/// Retained by readers and queued writes so a disconnected descriptor is never reused
/// underneath them. Shutdown wakes blocking reads; the last owner closes it.
final class RuntimeSocket: @unchecked Sendable {
    let fd:Int32
    private let lock=NSLock()
    private var stopped=false
    init(_ fd:Int32){self.fd=fd}
    var active:Bool{lock.lock();defer{lock.unlock()};return !stopped}
    func stop(){lock.lock();if !stopped{stopped=true;shutdown(fd,SHUT_RDWR)};lock.unlock()}
    deinit{Darwin.close(fd)}
}
