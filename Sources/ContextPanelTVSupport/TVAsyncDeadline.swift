import Foundation

private enum TVAsyncDeadlineOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

public enum TVAsyncDeadline {
    public static func value<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard timeout > .zero else { return nil }

        let (stream, continuation) = AsyncStream<TVAsyncDeadlineOutcome<Value>>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let operationTask = Task {
            let value = await operation()
            continuation.yield(.value(value))
            continuation.finish()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            continuation.yield(.timedOut)
            continuation.finish()
        }

        defer {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }

        return await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            guard let outcome = await iterator.next() else { return nil }
            return switch outcome {
            case let .value(value):
                value
            case .timedOut:
                nil
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
    }
}
