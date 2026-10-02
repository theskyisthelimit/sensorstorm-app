import Foundation

/// Runs `work` over `inputs` with at most `limit` in flight at once, and returns the results in
/// the order they finished.
///
/// A scan starts hundreds of probes; started all at once they would exhaust file descriptors
/// and make the first answers look slow. Stops taking new inputs when the task is cancelled
/// and returns what has finished.
func concurrentMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], limit: Int,
    _ work: @escaping @Sendable (Input) async -> Output
) async -> [Output] {
    await withTaskGroup(of: Output.self) { group in
        var results: [Output] = []
        var active = 0
        for input in inputs {
            if Task.isCancelled { break }
            if active >= limit, let finished = await group.next() {
                results.append(finished)
                active -= 1
            }
            group.addTask { await work(input) }
            active += 1
        }
        for await finished in group { results.append(finished) }
        return results
    }
}
