@preconcurrency import AVFoundation
import Foundation
import Speech

/// Deterministic, phase-continuous pure-Swift downsampler:
/// mixes any channel layout (1ch/2ch/4ch Mac mic array) to mono and resamples cleanly to 16kHz 16-bit LE PCM.
private final class LinearPCM16kResampler: @unchecked Sendable {
    private let inputRate: Double
    private let outputRate: Double = 16000.0
    private let step: Double
    private var phase: Double = 0.0
    private var lastSample: Float = 0.0
    private var hasLastSample: Bool = false

    init(inputSampleRate: Double) {
        self.inputRate = max(8000.0, inputSampleRate)
        self.step = self.inputRate / 16000.0
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return Data() }

        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)

        if let floatData = buffer.floatChannelData {
            if buffer.format.isInterleaved && channelCount > 1 {
                let ptr = floatData[0]
                let invCh = 1.0 / Float(channelCount)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += ptr[i * channelCount + c]
                    }
                    mono[i] = sum * invCh
                }
            } else {
                let invCh = 1.0 / Float(max(1, channelCount))
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channelCount {
                        sum += floatData[c][i]
                    }
                    mono[i] = sum * invCh
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            let ptr = int16Data[0]
            for i in 0..<frameCount {
                mono[i] = Float(ptr[i]) / 32768.0
            }
        } else {
            return Data()
        }

        // Linear interpolation resampling to 16kHz signed Int16 LE
        var outSamples: [Int16] = []
        outSamples.reserveCapacity(Int(Double(frameCount) / step) + 4)

        var pos = phase
        while pos < Double(frameCount) {
            let idx = Int(floor(pos))
            let frac = Float(pos - Double(idx))

            let s0: Float
            if idx < 0 {
                s0 = hasLastSample ? lastSample : mono[0]
            } else {
                s0 = mono[min(idx, frameCount - 1)]
            }
            let s1 = mono[min(idx + 1, frameCount - 1)]
            let interp = s0 + (s1 - s0) * frac
            let clamped = max(-1.0, min(1.0, interp))
            outSamples.append(Int16(clamped * 32767.0).littleEndian)
            pos += step
        }

        phase = pos - Double(frameCount)
        lastSample = mono[frameCount - 1]
        hasLastSample = true

        return outSamples.withUnsafeBytes { Data($0) }
    }
}

/// Thread-safe PCM accumulator for chunking 16kHz 16-bit mono audio into ~160ms packets (5120 bytes).
private final class PCMChunkAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let chunkBytes: Int

    init(chunkBytes: Int = 5120) {
        self.chunkBytes = chunkBytes
    }

    func append(_ data: Data) -> [Data] {
        lock.withLock {
            buffer.append(data)
            var chunks: [Data] = []
            while buffer.count >= chunkBytes {
                chunks.append(buffer.prefix(chunkBytes))
                buffer.removeFirst(chunkBytes)
            }
            return chunks
        }
    }

    func flushRemaining() -> Data {
        lock.withLock {
            let rem = buffer
            buffer.removeAll()
            return rem
        }
    }
}

