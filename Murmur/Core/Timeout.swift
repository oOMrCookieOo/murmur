import Foundation
import os

/// Runs `operation`, returning nil if `timeout` elapses first.
///
/// Deliberately not a `TaskGroup`. A task group implicitly awaits every child
/// before returning, so `cancelAll()` only bounds the wall clock if the losing
/// task actually observes cancellation. Measured against a non-cooperative
/// operation, a 300 ms group "timeout" returned after 2 s — useless for
/// anything on a latency budget.
///
/// Racing a continuation instead lets us genuinely abandon the loser: it is
/// still cancelled cooperatively, but we stop waiting for it either way.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let hasResumed = OSAllocatedUnfairLock(initialState: false)

        @Sendable func finish(_ value: T?) {
            let shouldResume = hasResumed.withLock { resumed -> Bool in
                if resumed { return false }
                resumed = true
                return true
            }
            if shouldResume { continuation.resume(returning: value) }
        }

        let work = Task(priority: .userInitiated) { finish(await operation()) }

        Task {
            try? await Task.sleep(for: timeout)
            work.cancel()   // cooperative, in case the operation honours it
            finish(nil)     // resume regardless; we do not wait for the loser
        }
    }
}
