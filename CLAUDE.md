# Scribey

Offline hold-to-dictate for macOS. Hold right-⌥ to record, release to transcribe+paste at cursor; double-tap right-⌥ to lock into continuous recording, tap again to stop.

## Architecture

Swift Package Manager executable (`.app` bundle, no Xcode project) + a long-lived Python daemon:

- **Swift app** (`Sources/Scribey/`) — hotkey capture (`HotkeyManager.swift`), mic recording (`AudioRecorder.swift`), clipboard paste (`PasteboardBridge.swift`), overlay pill UI (`OverlayPanel.swift`/`OverlayView.swift`/`WaveformView.swift`), daemon process management (`DaemonProcess.swift`), socket client (`TranscriptionClient.swift`).
- **Python daemon** (`daemon/transcribe_daemon.py`) — loads NVIDIA's Parakeet TDT v2 model once via `parakeet-mlx` (Apple Silicon MLX, ~2.5GB, `mlx-community/parakeet-tdt-0.6b-v2` from Hugging Face) and stays warm, serving transcription over a Unix socket (`~/Library/Application Support/Scribey/scribey.sock`) with length-prefixed JSON framing. Fully offline, no cloud calls.

`install.sh` moves the built `Scribey.app` to /Applications while `daemon/` stays in the checkout. `DaemonProcess.swift` looks for `daemon/` beside the bundle first, then falls back to the `checkoutPath` default that `install.sh` writes. If neither exists, the app sits in "Starting up…" forever.

## Known gotchas

- **Mic permission** for a bundle app needs both an `.app` bundle with `NSMicrophoneUsageDescription` in `Info.plist` AND a `com.apple.security.device.audio-input` entitlement passed to codesign (Hardened Runtime gates mic access even without App Sandbox).
- **MDM-managed Macs may grant mic permission silently** (a pushed PPPC profile) with no visible prompt. Check `AVCaptureDevice.authorizationStatus` or Privacy & Security → Microphone rather than waiting for a dialog.
- **Ad-hoc signing (the default in `build-release.sh`) means TCC permissions may not survive a rebuild**, because TCC keys ad-hoc apps by code hash. Set `SCRIBEY_SIGNING_IDENTITY` to a real identity to avoid re-granting.
- **`AVAudioConverter`'s input callback can be invoked multiple times per `convert()` call** — must track whether the buffer was already supplied and return `.noDataNow`/nil on subsequent calls, or audio gets duplicated/mangled during resampling. Caused a real "records fine, transcribes garbage" bug once — see the `suppliedInput` flag in `AudioRecorder.swift`.
- **`swift build`'s in-tree `.build/build.db` intermittently throws a spurious "disk I/O error"** under sandboxed shells even on successful builds. `build-release.sh` builds to `/tmp/scribey-build` via `--scratch-path` to avoid this entirely.
- **MLX's GPU buffer cache grows unbounded across varied clip lengths and tanks performance.** MLX pools freed Metal buffers by size, and every new audio length allocates a fresh set that's never reused, so a long-lived daemon accumulates cache forever — measured at 10.7GB after 30 mixed-length clips, and 11GB on a daemon that had been up 6 days. That pushes the machine into swap, and transcription drops from ~0.15–1.0s to 2.5–12.7s for the same clips (a 5–20x regression that gets worse the longer the daemon runs, which is why it feels like it "used to be faster"). Fix: `mx.set_cache_limit(512MB)` at startup plus `mx.clear_cache()` in the `finally` after every transcribe. Steady-state footprint is then ~1.3GB with no slowdown. Don't remove the `clear_cache` — the cache only saves a few ms of allocator work.
- **First transcription after daemon start pays ~1.5s of lazy Metal kernel compilation**, which is the "have to warm it up with a few taps" symptom. `daemon/warmup.wav` (1.5s tone, committed) is transcribed at startup to absorb that cost before the first real dictation.
- **Modifier state must be read from the device-specific right-⌥ bit (`0x40`), not `.maskAlternate`.** `.maskAlternate` is set while *either* option key is down, so holding left-⌥ made a right-⌥ release read as a press. Combined with the old lock-exit that only fired on key-up, that stranded the app in `.locked` forever — recording indefinitely with no way out but quitting (hit once: a 2-minute, 8MB orphaned clip). Lock now exits on the key-**down** edge, with an `awaitingLockReleaseUp` state to swallow the trailing key-up.
- **Always keep an escape hatch out of recording states.** Esc cancels from any recording state (swallowed so it doesn't reach the focused app), and the menu-bar item has "Stop Recording". Any state machine driven by `flagsChanged` can miss an event; without an escape hatch that means force-quitting.
- **A recording stopped immediately after starting yields a header-only WAV.** `AVAudioEngine` needs a moment before it delivers the first buffer, so the file has zero audio frames — this was the source of the `duration=0.0` / empty-transcription log spam. `AudioRecorder.capturedFrameCount` tracks frames actually written and `AppDelegate` discards the clip locally instead of round-tripping it to the daemon.
- **`minMeaningfulPress` (0.45s) is the constant that makes double-tap work — not `doubleTapWindow`.** It was 0.2s, which is *shorter than a real double-tap's first press*, so tap one measured as a completed hold-to-dictate and the gesture got split into two independent single-taps that never locked. Widening `doubleTapWindow` doesn't help, because the code never reaches the window check. Measured on this machine: taps run 0.10–0.15s (first) and 0.08–0.09s (second), a deliberate hold ~1.9s — so 0.45s sits in a wide dead zone between the two gestures. If double-tap regresses, read the `first press held Xs` log line before touching anything else.
- **Press durations are logged on purpose** (`first press held`, `second tap detected`, `second press held`, `LOCKED`). One line per press; this is what turns "the double-tap feels flaky" into a diagnosis in one read of `/tmp/scribey.log`. Don't strip them as debug noise.
- **The daemon serves one connection at a time** (`server.listen(1)` + a blocking inner loop) and the Swift app holds its connection for the app's whole lifetime. Any second client — e.g. a benchmark script — blocks in the backlog until the app disconnects, which looks exactly like a hang. To time the real path, read the `transcribed in Xs` daemon log line rather than opening a competing socket.
- **Custom vocabulary is fuzzy post-processing, not real biasing.** Parakeet (RNNT/TDT) has no prompt- or vocab-biasing hook at decode time, unlike Whisper's `initial_prompt`. `daemon/custom_words.txt` (one word/phrase per line, `#` comments allowed; gitignored, seeded by the daemon from the committed `custom_words.default.txt` if missing) is re-read on every transcription — no daemon restart needed — and `apply_custom_words()` in `transcribe_daemon.py` snaps any output word that's a close spelling match (`difflib.get_close_matches`, cutoff `0.75`) to the exact spelling on the list. Only single alphanumeric tokens are matched, so if Parakeet splits a word into multiple tokens (e.g. hearing "n8n" as "n eight n"), there's no single token close enough to correct — this only rescues near-miss single-word mishearings, not garbled multi-word ones.

## Launch on login

`install.sh` generates a LaunchAgent (`~/Library/LaunchAgents/com.mickrudolph.scribey.plist`) pointing at `/Applications/Scribey.app/Contents/MacOS/Scribey` — starts at login, `KeepAlive` restarts it on crash. Re-running `install.sh` replaces the app and reloads the agent.

## Rebuilding

```
./install.sh   # builds, signs, installs to /Applications, reloads the login agent
```

First-time setup is `./install.sh` (venv + model download, build, LaunchAgent); `./uninstall.sh` reverses it. See `README.md`.
