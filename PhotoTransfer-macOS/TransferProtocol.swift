import Foundation

struct TransferHeader {
    let filename: String
    let fileSize: UInt64
    let creationDate: Date
}

enum TransferProtocol {
    // Encode: [4B magic BE][4B filename length BE][N B filename UTF-8][8B file size BE][8B creation date ms BE]
    static func encodeHeader(_ header: TransferHeader) -> Data {
        let filenameData = header.filename.data(using: .utf8) ?? Data()
        let creationMs = UInt64(max(0, header.creationDate.timeIntervalSince1970 * 1000))
        var result = Data()
        appendUInt32BE(TransferConstants.magic, to: &result)
        appendUInt32BE(UInt32(filenameData.count), to: &result)
        result.append(filenameData)
        appendUInt64BE(header.fileSize, to: &result)
        appendUInt64BE(creationMs, to: &result)
        return result
    }

    // Returns parsed header and total bytes consumed (header bytes only, not file content).
    static func decodeHeader(from data: Data) -> (header: TransferHeader, bytesConsumed: Int)? {
        guard data.count >= 4 + 4 + 8 else { return nil }

        let magic = readUInt32BE(from: data, at: data.startIndex)
        guard magic == TransferConstants.magic else { return nil }

        let nameLen = Int(readUInt32BE(from: data, at: data.startIndex + 4))
        let totalHeaderSize = 4 + 4 + nameLen + 8 + 8
        guard data.count >= totalHeaderSize else { return nil }

        let nameStart = data.startIndex + 8
        guard let filename = String(data: data[nameStart ..< nameStart + nameLen], encoding: .utf8) else { return nil }

        let sizeOffset = nameStart + nameLen
        let fileSize = readUInt64BE(from: data, at: sizeOffset)

        let dateOffset = sizeOffset + 8
        let creationMs = readUInt64BE(from: data, at: dateOffset)
        let creationDate = creationMs > 0
            ? Date(timeIntervalSince1970: Double(creationMs) / 1000)
            : Date()

        return (TransferHeader(filename: filename, fileSize: fileSize, creationDate: creationDate), totalHeaderSize)
    }

    // MARK: - Byte helpers (no alignment assumptions)

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8)  & 0xFF))
        data.append(UInt8( value        & 0xFF))
    }

    private static func appendUInt64BE(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8)  & 0xFF))
        data.append(UInt8( value        & 0xFF))
    }

    static func readUInt32BE(from data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])     << 24 |
        UInt32(data[index + 1]) << 16 |
        UInt32(data[index + 2]) << 8  |
        UInt32(data[index + 3])
    }

    static func readUInt64BE(from data: Data, at index: Data.Index) -> UInt64 {
        UInt64(data[index])     << 56 |
        UInt64(data[index + 1]) << 48 |
        UInt64(data[index + 2]) << 40 |
        UInt64(data[index + 3]) << 32 |
        UInt64(data[index + 4]) << 24 |
        UInt64(data[index + 5]) << 16 |
        UInt64(data[index + 6]) << 8  |
        UInt64(data[index + 7])
    }
}
