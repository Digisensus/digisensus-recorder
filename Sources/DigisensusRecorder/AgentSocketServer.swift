import Foundation

/// A Unix-domain socket that takes one JSON request per connection and answers with one
/// JSON reply, each terminated by a newline. There is deliberately no network listener:
/// the socket file is only reachable by processes of the same user.
final class AgentSocketServer {
    private let path: String
    private let handler: (Data) async -> Data
    private var descriptor: Int32 = -1
    private let connections = DispatchQueue(label: "com.digisensus.recorder.agent.connections", attributes: .concurrent)

    private static let requestLimit = 1 << 20

    init(path: String, handler: @escaping (Data) async -> Data) {
        self.path = path
        self.handler = handler
    }

    var isListening: Bool { descriptor >= 0 }

    func start() throws {
        guard descriptor < 0 else { return }
        unlink(path)

        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(socketDescriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Owner-only before anyone can connect.
        guard bound == 0, chmod(path, 0o600) == 0, listen(socketDescriptor, 8) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(socketDescriptor)
            unlink(path)
            throw error
        }

        descriptor = socketDescriptor
        let thread = Thread { [weak self] in self?.acceptLoop(socketDescriptor) }
        thread.name = "com.digisensus.recorder.agent.accept"
        thread.start()
    }

    func stop() {
        guard descriptor >= 0 else { return }
        // Closing the listening socket makes the blocked accept() fail, ending the loop.
        close(descriptor)
        descriptor = -1
        unlink(path)
    }

    private func acceptLoop(_ listening: Int32) {
        while true {
            let client = accept(listening, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            connections.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }

        // The file mode already limits this to the owner; check the peer anyway.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while !request.contains(UInt8(ascii: "\n")), request.count < Self.requestLimit {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            request.append(buffer, count: count)
        }
        guard !request.isEmpty else { return }

        let done = DispatchSemaphore(value: 0)
        var reply = Data()
        let handler = handler
        Task {
            reply = await handler(request)
            done.signal()
        }
        done.wait()

        reply.append(UInt8(ascii: "\n"))
        reply.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = send(client, bytes.baseAddress! + offset, bytes.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}
