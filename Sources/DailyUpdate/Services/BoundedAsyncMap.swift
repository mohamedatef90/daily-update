import Foundation

enum BoundedAsyncMap {
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrent: Int,
        operation: @escaping @Sendable (Input) async -> Output,
        onResult: @escaping (Int, Output) async -> Void = { _, _ in }
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, inputs.count))

        return await withTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            var results: [Int: Output] = [:]

            func addNextTask() {
                guard nextIndex < inputs.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    (index, await operation(inputs[index]))
                }
            }

            for _ in 0..<limit { addNextTask() }

            while let (index, output) = await group.next() {
                results[index] = output
                await onResult(index, output)
                addNextTask()
            }

            return inputs.indices.map { results[$0]! }
        }
    }
}
