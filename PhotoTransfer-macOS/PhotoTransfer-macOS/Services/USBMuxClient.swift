import Foundation
import Network


// Pure Swift usbmuxd client.
// Packet format: [4B length LE (incl. header)][4B version=1 LE][4B type=8 LE][4B tag LE][binary plist]
final class USBMuxClient {
    enum USBMuxError: Error {
        case connectionFailed(String)
        case noDeviceFound
        case connectFailed(Int)
        case invalidResponse
    }

    private static let usbmuxdPath = "/var/run/usbmuxd"
    private static let headerSize = 16

    // Connect to iPhone's TCP port via usbmuxd tunnel.
    // On success, the returned NWConnection is a raw TCP stream to the iPhone app.
    static func connectToDevice(port: UInt16) async throws -> NWConnection {
        // Step 1: List devices
        let deviceID = try await listDevices()
        print("[USBMuxClient] Found device ID: \(deviceID)")

        // Step 2: Connect tunnel
        let conn = try await connectTunnel(deviceID: deviceID, port: port)
        print("[USBMuxClient] Tunnel established")
        return conn
    }

    // MARK: - Private

    private static func listDevices() async throws -> Int {
        let conn = makeConnection()
        try await waitForReady(conn)

        let payload: [String: Any] = [
            "MessageType": "ListDevices",
            "ClientVersionString": "PhotoTransfer",
            "ProgName": "PhotoTransfer"
        ]
        try await sendPacket(payload, tag: 1, conn: conn)
        let response = try await receivePacket(conn)
        conn.cancel()

        guard let deviceList = response["DeviceList"] as? [[String: Any]],
              let first = deviceList.first,
              let props = first["Properties"] as? [String: Any],
              let deviceID = props["DeviceID"] as? Int else {
            throw USBMuxError.noDeviceFound
        }
        return deviceID
    }

    private static func connectTunnel(deviceID: Int, port: UInt16) async throws -> NWConnection {
        let conn = makeConnection()
        try await waitForReady(conn)

        // PortNumber must be big-endian UInt16 value placed as an integer in the plist
        let portBE = Int(port.bigEndian)
        let payload: [String: Any] = [
            "MessageType": "Connect",
            "ClientVersionString": "PhotoTransfer",
            "ProgName": "PhotoTransfer",
            "DeviceID": deviceID,
            "PortNumber": portBE
        ]
        try await sendPacket(payload, tag: 2, conn: conn)
        let response = try await receivePacket(conn)

        guard let resultCode = response["Number"] as? Int else {
            throw USBMuxError.invalidResponse
        }
        guard resultCode == 0 else {
            throw USBMuxError.connectFailed(resultCode)
        }

        // From this point the connection is a raw TCP stream — return it as-is
        return conn
    }

    private static func makeConnection() -> NWConnection {
        let endpoint = NWEndpoint.unix(path: Self.usbmuxdPath)
        let params = NWParameters.tcp
        params.defaultProtocolStack.transportProtocol.map {
            let tcp = $0 as? NWProtocolTCP.Options
            tcp?.enableKeepalive = true
            tcp?.keepaliveInterval = 30
        }
        return NWConnection(to: endpoint, using: params)
    }

    private static func waitForReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak conn] state in
                switch state {
                case .ready:
                    conn?.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    conn?.stateUpdateHandler = nil
                    cont.resume(throwing: USBMuxError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    conn?.stateUpdateHandler = nil
                    cont.resume(throwing: USBMuxError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func sendPacket(_ payload: [String: Any], tag: UInt32, conn: NWConnection) async throws {
        let plistData = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        let totalLength = UInt32(Self.headerSize + plistData.count)

        var header = Data(count: Self.headerSize)
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: totalLength.littleEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: UInt32(1).littleEndian,   toByteOffset: 4, as: UInt32.self) // version
            ptr.storeBytes(of: UInt32(8).littleEndian,   toByteOffset: 8, as: UInt32.self) // type: plist
            ptr.storeBytes(of: tag.littleEndian,          toByteOffset: 12, as: UInt32.self)
        }

        let packet = header + plistData
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: packet, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    private static func receivePacket(_ conn: NWConnection) async throws -> [String: Any] {
        // Read header first
        let headerData: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: Self.headerSize, maximumLength: Self.headerSize) { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, data.count == Self.headerSize else {
                    cont.resume(throwing: USBMuxError.invalidResponse); return
                }
                cont.resume(returning: data)
            }
        }

        // Read length as little-endian UInt32 without alignment assumptions
        let totalLength = Int(
            UInt32(headerData[0]) |
            UInt32(headerData[1]) << 8 |
            UInt32(headerData[2]) << 16 |
            UInt32(headerData[3]) << 24
        )
        let plistLength = totalLength - Self.headerSize
        guard plistLength > 0 else { return [:] }

        let plistData: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: plistLength, maximumLength: plistLength) { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                guard let data else { cont.resume(throwing: USBMuxError.invalidResponse); return }
                cont.resume(returning: data)
            }
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw USBMuxError.invalidResponse
        }
        return plist
    }
}
