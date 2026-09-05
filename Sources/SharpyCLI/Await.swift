// A blocking bridge for the command surface.
//
// The CLI is synchronous on purpose: a command that returned before its work finished would print
// results nobody can rely on, and every command here exists to report a measurement.

import Foundation

/// Run async work and wait for it, rethrowing whatever it threw.
func await2<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch result! {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}
