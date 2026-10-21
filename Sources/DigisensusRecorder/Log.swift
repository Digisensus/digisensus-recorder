import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "com.digisensus.recorder.log")
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Digisensus Recorder.log")

    private static let sizeLimit = 2_000_000
    nonisolated(unsafe) private static var checkedSize = false

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if !checkedSize {
                checkedSize = true
                rollOverIfLarge()
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return "\(error)" }
        return "\(urlError.localizedDescription) (URLError \(urlError.code.rawValue))"
    }

    private static func rollOverIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > sizeLimit else { return }
        let previous = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
