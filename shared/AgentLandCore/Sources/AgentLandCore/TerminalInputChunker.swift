import Foundation

public enum TerminalInputChunkError: Error, Equatable, Sendable { case invalidUTF8, tooLarge }

public enum TerminalInputChunker {
    public static let maximumChunkBytes = 32_768
    public static let maximumPasteBytes = 262_144

    public static func chunks(_ data: Data) throws -> [Data] {
        guard data.count <= maximumPasteBytes else { throw TerminalInputChunkError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw TerminalInputChunkError.invalidUTF8 }
        var result: [Data] = []
        var current = Data()
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if current.count + bytes.count > maximumChunkBytes {
                result.append(current)
                current = Data()
            }
            current.append(bytes)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
