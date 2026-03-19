import Foundation
import Photos
import PhotosUI
import UIKit
import Observation

@Observable
@MainActor
final class TransferViewModel {
    struct TransferStats {
        let sentCount: Int
        let failedCount: Int
        let totalBytes: Int64
        let duration: TimeInterval

        var averageSpeedMBps: Double {
            duration > 0 ? Double(totalBytes) / duration / 1_000_000 : 0
        }
    }

    enum TransferState {
        case idle
        case waitingForClient
        case transferring(filename: String)
        case done(TransferStats)
        case error(String)
    }

    var assets: [PhotoAsset] = []
    var transferState: TransferState = .idle
    var progress: Double = 0
    var speedMBps: Double = 0

    var selectedAssets: [PhotoAsset] { assets }

    private let server: TransferServer
    private let library = PhotoLibraryService()
    private let bytesBox = BytesBox()
    private var currentBuffer: ChunkBuffer?
    private var isCancelled = false

    init(server: TransferServer) {
        self.server = server
    }

    // Called after PHPickerViewController returns results.
    func setSelectedAssets(from results: [PHPickerResult]) {
        let identifiers = results.compactMap { $0.assetIdentifier }
        guard !identifiers.isEmpty else {
            assets = []
            return
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetMap: [String: PhotoAsset] = [:]
        fetchResult.enumerateObjects { phAsset, _, _ in
            let (filename, fileSize) = self.library.info(for: phAsset)
            let item = PhotoAsset(id: phAsset.localIdentifier, asset: phAsset, filename: filename, fileSize: fileSize)
            assetMap[phAsset.localIdentifier] = item
        }
        assets = identifiers.compactMap { assetMap[$0] }
        transferState = .idle
    }

    func startTransfer() {
        guard !selectedAssets.isEmpty else { return }
        guard server.hasClient else {
            transferState = .waitingForClient
            return
        }
        Task { await performTransfer() }
    }

    func cancelTransfer() {
        isCancelled = true
        currentBuffer?.abort()
    }

    // MARK: - Private

    private func performTransfer() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let targets = selectedAssets
        let totalBytes = targets.reduce(Int64(0)) { $0 + $1.fileSize }
        var sentCount = 0
        var failedCount = 0
        let startTime = Date()

        bytesBox.reset()

        // Throttle task: updates progress + speed at 0.3 s intervals instead of
        // dispatching to main on every chunk (which floods the main queue).
        let throttleTask = Task { [weak self] in
            guard let self else { return }
            var lastBytes: Int64 = 0
            var lastTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { break }
                let sent = self.bytesBox.read()
                self.progress = totalBytes > 0 ? Double(sent) / Double(totalBytes) : 0
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                if elapsed > 0 {
                    self.speedMBps = Double(sent - lastBytes) / elapsed / 1_000_000
                }
                lastBytes = sent
                lastTime = now
            }
        }
        defer { throttleTask.cancel() }

        for asset in targets {
            if isCancelled { break }
            transferState = .transferring(filename: asset.filename)

            let result = await sendAsset(asset, filename: asset.filename, fileSize: asset.fileSize) { [weak self] sent in
                self?.bytesBox.add(sent)
            }

            if isCancelled { break }
            if result { sentCount += 1 } else { failedCount += 1 }
        }

        speedMBps = 0

        if isCancelled {
            isCancelled = false
            progress = 0
            transferState = .idle
        } else {
            progress = 1.0
            let stats = TransferStats(
                sentCount: sentCount,
                failedCount: failedCount,
                totalBytes: bytesBox.read(),
                duration: Date().timeIntervalSince(startTime)
            )
            transferState = .done(stats)
        }
    }

    private func sendAsset(
        _ asset: PhotoAsset,
        filename: String,
        fileSize: Int64,
        onChunk: @escaping (Int) -> Void
    ) async -> Bool {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let buffer = ChunkBuffer()
            currentBuffer = buffer

            library.streamAssetData(for: asset.asset, handler: { data in
                buffer.enqueue(data)
            }, completion: { error in
                if let error {
                    print("[TransferViewModel] Stream error for \(filename): \(error)")
                    buffer.finish(withError: true)
                } else {
                    buffer.finish(withError: false)
                }
            })

            let header = TransferHeader(filename: filename, fileSize: UInt64(fileSize), creationDate: asset.asset.creationDate ?? Date())
            server.sendFile(header: header, provider: {
                let chunk = buffer.dequeue()
                if let chunk, !chunk.isEmpty {
                    onChunk(chunk.count)
                }
                return chunk
            }, completion: { error in
                if let error {
                    print("[TransferViewModel] Send error for \(filename): \(error)")
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            })
        }
        currentBuffer = nil
        return result
    }
}

// MARK: - BytesBox
// Thread-safe Int64 counter: incremented from NWConnection callbacks, read from main actor.

private final class BytesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func add(_ n: Int) { lock.withLock { value += Int64(n) } }
    func read() -> Int64 { lock.withLock { value } }
    func reset() { lock.withLock { value = 0 } }
}

