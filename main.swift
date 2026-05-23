// capybara — system-wide mechanical-keyboard sounds for macOS.
// Listens for global key-downs (Accessibility-gated) and plays a random clip
// from capybara_sprite.wav through AVAudioEngine.

import Cocoa
import AVFoundation
import IOKit.hid

// Sprite: 8 clips × 5071 frames (~115 ms @ 44.1 kHz), laid out end-to-end.
private let CLIP_COUNT  = 8
private let CLIP_FRAMES: AVAudioFrameCount = 5071

// Each entry maps a user-facing switch name to its sprite resource (without .wav).
// To add a switch: drop a new <name>_sprite.wav in Resources/ and add a line here.
private let SWITCHES: [(name: String, resource: String)] = [
    ("Capybara",       "capybara_sprite"),
    ("Morandi",        "morandi_sprite"),
    ("Akko Rosewood",  "akko_rosewood_sprite"),
]

// MARK: - Audio

final class Audio {
    private let engine = AVAudioEngine()
    private let mixer  = AVAudioMixerNode()
    private var voices: [(player: AVAudioPlayerNode, speed: AVAudioUnitVarispeed)] = []
    private var clipsByName: [String: [AVAudioPCMBuffer]] = [:]
    private(set) var currentSwitch: String = SWITCHES[0].name

    var volume: Float = 0.6 { didSet { mixer.outputVolume = max(0, min(1.5, volume)) } }

    init() throws {
        // Load every known switch sprite. The first one's format wins — we expect
        // all sprites to be the same sample-rate / channel layout (44.1k mono PCM)
        // since we generate them with one Python script.
        var commonFormat: AVAudioFormat?
        for sw in SWITCHES {
            guard let url = Bundle.main.url(forResource: sw.resource, withExtension: "wav") else {
                continue   // skip silently if a sprite isn't bundled
            }
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            if commonFormat == nil { commonFormat = format }
            let full = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: full)
            var clips: [AVAudioPCMBuffer] = []
            for i in 0..<CLIP_COUNT {
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: CLIP_FRAMES)!
                buf.frameLength = CLIP_FRAMES
                let offset = Int(CLIP_FRAMES) * i
                for ch in 0..<Int(format.channelCount) {
                    let src = full.floatChannelData![ch].advanced(by: offset)
                    memcpy(buf.floatChannelData![ch], src, Int(CLIP_FRAMES) * MemoryLayout<Float>.size)
                }
                clips.append(buf)
            }
            clipsByName[sw.name] = clips
        }
        guard let format = commonFormat, !clipsByName.isEmpty else {
            throw NSError(domain: "capybara", code: 1, userInfo: [NSLocalizedDescriptionKey: "no switch sprites found in bundle"])
        }

        // 8-voice pool. Each voice = player → varispeed (resampling pitch shift) → mixer.
        // Varispeed (not AVAudioUnitTimePitch) preserves the sharp click transient.
        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: format)
        mixer.outputVolume = volume
        for _ in 0..<8 {
            let p = AVAudioPlayerNode()
            let s = AVAudioUnitVarispeed()
            engine.attach(p); engine.attach(s)
            engine.connect(p, to: s, format: format)
            engine.connect(s, to: mixer, format: format)
            voices.append((p, s))
        }
        try engine.start()
        for v in voices { v.player.play() }
    }

    func setSwitch(_ name: String) {
        if clipsByName[name] != nil { currentSwitch = name }
    }

    func play(spaceLike: Bool, pan: Float, detuneCents: Float) {
        guard let clips = clipsByName[currentSwitch] else { return }
        let v = voices.randomElement()!
        let detune = detuneCents + (spaceLike ? -120 : 0) + Float.random(in: -15...15)
        v.speed.rate  = pow(2, detune / 1200)
        v.player.pan  = max(-1, min(1, pan))
        v.player.scheduleBuffer(clips.randomElement()!, at: nil, options: [.interrupts], completionHandler: nil)
    }
}

// MARK: - Key listener (CGEvent tap, listen-only)

final class KeyListener {
    private var tap: CFMachPort?
    private var lastFiredAt: [Int64: CFAbsoluteTime] = [:]
    private let onKey: (Int64) -> Void
    var enabled = true

    init(onKey: @escaping (Int64) -> Void) { self.onKey = onKey }

