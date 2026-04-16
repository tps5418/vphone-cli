import Darwin
import Foundation

final class VPhoneClipboardBridgeServer: @unchecked Sendable {
    private struct Request: Decodable {
        let textBase64: String
    }

    private struct Response: Encodable {
        let ok: Bool
        let message: String
        let bytes: Int?
    }

    let socketURL: URL
    private let control: VPhoneControl
    private let queue = DispatchQueue(label: "vphone.clipboard.bridge", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(socketURL: URL, control: VPhoneControl) {
        self.socketURL = socketURL
        self.control = control
    }

    func start() throws {
        stop()

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket() failed for clipboard bridge"]
            )
        }

        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "clipboard bridge socket path is too long"]
            )
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { ptr in
                ptr.initialize(repeating: 0, count: pathBytes.count + 1)
                for (index, byte) in pathBytes.enumerated() {
                    ptr[index] = CChar(bitPattern: byte)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrLen)
            }
        }
        guard bindResult == 0 else {
            let errorCode = errno
            close(fd)
            unlink(socketURL.path)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "bind() failed for clipboard bridge"]
            )
        }

        guard listen(fd, 8) == 0 else {
            let errorCode = errno
            close(fd)
            unlink(socketURL.path)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "listen() failed for clipboard bridge"]
            )
        }

        chmod(socketURL.path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        listenFD = fd
        acceptSource = source
        print("[clipboard-bridge] listening on \(socketURL.path)")
    }

    func stop() {
        if let acceptSource {
            self.acceptSource = nil
            listenFD = -1
            acceptSource.cancel()
        } else if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }

        unlink(socketURL.path)
    }

    private func acceptPendingConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                print("[clipboard-bridge] accept failed: \(String(cString: strerror(errno)))")
                return
            }

            queue.async { [weak self] in
                guard let self else {
                    close(clientFD)
                    return
                }
                Task {
                    let response = await self.handleConnection(clientFD: clientFD)
                    self.writeResponse(response, to: clientFD)
                    shutdown(clientFD, SHUT_RDWR)
                    close(clientFD)
                }
            }
        }
    }

    private func handleConnection(clientFD: Int32) async -> Response {
        let requestData = readAll(from: clientFD)
        guard !requestData.isEmpty else {
            return Response(ok: false, message: "empty request", bytes: nil)
        }

        let decoder = JSONDecoder()
        let request: Request
        do {
            request = try decoder.decode(Request.self, from: requestData)
        } catch {
            return Response(ok: false, message: "invalid request JSON: \(error)", bytes: nil)
        }

        guard let textData = Data(base64Encoded: request.textBase64) else {
            return Response(ok: false, message: "invalid base64 payload", bytes: nil)
        }
        guard textData.count <= 1_000_000 else {
            return Response(ok: false, message: "clipboard payload too large", bytes: textData.count)
        }
        guard let text = String(data: textData, encoding: .utf8) else {
            return Response(ok: false, message: "clipboard payload is not valid UTF-8", bytes: textData.count)
        }

        do {
            try await control.clipboardSet(text: text)
            return Response(ok: true, message: "guest clipboard updated", bytes: textData.count)
        } catch {
            return Response(ok: false, message: "\(error)", bytes: textData.count)
        }
    }

    private func readAll(from fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            break
        }

        return data
    }

    private func writeResponse(_ response: Response, to fd: Int32) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(response) else { return }
        _ = data.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return false }
            return writeAll(fd: fd, buffer: baseAddress.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
    }

    private func writeAll(fd: Int32, buffer: UnsafePointer<UInt8>, count: Int) -> Bool {
        var totalWritten = 0
        while totalWritten < count {
            let written = write(fd, buffer.advanced(by: totalWritten), count - totalWritten)
            if written <= 0 {
                return false
            }
            totalWritten += written
        }
        return true
    }
}
