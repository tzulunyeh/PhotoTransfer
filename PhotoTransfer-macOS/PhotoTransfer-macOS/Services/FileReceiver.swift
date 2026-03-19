import Foundation
import Network

// Receives files from the TCP stream according to the transfer protocol.
// Writes each file to disk as .partial, then renames on completion.
final class FileReceiver {
    var onFileStarted: ((String) -> Void)?
    var onFileCompleted: ((String) -> Void)?
    var onProgress: ((UInt64, UInt64) -> Void)?   // (bytesReceived, totalBytes)
    var onError: ((Error) -> Void)?
    var onDisconnected: (() -> Void)?

    private enum State {
        case waitingForHeader(buffer: Data)
        case receivingFile(header: TransferHeader, bytesReceived: UInt64, fileHandle: FileHandle, partialURL: URL)
    }

    private let outputDirectory: URL
    private var state: State = .waitingForHeader(buffer: Data())

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func start(on connection: NWConnection) {
        receiveLoop(connection)
    }

    // MARK: - Private

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: TransferConstants.bufferSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.onError?(error)
                self.cleanup()
                self.onDisconnected?()
                return
            }

            if let data, !data.isEmpty {
                self.process(data)
            }

            if isComplete {
                self.cleanup()
                self.onDisconnected?()
                return
            }

            self.receiveLoop(conn)
        }
    }

    private func process(_ data: Data) {
        switch state {
        case .waitingForHeader(let buffer):
            let combined = buffer + data
            if let (header, consumed) = TransferProtocol.decodeHeader(from: combined) {
                print("[FileReceiver] Receiving '\(header.filename)' (\(header.fileSize) bytes)")
                onFileStarted?(header.filename)
                let (fileHandle, partialURL) = openPartialFile(filename: header.filename)
                state = .receivingFile(header: header, bytesReceived: 0, fileHandle: fileHandle, partialURL: partialURL)

                let leftover = combined.dropFirst(consumed)
                if !leftover.isEmpty {
                    process(Data(leftover))
                }
            } else {
                state = .waitingForHeader(buffer: combined)
            }

        case .receivingFile(let header, let bytesReceived, let fileHandle, let partialURL):
            let remaining = header.fileSize - bytesReceived
            let chunk = data.prefix(Int(min(remaining, UInt64(data.count))))

            fileHandle.write(chunk)
            let newBytesReceived = bytesReceived + UInt64(chunk.count)
            onProgress?(newBytesReceived, header.fileSize)

            if newBytesReceived >= header.fileSize {
                fileHandle.closeFile()
                finalizeFile(partialURL: partialURL, header: header)
                onFileCompleted?(header.filename)
                state = .waitingForHeader(buffer: Data())

                let leftover = data.dropFirst(chunk.count)
                if !leftover.isEmpty {
                    process(Data(leftover))
                }
            } else {
                state = .receivingFile(header: header, bytesReceived: newBytesReceived, fileHandle: fileHandle, partialURL: partialURL)
            }
        }
    }

    private func openPartialFile(filename: String) -> (FileHandle, URL) {
        let partialURL = outputDirectory.appendingPathComponent(filename + ".partial")
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        let fileHandle = FileHandle(forWritingAtPath: partialURL.path)!
        return (fileHandle, partialURL)
    }

    private func finalizeFile(partialURL: URL, header: TransferHeader) {
        let finalURL = outputDirectory.appendingPathComponent(header.filename)
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: partialURL, to: finalURL)
        // Restore original creation and modification dates from the device
        try? FileManager.default.setAttributes([
            .creationDate: header.creationDate,
            .modificationDate: header.creationDate
        ], ofItemAtPath: finalURL.path)
        print("[FileReceiver] Saved '\(header.filename)' (created: \(header.creationDate))")
    }

    private func cleanup() {
        // Delete any in-progress partial file on disconnect/error
        if case .receivingFile(_, _, let fileHandle, let partialURL) = state {
            fileHandle.closeFile()
            try? FileManager.default.removeItem(at: partialURL)
            print("[FileReceiver] Cleaned up partial file")
        }
        state = .waitingForHeader(buffer: Data())
    }
}
