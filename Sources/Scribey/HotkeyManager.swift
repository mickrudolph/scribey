import AppKit

enum HotkeyTiming {
    /// Longest press still counted as a "tap" rather than a hold-to-dictate.
    ///
    /// This was 0.2s, which is faster than an actual human double-tap: the
    /// first tap measured as a deliberate hold, so the gesture was split into
    /// two independent single-taps and never locked. Real taps here measure
    /// ~0.1-0.35s, so allow up to 0.45s. A hold-to-dictate press is always far
    /// longer than that in practice, so nothing meaningful is misread.
    static let minMeaningfulPress: TimeInterval = 0.45
    /// Gap allowed between the two taps of a double-tap.
    static let doubleTapWindow: TimeInterval = 0.6
}

final class HotkeyManager {
    private enum State {
        case idle
        case firstPressHeld(start: Date)
        case awaitingSecondTap
        case secondPressHeld(start: Date)
        case locked
        /// Lock was released on key-down; swallow the key-up that follows so it
        /// doesn't immediately start a new recording.
        case awaitingLockReleaseUp
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var state: State = .idle
    private var doubleTapTimer: Timer?
    private var tapRetryTimer: Timer?

    var onRecordStart: (() -> Void)?
    var onRecordStop: ((_ shouldTranscribe: Bool) -> Void)?
    var onLockEngaged: (() -> Void)?
    var onCancel: (() -> Void)?

    private let rightOptionKeyCode: Int64 = 0x3D
    private let escapeKeyCode: Int64 = 0x35

    /// Device-dependent modifier bit for the RIGHT option key
    /// (`NX_DEVICERALTKEYMASK`). The generic `.maskAlternate` flag is set when
    /// EITHER option key is down, so using it means a held left-⌥ makes a
    /// right-⌥ release look like a press — which used to strand the lock state
    /// permanently. This bit tracks the physical key we actually care about.
    private let rightOptionFlagBit: UInt64 = 0x40

    var isRecording: Bool {
        switch state {
        case .idle, .awaitingLockReleaseUp: return false
        case .firstPressHeld, .awaitingSecondTap, .secondPressHeld, .locked: return true
        }
    }

    /// Without Accessibility permission the tap can't be created. Keep retrying
    /// so granting it takes effect right away instead of needing a relaunch;
    /// with ad-hoc signing that happens after every rebuild.
    func start() {
        guard !installTap() else { return }
        print("Scribey: no Accessibility permission yet, hotkey will start once it's granted in System Settings")
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.installTap() else { return }
            timer.invalidate()
            self.tapRetryTimer = nil
            print("Scribey: Accessibility granted, hotkey active")
        }
    }

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Esc is an unconditional escape hatch out of any recording state, so a
        // missed modifier event can never strand the overlay again.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == escapeKeyCode {
            if isRecording {
                cancelFromEscape()
                return nil // swallow the Esc so it doesn't also hit the focused app
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == rightOptionKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Read the right-option bit specifically rather than `.maskAlternate`.
        let isKeyDown = (event.flags.rawValue & rightOptionFlagBit) != 0
        let now = Date()

        switch state {
        case .idle:
            guard isKeyDown else { break }
            state = .firstPressHeld(start: now)
            dispatchRecordStart()

        case .firstPressHeld(let start):
            guard !isKeyDown else { break }
            let heldDuration = now.timeIntervalSince(start)
            print(String(format: "Scribey: first press held %.3fs (tap threshold %.2fs)",
                         heldDuration, HotkeyTiming.minMeaningfulPress))
            if heldDuration >= HotkeyTiming.minMeaningfulPress {
                state = .idle
                dispatchRecordStop(shouldTranscribe: true)
            } else {
                state = .awaitingSecondTap
                scheduleDoubleTapTimeout()
            }

        case .awaitingSecondTap:
            guard isKeyDown else { break }
            print("Scribey: second tap detected, awaiting release to lock")
            doubleTapTimer?.invalidate()
            doubleTapTimer = nil
            state = .secondPressHeld(start: now)

        case .secondPressHeld(let start):
            guard !isKeyDown else { break }
            let heldDuration = now.timeIntervalSince(start)
            print(String(format: "Scribey: second press held %.3fs", heldDuration))
            if heldDuration < HotkeyTiming.minMeaningfulPress {
                state = .locked
                dispatchLockEngaged()
            } else {
                state = .idle
                dispatchRecordStop(shouldTranscribe: true)
            }

        case .locked:
            // Stop on the key-DOWN edge. Waiting for key-up here meant a single
            // dropped or flag-desynced release event left us locked forever.
            guard isKeyDown else { break }
            state = .awaitingLockReleaseUp
            dispatchRecordStop(shouldTranscribe: true)

        case .awaitingLockReleaseUp:
            guard !isKeyDown else { break }
            state = .idle
        }

        return Unmanaged.passUnretained(event)
    }

    /// Force everything back to idle, discarding whatever was being recorded.
    func forceCancel() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        state = .idle
        dispatchRecordStop(shouldTranscribe: false)
    }

    private func cancelFromEscape() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        state = .idle
        DispatchQueue.main.async { self.onCancel?() }
    }

    private func scheduleDoubleTapTimeout() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = Timer.scheduledTimer(withTimeInterval: HotkeyTiming.doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self, case .awaitingSecondTap = self.state else { return }
            self.state = .idle
            self.doubleTapTimer = nil
            self.dispatchRecordStop(shouldTranscribe: false)
        }
    }

    private func dispatchRecordStart() {
        DispatchQueue.main.async { self.onRecordStart?() }
    }

    private func dispatchRecordStop(shouldTranscribe: Bool) {
        DispatchQueue.main.async { self.onRecordStop?(shouldTranscribe) }
    }

    private func dispatchLockEngaged() {
        DispatchQueue.main.async { self.onLockEngaged?() }
    }
}