@MainActor
final class SpeechService: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var liveTranscript: String = ""
    @Published var audioLevels: [CGFloat] = Array(repeating: 0.12, count: 14)
    @Published var permissionError: String?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()

    // macOS Speech mode state (preserves earlier utterances if SFSpeechRecognizer resets after a pause)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var committedMacOSSegments: [String] = []
    private var currentMacOSSegment: String = ""

    // Doubao ASR mode state
    private var activeEngine: SpeechEngineType = .macOS
    private var doubaoClient: DoubaoASRClient?
    private var pcmAccumulator: PCMChunkAccumulator?

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    func startRecording(settings: AppSettings) async -> Bool {
        permissionError = nil
        liveTranscript = ""
        committedMacOSSegments = []
        currentMacOSSegment = ""
        audioLevels = Array(repeating: 0.12, count: 14)

        let micOK = await requestMicrophonePermission()
        guard micOK else {
            permissionError = "未获得麦克风权限，请在「系统设置 → 隐私与安全性 → 麦克风」中允许 ReceiptTodo。"
            return false
        }

        activeEngine = settings.speechEngine
        switch settings.speechEngine {
        case .doubao:
            return await startDoubaoRecording(settings: settings)
        case .macOS:
            return await startMacOSRecording(preferOnDevice: settings.preferOnDeviceSpeech)
        }
    }

    // MARK: - Doubao Streaming ASR Mode

    private func startDoubaoRecording(settings: AppSettings) async -> Bool {
        guard settings.hasDoubaoAPIKey else {
            permissionError = "已选择「豆包语音」，请先在设置中填入你的豆包语音 API Key。"
            return false
        }

        cleanupAudioSession()

        let client = DoubaoASRClient()
        do {
            try await client.connect(
                settings: settings,
                onTranscript: { [weak self] text, _ in
                    Task { @MainActor [weak self] in
                        guard let self, !text.isEmpty else { return }
                        self.liveTranscript = text
                    }
                },
                onError: { [weak self] errMsg in
                    Task { @MainActor [weak self] in
                        self?.permissionError = errMsg
                    }
                }
            )
        } catch {
            permissionError = error.localizedDescription
            return false
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            client.disconnect()
            permissionError = "无法读取默认麦克风输入格式，请检查音频输入设备。"
            return false
        }

        let resampler = LinearPCM16kResampler(inputSampleRate: inputFormat.sampleRate)
        let accumulator = PCMChunkAccumulator(chunkBytes: 5120)
        self.doubaoClient = client
        self.pcmAccumulator = accumulator

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.computeNormalizedPower(from: buffer)
            Task { @MainActor [weak self] in
                self?.pushAudioLevel(level)
            }

            let pcmData = resampler.process(buffer)
            if !pcmData.isEmpty {
                let chunks = accumulator.append(pcmData)
                for chunk in chunks {
                    client.sendPCMChunk(chunk)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cleanupAudioSession()
            permissionError = "启动录音失败：\(error.localizedDescription)"
            return false
        }

        isRecording = true
        return true
    }

    // MARK: - macOS Native Speech Mode

    private func startMacOSRecording(preferOnDevice: Bool) async -> Bool {
        let speechOK = await requestSpeechPermission()
        guard speechOK else {
            permissionError = "未获得语音识别权限，请在「系统设置 → 隐私与安全性 → 语音识别」中允许 ReceiptTodo。"
            return false
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            permissionError = "中文语音识别服务当前不可用，请检查系统语音识别设置或切换为豆包语音。"
            return false
        }

        cleanupAudioSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            permissionError = "无法读取默认麦克风输入格式，请检查音频输入设备。"
            return false
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.computeNormalizedPower(from: buffer)
            Task { @MainActor [weak self] in
                self?.pushAudioLevel(level)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cleanupAudioSession()
            permissionError = "启动录音失败：\(error.localizedDescription)"
            return false
        }

        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        // Guard against Apple SFSpeechRecognizer resetting formattedString mid-monologue after pauses
                        if !self.currentMacOSSegment.isEmpty
                            && text.count + 4 < self.currentMacOSSegment.count
                            && !self.currentMacOSSegment.hasPrefix(text) {
                            self.committedMacOSSegments.append(self.currentMacOSSegment)
                        }
                        self.currentMacOSSegment = text
                        let combined = (self.committedMacOSSegments + [self.currentMacOSSegment]).joined(separator: "，")
                        self.liveTranscript = combined
                    }
                }
                if let error, self.isRecording {
                    let nsErr = error as NSError
                    if nsErr.code != 216 && nsErr.code != 301 {
                        self.permissionError = "语音识别中断：\(error.localizedDescription)"
                    }
                }
            }
        }

        return true
    }

    // MARK: - Stop / Cancel

    func stopRecordingAndCollectTranscript() async -> String {
        guard isRecording else { return liveTranscript }
        isRecording = false

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        var finalTranscript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if activeEngine == .doubao {
            let remaining = pcmAccumulator?.flushRemaining() ?? Data()
            if let client = doubaoClient {
                let serverFinal = await client.finishAndCollectFinal(remainingPCM: remaining)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !serverFinal.isEmpty {
                    finalTranscript = serverFinal
                    liveTranscript = serverFinal
                }
            }
        } else {
            recognitionRequest?.endAudio()
            try? await Task.sleep(nanoseconds: 450_000_000)
            let updated = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !updated.isEmpty {
                finalTranscript = updated
            }
        }

        cleanupAudioSession()
        return finalTranscript
    }

    func cancelRecording() {
        isRecording = false
        liveTranscript = ""
        committedMacOSSegments = []
        currentMacOSSegment = ""
        cleanupAudioSession()
    }

    private func cleanupAudioSession() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        doubaoClient?.disconnect()
        doubaoClient = nil
        pcmAccumulator = nil

        audioLevels = Array(repeating: 0.12, count: 14)
    }

    private func pushAudioLevel(_ level: CGFloat) {
        guard isRecording else { return }
        audioLevels.removeFirst()
        audioLevels.append(max(0.10, min(1.0, level)))
    }

    private nonisolated static func computeNormalizedPower(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.12 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.12 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 0.0001))
        let normalized = (db + 52) / 42
        return CGFloat(max(0.10, min(1.0, normalized)))
    }
}
