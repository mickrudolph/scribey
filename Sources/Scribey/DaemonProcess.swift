import Foundation

final class DaemonProcess {
    private var process: Process?
    private var hasRespawned = false

    var onExitUnexpectedly: (() -> Void)?

    // Scribey.app is built into the root of the checkout, next to daemon/. If
    // the app has been moved (e.g. to /Applications), fall back to the checkout
    // path install.sh records in the "checkoutPath" default.
    static let daemonDirectory: URL = {
        let besideApp = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("daemon")
        if FileManager.default.fileExists(atPath: besideApp.path) { return besideApp }
        if let checkout = UserDefaults.standard.string(forKey: "checkoutPath") {
            return URL(fileURLWithPath: checkout).appendingPathComponent("daemon")
        }
        return besideApp
    }()

    private var pythonPath: URL {
        Self.daemonDirectory.appendingPathComponent(".venv/bin/python3")
    }

    private var scriptPath: URL {
        Self.daemonDirectory.appendingPathComponent("transcribe_daemon.py")
    }

    func start() {
        try? FileManager.default.createDirectory(at: ScribeyPaths.supportDirectory, withIntermediateDirectories: true)

        guard FileManager.default.isExecutableFile(atPath: pythonPath.path) else {
            print("Scribey: no daemon venv at \(pythonPath.path), run ./install.sh from the checkout")
            return
        }

        let process = Process()
        process.executableURL = pythonPath
        process.arguments = [scriptPath.path]

        // launchd's minimal environment doesn't include Homebrew's bin dirs,
        // where ffmpeg (a hard dependency of parakeet-mlx) lives.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        FileManager.default.createFile(atPath: ScribeyPaths.daemonLogPath.path, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: ScribeyPaths.daemonLogPath.path) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        process.terminationHandler = { [weak self] _ in
            self?.handleUnexpectedExit()
        }

        do {
            try process.run()
            self.process = process
        } catch {
            print("Scribey: failed to launch daemon: \(error)")
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func handleUnexpectedExit() {
        guard !hasRespawned else {
            DispatchQueue.main.async { self.onExitUnexpectedly?() }
            return
        }
        hasRespawned = true
        DispatchQueue.main.async {
            self.onExitUnexpectedly?()
            self.start()
        }
    }
}