    @discardableResult
    func start() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let me = Unmanaged.passUnretained(self).toOpaque()
        // .cgSessionEventTap works with just Accessibility on macOS 14+.
        // .cghidEventTap (the earlier-pipeline location) now requires Input Monitoring,
        // which is a separate TCC permission we'd rather not ask for.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                Unmanaged<KeyListener>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard enabled, type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let now  = CFAbsoluteTimeGetCurrent()
        if let prev = lastFiredAt[code], now - prev < 0.02 { return }   // de-dup duplicate deliveries
        lastFiredAt[code] = now
        DispatchQueue.main.async { [onKey] in onKey(code) }
    }
}

// MARK: - Per-key acoustics

// Approximate column (0..15) for each macOS virtual key code, used to derive
// stereo pan + a small pitch offset so left-hand keys sound on the left.
private let keyColumn: [Int64: Double] = [
    // F-row
    53: 0, 122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7,
    100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
    // Numbers
    50: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7,
    28: 8, 25: 9, 29: 10, 27: 11, 24: 12, 51: 13,
    // QWERTY
    48: 0.5, 12: 1.5, 13: 2.5, 14: 3.5, 15: 4.5, 17: 5.5, 16: 6.5,
    32: 7.5, 34: 8.5, 31: 9.5, 35: 10.5, 33: 11.5, 30: 12.5, 42: 13.5,
    // ASDF
    57: 0.75, 0: 1.75, 1: 2.75, 2: 3.75, 3: 4.75, 5: 5.75, 4: 6.75,
    38: 7.75, 40: 8.75, 37: 9.75, 41: 10.75, 39: 11.75, 36: 13,
    // ZXCV
    56: 0.25, 6: 2, 7: 3, 8: 4, 9: 5, 11: 6, 45: 7, 46: 8,
    43: 9, 47: 10, 44: 11, 60: 13,
    // Modifiers / bottom row
    59: 0, 55: 1, 58: 2, 49: 7, 61: 11, 54: 12, 62: 13,
    // Arrows
    123: 12, 125: 13, 124: 14, 126: 13,
]

private let spaceLikeKeys: Set<Int64> = [49, 36, 51, 76, 56, 60, 48]   // space, return, backspace, numpadEnter, shifts, tab

private func acoustics(_ code: Int64) -> (pan: Float, detune: Float, spaceLike: Bool) {
    let col = keyColumn[code] ?? 7
    return (
        pan: Float(max(-1, min(1, (col - 8) / 8))),
        detune: Float((col - 8) * 8),
        spaceLike: spaceLikeKeys.contains(code)
    )
}

// MARK: - Menu bar app

final class App: NSObject, NSApplicationDelegate {
    private var audio: Audio!
    private var listener: KeyListener!
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaults = UserDefaults.standard
    private var enabledItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var inputMonitorItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        // CGEvent.tapCreate on macOS 15+ requires BOTH Accessibility AND Input Monitoring.
        // Prompt for Input Monitoring up front (no-op if already granted).
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        NSApp.setActivationPolicy(.accessory)                       // menu-bar only, no Dock icon
        // Use the bundled switch photo as the menu bar icon. Falls back to a glyph
        // if the resource is missing.
        if let url = Bundle.main.url(forResource: "capylogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            // Scale to ~25pt tall, preserving the source image's aspect ratio so it
            // doesn't squish horizontally.
            let h: CGFloat = 25
            let w = img.size.width > 0 ? h * (img.size.width / img.size.height) : h
            img.size = NSSize(width: w, height: h)
            img.isTemplate = false                                  // it's a color photo, don't tint
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "⌨︎"
        }
        statusItem.button?.toolTip = "capybara — mechanical keyboard sounds"

        do {
            audio = try Audio()
        } catch {
            fatalAlert("Audio engine failed: \(error.localizedDescription)")
            return
        }
        audio.volume       = Float(defaults.object(forKey: "volume") as? Double ?? 0.6)
        let savedEnabled   = defaults.object(forKey: "enabled") as? Bool ?? true
        let savedSwitch    = defaults.object(forKey: "switch") as? String ?? SWITCHES[0].name
        audio.setSwitch(savedSwitch)

