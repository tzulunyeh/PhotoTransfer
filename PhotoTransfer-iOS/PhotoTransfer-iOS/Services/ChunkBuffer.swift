import Foundation

// Bridges PHAssetResourceManager callbacks → NWConnection send provider.
//
// Pass-through design: each chunk is immediately available for dequeue,
// preserving read/send pipelining. Backpressure (32 MB ceiling) prevents
// unbounded memory growth if the network is slower than disk.

final class ChunkBuffer: @unchecked Sendable {
    static let maxQueueBytes = 32 * 1024 * 1024   // 32 MB backpressure ceiling

    private var queue      = [Data]()
    private var readIdx    = 0
    private var queuedBytes = 0
    private var finished   = false
    private let cond = NSCondition()

    func enqueue(_ data: Data) {
        cond.lock()
        // Backpressure: block if queued bytes exceed ceiling (also unblocked by abort)
        while queuedBytes >= ChunkBuffer.maxQueueBytes && !finished {
            cond.wait()
        }
        if finished { cond.unlock(); return }
        queue.append(data)
        queuedBytes += data.count
        cond.signal()
        cond.unlock()
    }

    func finish(withError error: Bool) {
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    /// Immediately stops all blocking — dequeue() returns nil, enqueue() drops new data.
    func abort() {
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }

    /// Returns the next chunk, blocking until data is available.
    /// Returns nil at EOF or after abort().
    func dequeue() -> Data? {
        cond.lock()
        defer { cond.unlock() }

        while true {
            if readIdx < queue.count {
                let chunk = queue[readIdx]
                readIdx += 1
                queuedBytes -= chunk.count
                // Compact the array once enough slots have been consumed
                if readIdx >= 8 {
                    queue.removeFirst(readIdx)
                    readIdx = 0
                }
                cond.signal() // wake enqueue (backpressure slot freed)
                return chunk
            }
            if finished {
                return nil
            }
            cond.wait()
        }
    }
}
