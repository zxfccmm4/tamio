//
//  BalancedEmitter.swift
//  TamioAssistant
//
//  FlowDown-inspired streaming text pacer that smooths bursty SSE chunks into
//  a steady cadence so MarkdownView's fade-in reveal feels fluid rather than jumpy.
//

import Foundation

public actor BalancedEmitter {
    private var buffer = ""
    private var isRunning = false
    private var continuation: CheckedContinuation<Void, Never>?

    private let onEmit: @Sendable (String) -> Void
    private var duration: Double
    private var frequency: Int
    private var batchSize = 1

    public init(
        duration: Double = 0.35,
        frequency: Int = 30,
        onEmit: @escaping @Sendable (String) -> Void
    ) {
        self.duration = duration
        self.frequency = max(1, frequency)
        self.onEmit = onEmit
    }

    public func add(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        buffer += chunk
        batchSize = max(1, Int(ceil(Double(buffer.count) / Double(frequency))))
        dispatchLoopIfRequired()
    }

    public func flushAndWait() async {
        if buffer.isEmpty, !isRunning { return }
        await withCheckedContinuation { cont in
            clean()
            dispatchLoopIfRequired()
            if buffer.isEmpty, !isRunning {
                cont.resume()
            } else {
                continuation = cont
            }
        }
    }

    public func cancel() {
        buffer = ""
        clean()
    }

    private func dispatchLoopIfRequired() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let stepDelayMs = max(8, Int((duration * 1000) / Double(frequency)))
            while !buffer.isEmpty {
                let len = min(batchSize, buffer.count)
                let emitText = String(buffer.prefix(len))
                buffer.removeFirst(emitText.count)
                onEmit(emitText)
                if buffer.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(stepDelayMs))
            }
            isRunning = false
            clean()
        }
    }

    private func clean() {
        continuation?.resume()
        continuation = nil
    }
}
