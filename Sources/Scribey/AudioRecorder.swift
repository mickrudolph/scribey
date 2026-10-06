import AVFoundation
import Foundation

enum AudioRecorder {
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private static var engine: AVAudioEngine?
    private static var file: AVAudioFile?
    private static var converter: AVAudioConverter?
    private static var currentPath: URL?

    private static let stateLock = NSLock()
    private static var framesWritten: AVAudioFramePosition = 0

    /// Frames actually captured for the current/just-finished recording.
    /// `AVAudioEngine` needs a moment to spin up, so a recording stopped very
    /// soon after starting can yield a header-only file. Sending that to the
    /// daemon produced the `duration=0.0` empty transcriptions.
    static var capturedFrameCount: AVAudioFramePosition {
        stateLock.lock()
        defer { stateLock.unlock() }
        return framesWritten
    }

    static func start(onAmplitude: ((Float) -> Void)? = nil) -> URL {
        let supportDir = ScribeyPaths.tmpDirectory
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let path = supportDir.appendingPathComponent("recording-\(UUID().uuidString).wav")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        let file = try! AVAudioFile(forWriting: path, settings: targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            if let onAmplitude {
                let level = rmsAmplitude(of: buffer)
                DispatchQueue.main.async { onAmplitude(level) }
            }

            guard let converter else { return }
            let capacity = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / hardwareFormat.sampleRate) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var suppliedInput = false
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if suppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            try? file.write(from: outBuffer)

            stateLock.lock()
            framesWritten += AVAudioFramePosition(outBuffer.frameLength)
            stateLock.unlock()
        }

        self.engine = engine
        self.file = file
        self.converter = converter
        self.currentPath = path

        stateLock.lock()
        framesWritten = 0
        stateLock.unlock()

        try? engine.start()
        return path
    }

    static func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        converter = nil
        currentPath = nil
    }

    static func discardCurrentRecording() {
        let path = currentPath
        stop()
        if let path {
            try? FileManager.default.removeItem(at: path)
        }
    }

    private static func rmsAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let boosted = min(rms * 20, 1.0)
        // Perceptual curve: pushes quiet-to-moderate speech higher up the
        // visible range instead of clustering near the bottom.
        return pow(boosted, 0.4)
    }
}
