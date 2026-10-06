import Foundation

enum ScribeyPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Scribey")
    }()

    static let tmpDirectory: URL = supportDirectory.appendingPathComponent("tmp")

    static let socketPath: String = supportDirectory.appendingPathComponent("scribey.sock").path

    static let daemonLogPath: URL = supportDirectory.appendingPathComponent("daemon.log")
}
