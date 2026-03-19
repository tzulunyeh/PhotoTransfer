import Foundation
import Network
import Observation

@Observable
final class TransferServer {
    var isListening = false
    var hasClient = false

    private var listener: NWListener?
    private var connection: NWConnection?
    // Dedicated queue: provider() blocks here, not on NWConnection's callback queue.
    private let sendQueue = DispatchQueue(label: "phototransfer.send", qos: .userInitiated)
    // Each accepted connection gets a UUID so stateUpdateHandler callbacks
    // from a cancelled old connection don't clobber hasClient for the new one.
    private var currentConnectionID: UUID = UUID()

    func start() {
        let params = NWParameters.tcp
        params.defaultProtocolStack.transportProtocol.map {
            let tcp = $0 as? NWProtocolTCP.Options
            tcp?.noDelay = true
            tcp?.enableKeepalive = true
            tcp?.keepaliveInterval = 30
        }

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(integerLiteral: TransferConstants.port)) else {
            print("[TransferServer] Failed to create listener")
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("[TransferServer] Listening on port \(TransferConstants.port)")
                    self?.isListening = true
                case .failed(let error):
                    print("[TransferServer] Listener failed: \(error)")
                    self?.isListening = false
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
        DispatchQueue.main.async {
            self.isListening = false
            self.hasClient = false
        }
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn

        let connectionID = UUID()
        currentConnectionID = connectionID

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                // Guard against stale callbacks from a previously cancelled connection
                guard let self, self.currentConnectionID == connectionID else { return }
                switch state {
                case .ready:
                    print("[TransferServer] Client connected")
                    self.hasClient = true
                case .failed(let error):
                    print("[TransferServer] Connection failed: \(error)")
                    self.hasClient = false
                case .cancelled:
                    self.hasClient = false
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
    }

    // Send a file using a data provider closure.
    // provider is called repeatedly until it returns nil (EOF).
    func sendFile(header: TransferHeader, provider: @escaping () -> Data?, completion: @escaping (Error?) -> Void) {
        guard let conn = connection else {
            completion(NSError(domain: "TransferServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No client connected"]))
            return
        }

        let headerData = TransferProtocol.encodeHeader(header)
        conn.send(content: headerData, completion: .contentProcessed { error in
            if let error {
                completion(error)
                return
            }
            self.sendNextChunk(conn: conn, provider: provider, completion: completion)
        })
    }

    private func sendNextChunk(conn: NWConnection, provider: @escaping () -> Data?, completion: @escaping (Error?) -> Void) {
        // Run provider() on sendQueue so blocking dequeue() never stalls NWConnection's callback queue.
        sendQueue.async {
            guard let chunk = provider(), !chunk.isEmpty else {
                // EOF — signal end of this file's stream (do not close connection)
                completion(nil)
                return
            }
            conn.send(content: chunk, completion: .contentProcessed { error in
                if let error {
                    completion(error)
                    return
                }
                self.sendNextChunk(conn: conn, provider: provider, completion: completion)
            })
        }
    }
}
