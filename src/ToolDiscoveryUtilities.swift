import Foundation

enum ToolDiscoveryUtilities {
    static func findExecutable(named toolName: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: toolName, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        var candidates = ["/usr/bin/\(toolName)"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":") {
                candidates.append(String(entry) + "/\(toolName)")
            }
        }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func isMachOExecutable(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else { return false }
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let known: Set<UInt32> = [
            0xFEEDFACE, 0xCEFAEDFE,
            0xFEEDFACF, 0xCFFAEDFE,
            0xCAFEBABE, 0xBEBAFECA,
            0xCAFEBABF, 0xBFBAFECA
        ]
        return known.contains(magic)
    }

    static func countSRTCues(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: .newlines).filter { $0.contains("-->") }.count
    }
}
