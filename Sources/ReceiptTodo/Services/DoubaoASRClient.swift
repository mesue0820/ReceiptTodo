import Foundation
import zlib

enum DoubaoASRError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case serverError(code: UInt32, message: String)
    case connectionClosed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在「设置 → 1. 语音识别引擎」中填入豆包语音 API Key。"
        case .invalidURL:
            return "豆包语音 WebSocket 地址格式不正确。"
        case .serverError(let code, let message):
            return "豆包语音服务返回错误 (\(code))：\(message)"
        case .connectionClosed(let reason):
            return "豆包语音连接断开：\(reason)"
        }
    }
}

/// Volcengine Doubao Streaming ASR 2.0 (SAUC v3) WebSocket client.
/// Uses the official NO_SEQUENCE framing (`0x10` Full Client Request, `0x20` Audio Chunk, `0x22` Final Audio Chunk)
/// over `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`.
final class DoubaoASRClient: @unchecked Sendable {
    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var isStopped = false
    private var latestTranscript: String = ""
    private var sentChunkCount: Int = 0
    private let lock = NSLock()

    private var onTranscript: ((String, Bool) -> Void)?
    private var onError: ((String) -> Void)?
    private var finalContinuation: CheckedContinuation<Void, Never>?

    private struct ServerPayload: Decodable {
        struct Utterance: Decodable {
            let text: String?
        }
        struct Result: Decodable {
            let text: String?
            let utterances: [Utterance]?
        }
        let result: Result?
    }

    func connect(
        settings: AppSettings,
        onTranscript: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        let apiKey = settings.doubaoAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw DoubaoASRError.missingAPIKey }

