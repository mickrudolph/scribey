import AppKit

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

// Writing to a socket after the daemon closes its end raises SIGPIPE, whose
// default action silently kills the whole process. TranscriptionClient uses
// raw send()/recv(), so this must be ignored globally.
signal(SIGPIPE, SIG_IGN)

// A second copy (e.g. opened from Finder while the LaunchAgent's is running)
// would fight over the hotkey and the daemon socket, so it just exits.
let bundleID = Bundle.main.bundleIdentifier ?? "com.mickrudolph.scribey"
let pid = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != pid }) {
    print("Scribey: already running, exiting this copy")
    exit(0)
}

// pkill and launchctl unload send SIGTERM, which skips applicationWillTerminate
// and orphans the daemon (~1.3GB). Route it through a normal quit instead.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { NSApplication.shared.terminate(nil) }
termSource.resume()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
