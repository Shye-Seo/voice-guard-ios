import Foundation

/// `NotificationCenter` 옵저버 토큰을 보관하고, 소유자가 해제될 때 함께 정리한다.
///
/// 메인 엑터에 묶이지 않는 순수 컨테이너라 `deinit`에서 안전하게 토큰을 제거할 수 있다.
final class NotificationObserverBag {
    private var tokens: [NSObjectProtocol] = []
    private let lock = NSLock()

    func add(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