        let wsURLString = settings.doubaoWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: wsURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" else {
            throw DoubaoASRError.invalidURL
        }

        let resourceID = settings.doubaoResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveResourceID = resourceID.isEmpty ? AppSettings.defaultDoubaoResourceID : resourceID

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(effectiveResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        lock.withLock {
            self.onTranscript = onTranscript
            self.onError = onError
            self.isStopped = false
            self.latestTranscript = ""
            self.sentChunkCount = 0
        }

        let task = URLSession.shared.webSocketTask(with: request)
        lock.withLock { self.wsTask = task }
        task.resume()

        // Send initial Full Client Request (NO_SEQUENCE: 0x10) with optional inline hotwords
        let initFrame = Self.buildFullClientRequestFrame(hotwords: settings.parsedHotwords)
        try await task.send(.data(initFrame))

        // Start async receive loop
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendPCMChunk(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        let (task, stopped) = currentTaskAndState()
        guard let task, !stopped else { return }

        lock.withLock { sentChunkCount += 1 }
        let frame = Self.buildAudioOnlyFrame(pcmData: pcmData, isLast: false)
        task.send(.data(frame)) { [weak self] error in
            if let error {
                let (_, alreadyStopped) = self?.currentTaskAndState() ?? (nil, true)
                if !alreadyStopped {
                    self?.onError?("豆包音频发送失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// Sends the final negative audio packet (`0x22`) and waits for Doubao's final pass transcript,
    /// returning the latest synchronized transcript directly to avoid MainActor race conditions.
    func finishAndCollectFinal(remainingPCM: Data = Data()) async -> String {
        let (task, stopped) = currentTaskAndState()
        if let task, !stopped {
            let finalFrame = Self.buildAudioOnlyFrame(pcmData: remainingPCM, isLast: true)
            try? await task.send(.data(finalFrame))

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await withCheckedContinuation { cont in
                        self?.setFinalContinuation(cont)
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                }
                await group.next()
                group.cancelAll()
            }
            resolveFinalContinuation()
        }

        let finalText = lock.withLock { latestTranscript }
        disconnect()
        return finalText
    }

    func disconnect() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            isStopped = true
            let t = wsTask
            wsTask = nil
            return t
        }
        resolveFinalContinuation()
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Connection Test (used in SettingsView)

    static func testConnection(settings: AppSettings) async throws -> String {
        let apiKey = settings.doubaoAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw DoubaoASRError.missingAPIKey }

        let wsURLString = settings.doubaoWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: wsURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" else {
            throw DoubaoASRError.invalidURL
        }

        let resourceID = settings.doubaoResourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveResourceID = resourceID.isEmpty ? AppSettings.defaultDoubaoResourceID : resourceID

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(effectiveResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let initFrame = buildFullClientRequestFrame(hotwords: settings.parsedHotwords)
        try await task.send(.data(initFrame))

        let silentPCM = Data(repeating: 0, count: 3200) // 100ms 16kHz 16-bit mono silence
        let finalFrame = buildAudioOnlyFrame(pcmData: silentPCM, isLast: true)
        try await task.send(.data(finalFrame))

        let message = try await task.receive()
        switch message {
        case .data(let data):
            let parsed = parseServerFrame(data)
            if let err = parsed.error {
                throw DoubaoASRError.serverError(code: err.code, message: err.message)
            }
            return "豆包语音连接成功（\(effectiveResourceID)）"
        case .string(let text):
            return "豆包语音已连通：\(text.prefix(40))"
        @unknown default:
            return "豆包语音连接成功"
        }
    }

    // MARK: - Receive Loop

    private func currentTaskAndState() -> (URLSessionWebSocketTask?, Bool) {
        lock.withLock { (wsTask, isStopped) }
    }

    private func updateLatestTranscript(_ text: String) {
        lock.withLock {
            if !text.isEmpty {
                latestTranscript = text
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let (task, stopped) = currentTaskAndState()
            guard let task, !stopped else { break }

            do {
                let message = try await task.receive()
                if case .data(let data) = message {
                    let parsed = Self.parseServerFrame(data)
                    if let err = parsed.error {
                        onError?("豆包语音错误 (\(err.code))：\(err.message)")
                        resolveFinalContinuation()
                        break
                    }
                    if let text = parsed.text, !text.isEmpty {
                        updateLatestTranscript(text)
                        onTranscript?(text, parsed.isFinal)
                    }
                    if parsed.isFinal {
                        resolveFinalContinuation()
                        break
                    }
                }
            } catch {
                let (_, alreadyStopped) = currentTaskAndState()
                if !alreadyStopped {
                    onError?("豆包语音连接异常：\(error.localizedDescription)")
                }
                resolveFinalContinuation()
                break
            }
        }
    }

    private func setFinalContinuation(_ cont: CheckedContinuation<Void, Never>) {
        lock.withLock { finalContinuation = cont }
    }

    private func resolveFinalContinuation() {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            let c = finalContinuation
            finalContinuation = nil
            return c
        }
        cont?.resume()
    }

    // MARK: - Binary Framing Builders & Parser (Volcengine SAUC v3 NO_SEQUENCE mode)

    private static func buildFullClientRequestFrame(hotwords: [String] = []) -> Data {
        var requestConfig: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "show_utterances": true
        ]

        // Volcengine SAUC v3 direct inline hotwords: request.corpus.context = stringified JSON
        if !hotwords.isEmpty {
            let hotwordObjs = hotwords.map { ["word": $0] }
            if let ctxData = try? JSONSerialization.data(withJSONObject: ["hotwords": hotwordObjs]),
               let ctxStr = String(data: ctxData, encoding: .utf8) {
                requestConfig["corpus"] = ["context": ctxStr]
            }
        }

        let payloadObj: [String: Any] = [
            "user": [
                "uid": "receipttodo-mac"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ],
            "request": requestConfig
        ]

        let jsonData = (try? JSONSerialization.data(withJSONObject: payloadObj)) ?? Data("{}".utf8)

        var frame = Data()
        // Byte 0: version 1 (0x1) | header size 1 (0x1 -> 4 bytes)
        // Byte 1: FULL_CLIENT_REQUEST (0x1) | NO_SEQUENCE (0x0) -> 0x10
        // Byte 2: JSON (0x1) | NO_COMPRESSION (0x0) -> 0x10
        // Byte 3: Reserved (0x00)
        frame.append(contentsOf: [0x11, 0x10, 0x10, 0x00])

        var lenBE = UInt32(jsonData.count).bigEndian
        frame.append(Data(bytes: &lenBE, count: 4))
        frame.append(jsonData)
        return frame
    }

    private static func buildAudioOnlyFrame(pcmData: Data, isLast: Bool) -> Data {
        var frame = Data()
        // Byte 1: AUDIO_ONLY (0x2) | NEG_SEQUENCE (0x2) if last, else NO_SEQUENCE (0x0)
        let byte1: UInt8 = isLast ? 0x22 : 0x20
        frame.append(contentsOf: [0x11, byte1, 0x00, 0x00])

        var lenBE = UInt32(pcmData.count).bigEndian
        frame.append(Data(bytes: &lenBE, count: 4))
        frame.append(pcmData)
        return frame
    }

    private struct ParsedServerFrame {
        var text: String?
        var isFinal: Bool = false
        var error: (code: UInt32, message: String)?
    }

    private static func parseServerFrame(_ data: Data) -> ParsedServerFrame {
        guard data.count >= 4 else { return ParsedServerFrame() }
        let bytes = [UInt8](data)
        let headerSize = Int(bytes[0] & 0x0F) * 4
        let msgType = (bytes[1] >> 4) & 0x0F
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F

        var offset = headerSize
        guard offset <= bytes.count else { return ParsedServerFrame() }

        // Server Error Frame (0xF)
        if msgType == 0xF {
            guard offset + 8 <= bytes.count else {
                return ParsedServerFrame(error: (0, "未知服务端错误"))
            }
            let code = readUInt32BE(bytes, at: offset)
            let msgLen = Int(readUInt32BE(bytes, at: offset + 4))
            offset += 8
            let end = min(bytes.count, offset + msgLen)
            var payloadData = Data(bytes[offset..<end])
            if compression == 0x1, let unzipped = gunzip(payloadData) {
                payloadData = unzipped
            }
            let msg = String(data: payloadData, encoding: .utf8) ?? "错误码 \(code)"
            return ParsedServerFrame(isFinal: true, error: (code, msg))
        }

        // Full Server Response (0x9)
        guard msgType == 0x9 else { return ParsedServerFrame() }

        var isFinal = false
        if (flags & 0x01) != 0 {
            guard offset + 4 <= bytes.count else { return ParsedServerFrame() }
            let seq = readInt32BE(bytes, at: offset)
            offset += 4
            if flags == 0x03 || seq < 0 {
                isFinal = true
            }
        } else if flags == 0x02 {
            isFinal = true
        }

        guard offset + 4 <= bytes.count else { return ParsedServerFrame(isFinal: isFinal) }
        let payloadLen = Int(readUInt32BE(bytes, at: offset))
        offset += 4

        guard payloadLen > 0, offset < bytes.count else {
            return ParsedServerFrame(isFinal: isFinal)
        }
        let end = min(bytes.count, offset + payloadLen)
        var payloadData = Data(bytes[offset..<end])
        if compression == 0x1, let unzipped = gunzip(payloadData) {
            payloadData = unzipped
        }

        if let decoded = try? JSONDecoder().decode(ServerPayload.self, from: payloadData) {
            if let text = decoded.result?.text, !text.isEmpty {
                return ParsedServerFrame(text: text, isFinal: isFinal)
            }
            if let utterances = decoded.result?.utterances {
                let joined = utterances.compactMap(\.text).joined()
                if !joined.isEmpty {
                    return ParsedServerFrame(text: joined, isFinal: isFinal)
                }
            }
        }
        return ParsedServerFrame(isFinal: isFinal)
    }

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
    }

    private static func readInt32BE(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(bytes, at: offset))
    }

    private static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        var status: Int32 = inflateInit2_(
            &stream,
            16 + MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: data.count * 3)
        let chunkSize = 16384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        let success: Bool = data.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            repeat {
                let outCount = buffer.withUnsafeMutableBytes { outPtr -> Int in
                    guard let outBase = outPtr.bindMemory(to: Bytef.self).baseAddress else { return 0 }
                    stream.next_out = outBase
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if outCount > 0 {
                    output.append(contentsOf: buffer[0..<outCount])
                }
            } while status == Z_OK

            return status == Z_STREAM_END
        }

        return success ? output : nil
    }
}
