import Testing
import Foundation
@testable import PhotoTransfer_iOS

// MARK: - Basic pipeline

struct ChunkBufferBasicTests {

    @Test func enqueueDequeue() {
        let buf = ChunkBuffer()
        let data = Data([1, 2, 3])
        buf.enqueue(data)
        buf.finish(withError: false)
        #expect(buf.dequeue() == data)
        #expect(buf.dequeue() == nil)
    }

    @Test func multipleChunksInOrder() {
        let buf = ChunkBuffer()
        let chunks = (0..<10).map { Data([$0]) }
        for chunk in chunks { buf.enqueue(chunk) }
        buf.finish(withError: false)
        for expected in chunks {
            #expect(buf.dequeue() == expected)
        }
        #expect(buf.dequeue() == nil)
    }

    @Test func finishWithErrorStillDrainsQueue() {
        let buf = ChunkBuffer()
        buf.enqueue(Data([42]))
        buf.finish(withError: true)
        // Remaining data is still readable; nil signals end
        #expect(buf.dequeue() == Data([42]))
        #expect(buf.dequeue() == nil)
    }

    @Test func abortReturnsNilImmediately() {
        let buf = ChunkBuffer()
        buf.enqueue(Data([1]))
        buf.abort()
        // After abort, dequeue must return nil (does not drain)
        #expect(buf.dequeue() == nil)
    }
}

// MARK: - Concurrent stress

struct ChunkBufferConcurrencyTests {

    @Test func concurrentEnqueueDequeue() async {
        let buf = ChunkBuffer()
        let count = 200
        let chunkSize = 1024

        // Producer thread
        let producer = Thread {
            for i in 0..<count {
                buf.enqueue(Data(repeating: UInt8(i % 256), count: chunkSize))
            }
            buf.finish(withError: false)
        }
        producer.start()

        // Consumer on current thread
        var received = 0
        while let chunk = buf.dequeue() {
            #expect(chunk.count == chunkSize)
            received += 1
        }
        #expect(received == count)
    }

    @Test func abortUnblocksBlockedDequeue() async {
        let buf = ChunkBuffer()
        var dequeueResult: Data? = Data()   // non-nil sentinel

        let consumer = Thread {
            dequeueResult = buf.dequeue()   // will block until abort
        }
        consumer.start()

        // Give consumer time to block
        try? await Task.sleep(nanoseconds: 50_000_000)
        buf.abort()

        // Give consumer time to unblock
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(dequeueResult == nil)
    }
}

// MARK: - Backpressure

struct ChunkBufferBackpressureTests {

    @Test func backpressureBlocksEnqueueBeyondCeiling() async {
        let buf = ChunkBuffer()
        let ceiling = ChunkBuffer.maxQueueBytes
        // Fill to just below ceiling with a single large chunk
        let fillData = Data(count: ceiling - 1)
        buf.enqueue(fillData)   // should not block

        var enqueueCompleted = false
        let producer = Thread {
            // This enqueue should block (would exceed ceiling)
            buf.enqueue(Data(count: ceiling))
            enqueueCompleted = true
        }
        producer.start()

        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(!enqueueCompleted, "enqueue should still be blocked")

        // Draining one chunk frees space and unblocks the producer
        _ = buf.dequeue()
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(enqueueCompleted)

        buf.finish(withError: false)
        while buf.dequeue() != nil {}   // drain remaining
    }
}
