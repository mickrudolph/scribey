import Foundation

enum TranscriptionError: Error {
    case notConnected
    case daemonError(String)
    case protocolError
}

final class TranscriptionClient {
    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.mickrudolph.scribey.transcription-client")

    var isConnected: Bool { socketFD >= 0 }

    func connect() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = ScribeyPaths.socketPath
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) { cPtr in
                path.withCString { srcPtr in
                    strncpy(cPtr, srcPtr, path.utf8.count)
                }
            }
        }

        let size = MemoryLayout<sockaddr_un>.size
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(fd, sockPtr, socklen_t(size))
            }
        }

        if result != 0 {
            close(fd)
            return false
        }

        socketFD = fd
        return true
    }

    func disconnect() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    func transcribe(path: URL, completion: @escaping (Result<String, TranscriptionError>) -> Void) {
        queue.async {
            guard self.socketFD >= 0 else {
                DispatchQueue.main.async { completion(.failure(.notConnected)) }
                return
            }

            let requestObj: [String: Any] = ["cmd": "transcribe", "path": path.path]
            guard let payload = try? JSONSerialization.data(withJSONObject: requestObj) else {
                DispatchQueue.main.async { completion(.failure(.protocolError)) }
                return
            }

            guard self.writeFrame(payload) else {
                self.disconnect()
                DispatchQueue.main.async { completion(.failure(.notConnected)) }
                return
            }

            guard let responseData = self.readFrame() else {
                self.disconnect()
                DispatchQueue.main.async { completion(.failure(.notConnected)) }
                return
            }

            guard let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.protocolError)) }
                return
            }

            if let ok = obj["ok"] as? Bool, ok, let text = obj["text"] as? String {
                DispatchQueue.main.async { completion(.success(text)) }
            } else {
                let message = obj["error"] as? String ?? "unknown daemon error"
                DispatchQueue.main.async { completion(.failure(.daemonError(message))) }
            }
        }
    }

    private func writeFrame(_ payload: Data) -> Bool {
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        let full = header + payload
        var written = 0
        let bytes = [UInt8](full)
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBufferPointer { buf in
                send(socketFD, buf.baseAddress, buf.count, 0)
            }
            if n <= 0 { return false }
            written += n
        }
        return true
    }

    private func readFrame() -> Data? {
        var header = [UInt8](repeating: 0, count: 4)
        guard readExact(into: &header, count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        var payload = [UInt8](repeating: 0, count: Int(length))
        guard readExact(into: &payload, count: Int(length)) else { return nil }
        return Data(payload)
    }

    private func readExact(into buffer: inout [UInt8], count: Int) -> Bool {
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                recv(socketFD, buf.baseAddress!.advanced(by: received), count - received, 0)
            }
            if n <= 0 { return false }
            received += n
        }
        return true
    }
}
