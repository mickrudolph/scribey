import AppKit

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

// Writing to a socket after the daemon closes its end raises SIGPIPE, whose
// default action silently kills the whole process. TranscriptionClient uses
// raw send()/recv(), so this must be ignored globally.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