        listener = KeyListener { [audio] code in
            let a = acoustics(code)
            audio!.play(spaceLike: a.spaceLike, pan: a.pan, detuneCents: a.detune)
        }
        listener.enabled = savedEnabled

        buildMenu(enabled: savedEnabled, volume: Double(audio.volume))
        applyEnabledVisual(savedEnabled)

        if !listener.start() {
            // Prompts the user — if denied, the menu's permission row tells them what to do.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            // Re-try once a second until the tap installs. Stops automatically on success.
            // Without this, the user grants Accessibility but nothing happens until they
            // restart the app — confusing.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                if self.listener.start() {
                    self.refreshPermissionLabel()
                    t.invalidate()
                }
            }
        }
        refreshPermissionLabel()
    }

    // MARK: Menu

    private func buildMenu(enabled: Bool, volume: Double) {
        let menu = NSMenu()
        menu.delegate = self

        enabledItem = menu.addItem(withTitle: "Sound enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state  = enabled ? .on : .off

        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let label = NSTextField(labelWithString: "Volume")
        label.frame = NSRect(x: 14, y: 5, width: 60, height: 20)
        label.textColor = .secondaryLabelColor
        label.font = NSFont.menuFont(ofSize: 12)
        row.addSubview(label)
        let slider = NSSlider(value: volume, minValue: 0, maxValue: 1.2, target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 78, y: 6, width: 130, height: 20)
        row.addSubview(slider)
        let volItem = NSMenuItem(); volItem.view = row
        menu.addItem(volItem)

        menu.addItem(.separator())

        // Switch picker — one menu item per known switch, checkmark on the active one.
        let switchLabel = menu.addItem(withTitle: "Switch", action: nil, keyEquivalent: "")
        switchLabel.isEnabled = false
        for sw in SWITCHES {
            let item = menu.addItem(withTitle: "  \(sw.name)", action: #selector(selectSwitch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sw.name
            item.state = (sw.name == audio.currentSwitch) ? .on : .off
        }

        menu.addItem(.separator())
        let permsHeader = menu.addItem(withTitle: "Permissions", action: nil, keyEquivalent: "")
        permsHeader.isEnabled = false
        accessibilityItem = menu.addItem(withTitle: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        inputMonitorItem  = menu.addItem(withTitle: "", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMonitorItem.target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit capybara", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectSwitch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        audio.setSwitch(name)
        defaults.set(name, forKey: "switch")
        // Update checkmarks across all switch items.
        if let menu = statusItem.menu {
            for item in menu.items {
                if let n = item.representedObject as? String {
                    item.state = (n == name) ? .on : .off
                }
            }
        }
    }

    @objc private func toggleEnabled() {
        let on = enabledItem.state != .on
        enabledItem.state = on ? .on : .off
        listener.enabled = on
        defaults.set(on, forKey: "enabled")
        applyEnabledVisual(on)
    }

    @objc private func volumeChanged(_ slider: NSSlider) {
        audio.volume = Float(slider.doubleValue)
        defaults.set(slider.doubleValue, forKey: "volume")
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func applyEnabledVisual(_ on: Bool) {
        statusItem.button?.alphaValue = on ? 1.0 : 0.45
    }

    private func refreshPermissionLabel() {
        // Accessibility
        if AXIsProcessTrusted() {
            accessibilityItem.title = "  Accessibility: granted ✓"
            accessibilityItem.action = nil
            accessibilityItem.target = nil
        } else {
            accessibilityItem.title = "  Grant Accessibility access…"
            accessibilityItem.action = #selector(openAccessibilitySettings)
            accessibilityItem.target = self
        }
        // Input Monitoring — IOHIDCheckAccess doesn't prompt, just reports state.
        let imGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if imGranted {
            inputMonitorItem.title = "  Input Monitoring: granted ✓"
            inputMonitorItem.action = nil
            inputMonitorItem.target = nil
        } else {
            inputMonitorItem.title = "  Grant Input Monitoring access…"
            inputMonitorItem.action = #selector(openInputMonitoringSettings)
            inputMonitorItem.target = self
        }
    }

    private func fatalAlert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "capybara"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "Quit")
        a.runModal()
        NSApp.terminate(nil)
    }
}

// Refresh the permission label whenever the user opens the menu — no polling needed.
extension App: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refreshPermissionLabel() }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
