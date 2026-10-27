import Foundation

final class AgentSocketServer {
    private let path: String
    private let handler: (Data) async -> Data
    private var descriptor: Int32 = -1
    private var socketFile: ino_t?
    private let connections = DispatchQueue(label: "com.digisensus.recorder.agent.connections", attributes: .concurrent)
    private let openSlots = DispatchSemaphore(value: 4)

    private static let requestLimit = 1 << 20
    private static let ioTimeout = 10

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
        guard bound == 0, chmod(path, 0o600) == 0, listen(socketDescriptor, 8) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(socketDescriptor)
            unlink(path)
            throw error
        }

        descriptor = socketDescriptor
        socketFile = Self.inode(of: path)
        let thread = Thread { [weak self] in self?.acceptLoop(socketDescriptor) }
        thread.name = "com.digisensus.recorder.agent.accept"
        thread.start()
    }

    func stop() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        if let socketFile, Self.inode(of: path) == socketFile { unlink(path) }
        socketFile = nil
    }

    private static func inode(of path: String) -> ino_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_ino : nil
    }

    private func acceptLoop(_ listening: Int32) {
        while true {
            let client = accept(listening, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            openSlots.wait()
            connections.async { [weak self] in
                self?.serve(client)
                self?.openSlots.signal()
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: Self.ioTimeout, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

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
