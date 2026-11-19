// sonos-stereo: turn the two Bluetooth Sonos speakers on the desk into a stereo pair.
//
// Sonos can't stereo pair over Bluetooth, so this does it on the Mac instead. It builds a
// CoreAudio aggregate device out of the two speakers, sends the left channel to the
// "Left" speaker and the right channel to the "Right" speaker, keeps them in sync, and
// makes it the Mac's sound output.
//
// Usage:
//   sonos-stereo on [--swap] [--bt-clock]   create the pair and switch output to it
//   sonos-stereo off           remove the pair and pause auto-pairing (until the next "on")
//   sonos-stereo status        show the speakers, the pair and the background helper
//   sonos-stereo vol <0-100>   set volume on both speakers
//   sonos-stereo test          play a tone on the left, then on the right
//   sonos-stereo calibrate     measure the time gap between the speakers with the Mac's
//                              microphone and save a per-speaker delay that lines them up
//   sonos-stereo install       start the background helper now and at every login
//   sonos-stereo uninstall     stop and remove the background helper
//   sonos-stereo daemon        run the helper in this terminal (what install runs)
//
// The background helper:
//   - makes the keyboard volume keys (and mute) work while the pair is the sound output
//   - when either speaker connects over Bluetooth, connects the other one and pairs them
//
// Speakers are found by name: anything containing "Left (SONOS" / "Right (SONOS".
// Override with env vars SONOS_LEFT / SONOS_RIGHT (part of the device name).

import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Foundation
import IOBluetooth

let pairName = "Sonos Stereo"
let pairUID = "local.sonos-stereo.aggregate"
let agentLabel = "local.sonos-stereo"
let leftMatch = ProcessInfo.processInfo.environment["SONOS_LEFT"] ?? "Left (SONOS"
let rightMatch = ProcessInfo.processInfo.environment["SONOS_RIGHT"] ?? "Right (SONOS"

let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/sonos-stereo")
let settingsURL = supportDir.appendingPathComponent("settings.json")
let installedBinary = supportDir.appendingPathComponent("sonos-stereo")
let agentPlist = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let logURL = home.appendingPathComponent("Library/Logs/sonos-stereo.log")

// MARK: - Settings (shared by the commands and the background helper)

struct Settings: Codable {
    var swap = false
    var btClock = false
    var paused = false
    /// Extra output latency (in frames) given to each speaker inside the pair, set by
    /// "calibrate" to line the two Bluetooth speakers up in time.
    var extraLeftFrames = 0
    var extraRightFrames = 0
    /// Wired mode: the exact output devices (CoreAudio UIDs) to use as Left and Right,
    /// set with "sonos-stereo assign". When unset, speakers are found by Bluetooth name.
    var leftUID: String? = nil
    var rightUID: String? = nil

    var wired: Bool { leftUID != nil && rightUID != nil }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        swap = try c.decodeIfPresent(Bool.self, forKey: .swap) ?? false
        btClock = try c.decodeIfPresent(Bool.self, forKey: .btClock) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        extraLeftFrames = try c.decodeIfPresent(Int.self, forKey: .extraLeftFrames) ?? 0
        extraRightFrames = try c.decodeIfPresent(Int.self, forKey: .extraRightFrames) ?? 0
        leftUID = try c.decodeIfPresent(String.self, forKey: .leftUID)
        rightUID = try c.decodeIfPresent(String.self, forKey: .rightUID)
    }
}

func loadSettings() -> Settings {
    guard let d = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
    return s
}

func saveSettings(_ s: Settings) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? JSONEncoder().encode(s).write(to: settingsURL)
}

// MARK: - CoreAudio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(f.string(from: Date()))] \(msg)")
}

func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids)
    return ids
}

func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func name(_ id: AudioObjectID) -> String { stringProp(id, kAudioObjectPropertyName) ?? "?" }
func uid(_ id: AudioObjectID) -> String? { stringProp(id, kAudioDevicePropertyDeviceUID) }

func outputChannels(_ id: AudioDeviceID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func device(withUID u: String) -> AudioDeviceID? {
    allDevices().first { uid($0) == u }
}

func findSpeaker(_ match: String) -> AudioDeviceID? {
    allDevices().first { name($0).localizedCaseInsensitiveContains(match) && outputChannels($0) > 0 && uid($0) != pairUID }
}

/// The Left/Right output: the assigned device in wired mode, else found by Bluetooth name.
func speaker(isLeft: Bool) -> AudioDeviceID? {
    let s = loadSettings()
    if let u = isLeft ? s.leftUID : s.rightUID {
        return device(withUID: u).flatMap { outputChannels($0) > 0 ? $0 : nil }
    }
    return findSpeaker(isLeft ? leftMatch : rightMatch)
}
func leftSpeaker() -> AudioDeviceID? { speaker(isLeft: true) }
func rightSpeaker() -> AudioDeviceID? { speaker(isLeft: false) }

func transportType(_ id: AudioDeviceID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
    return t
}

func transportLabel(_ id: AudioDeviceID) -> String {
    switch transportType(id) {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    default: return "other"
    }
}

func defaultOutput() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id)
    return id
}

@discardableResult
func setDefaultOutput(_ id: AudioDeviceID) -> OSStatus {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var v = id
    return AudioObjectSetPropertyData(systemObject, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
}

func pairIsOutput() -> Bool { uid(defaultOutput()) == pairUID }

func activeSubDevices(_ agg: AudioDeviceID) -> [AudioObjectID] {
    var a = addr(kAudioAggregateDevicePropertyActiveSubDeviceList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(agg, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &ids)
    return ids
}

func stereoChannels(_ id: AudioDeviceID) -> [UInt32] {
    var a = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
    var ch: [UInt32] = [0, 0]
    var size = UInt32(MemoryLayout<UInt32>.size * 2)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ch)
    return ch
}

func setStereoChannels(_ id: AudioDeviceID, _ l: UInt32, _ r: UInt32) -> OSStatus {
    var a = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
    var ch: [UInt32] = [l, r]
    return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size * 2), &ch)
}

func isSettable(_ id: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> Bool {
    var settable: DarwinBoolean = false
    return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
}

/// Volume 0...1 on a speaker. Tries the main element, then channels 1 and 2.
@discardableResult
func setVolume(_ id: AudioDeviceID, _ v: Float32) -> Bool {
    var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    var val = max(0, min(1, v))
    if isSettable(id, &a) {
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val) == noErr
    }
    var ok = false
    for ch: UInt32 in [1, 2] {
        var c = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
        if isSettable(id, &c), AudioObjectSetPropertyData(id, &c, 0, nil, UInt32(MemoryLayout<Float32>.size), &val) == noErr { ok = true }
    }
    return ok
}

func getVolume(_ id: AudioDeviceID) -> Float32? {
    for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
        guard AudioObjectHasProperty(id, &a) else { continue }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr { return v }
    }
    return nil
}

/// Hardware mute, if the speaker has one. Returns false if it doesn't.
func setMute(_ id: AudioDeviceID, _ on: Bool) -> Bool {
    var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
    guard isSettable(id, &a) else { return false }
    var v: UInt32 = on ? 1 : 0
    return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
}

/// Let CoreAudio publish property changes (needed right after creating a device).
func settle(_ seconds: Double = 0.3) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// The Mac's built-in speakers. Used only as a steady clock for the pair; they get no audio.
func builtInOutput() -> AudioDeviceID? {
    allDevices().first { id in
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t == kAudioDeviceTransportTypeBuiltIn && outputChannels(id) > 0
    }
}

// MARK: - Building and removing the pair

struct PairError: Error { let message: String }

@discardableResult
func destroyPair() -> Bool {
    guard let id = device(withUID: pairUID) else { return false }
    AudioHardwareDestroyAggregateDevice(id)
    settle()
    return true
}

/// A pair is healthy when it exists and both speakers are active inside it.
func pairIsHealthy() -> Bool {
    guard let agg = device(withUID: pairUID), let l = leftSpeaker(), let r = rightSpeaker() else { return false }
    let subs = activeSubDevices(agg)
    return subs.contains(l) && subs.contains(r)
}

/// Builds the pair and makes it the sound output. Returns a summary.
func buildPair(_ s: Settings) throws -> String {
    guard let l = leftSpeaker() else { throw PairError(message: "no output device matching \"\(leftMatch)\". Is the Left speaker connected over Bluetooth?") }
    guard let r = rightSpeaker() else { throw PairError(message: "no output device matching \"\(rightMatch)\". Is the Right speaker connected over Bluetooth?") }
    guard let lUID = uid(l), let rUID = uid(r) else { throw PairError(message: "couldn't read speaker IDs") }
    destroyPair()

    // Bluetooth speakers make a poor clock: audio arrives in bursts, so a pair clocked
    // from one of them stutters. By default the pair is clocked from the Mac's built-in
    // speakers (which stay silent) and BOTH Sonos speakers are drift corrected against it.
    // btClock uses the old setup: Left is the clock, only Right is drift corrected.
    // If one side is a built-in output (the Mac's headphone jack), it already runs on the
    // Mac's own clock, so it becomes the clock and no separate clock device is added.
    let builtInSide = [l, r].first { transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    let clock = (s.btClock || builtInSide != nil) ? nil : builtInOutput()

    // Run the clock at the speakers' rate (Bluetooth is usually 44.1 kHz) so nothing
    // has to be resampled on the fly.
    if let c = clock {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(l, &a, 0, nil, &size, &rate) == noErr, rate > 0 {
            AudioObjectSetPropertyData(c, &a, 0, nil, size, &rate)
            settle()
        }
    }
    let clockUID = clock.flatMap(uid)
    let drift: [String: Any] = [kAudioSubDeviceDriftCompensationKey: 1,
                                kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality]
    var subs: [[String: Any]] = []
    if let c = clockUID { subs.append([kAudioSubDeviceUIDKey: c, kAudioSubDeviceDriftCompensationKey: 0]) }
    // Main (clock) side: the separate clock device if any, else the built-in side, else Left.
    let mainUID = clockUID ?? builtInSide.flatMap(uid) ?? lUID
    let noDrift: [String: Any] = [kAudioSubDeviceDriftCompensationKey: 0]
    var lSub = [kAudioSubDeviceUIDKey: lUID].merging(lUID == mainUID ? noDrift : drift) { $1 }
    var rSub = [kAudioSubDeviceUIDKey: rUID].merging(rUID == mainUID ? noDrift : drift) { $1 }
    // Per-speaker timing offset from "calibrate".
    if s.extraLeftFrames > 0 { lSub[kAudioSubDeviceExtraOutputLatencyKey] = s.extraLeftFrames }
    if s.extraRightFrames > 0 { rSub[kAudioSubDeviceExtraOutputLatencyKey] = s.extraRightFrames }
    subs.append(lSub)
    subs.append(rSub)

    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: pairName,
        kAudioAggregateDeviceUIDKey: pairUID,
        kAudioAggregateDeviceSubDeviceListKey: subs,
        kAudioAggregateDeviceMainSubDeviceKey: mainUID,
        kAudioAggregateDeviceClockDeviceKey: mainUID,
        kAudioAggregateDeviceIsPrivateKey: 0,
        kAudioAggregateDeviceIsStackedKey: 0,
    ]
    var agg = AudioObjectID(0)
    let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
    if err != noErr { throw PairError(message: "couldn't create the pair (OSStatus \(err))") }

    // Wait until every sub-device shows up inside the pair.
    let cCh = clock.map(outputChannels) ?? 0
    let lCh = outputChannels(l)
    let expected = cCh + lCh + outputChannels(r)
    var total = 0
    for _ in 0..<30 {
        settle(0.2)
        total = outputChannels(agg)
        if total == expected { break }
    }
    if total != expected { throw PairError(message: "pair has \(total) channels, expected \(expected). Run it again, or try --bt-clock") }

    // Channels in the pair: clock device first (if any), then Left, then Right.
    // Send the left signal to the Left speaker's first channel and the right signal to the
    // Right speaker's last channel. Each speaker then only plays its own side.
    var leftCh = UInt32(cCh + 1)
    var rightCh = UInt32(total)
    if s.swap { leftCh = UInt32(cCh + lCh + 1); rightCh = UInt32(cCh + lCh) }
    let e = setStereoChannels(agg, leftCh, rightCh)
    if e != noErr { throw PairError(message: "couldn't set the left/right channels (OSStatus \(e))") }
    settle()

    // Start both speakers at the same volume so the stereo image is centered.
    if let v = getVolume(l) { setVolume(r, v) }

    let o = setDefaultOutput(agg)
    if o != noErr { throw PairError(message: "couldn't switch sound output (OSStatus \(o))") }
    settle()

    let ch = stereoChannels(agg)
    return """
    Stereo pair on: "\(pairName)" is now the sound output.
      left  -> \(s.swap ? name(r) : name(l))
      right -> \(s.swap ? name(l) : name(r))
      channels \(ch[0]) and \(ch[1]) of \(total), clock: \(clock.map(name) ?? builtInSide.map(name) ?? name(l))
    """
}

// MARK: - Bluetooth (connecting the other speaker)

func bluetoothDevice(_ match: String) -> IOBluetoothDevice? {
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return paired.first { ($0.name ?? "").localizedCaseInsensitiveContains(match) }
}

// MARK: - Volume keys

let volumeQueue = DispatchQueue(label: "sonos-stereo.volume")
var savedVolume: Float32? = nil   // set while muted with the volume-0 fallback
var hardwareMuted = false
var eventTap: CFMachPort? = nil

/// Called on volumeQueue for each volume key press while the pair is the sound output.
func handleVolumeKey(_ code: Int, fine: Bool) {
    guard let l = leftSpeaker(), let r = rightSpeaker() else { return }
    let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16

    func unmute() -> Float32? {
        if hardwareMuted { _ = setMute(l, false); _ = setMute(r, false); hardwareMuted = false }
        if let v = savedVolume { savedVolume = nil; return v }
        return nil
    }

    switch code {
    case 7: // mute
        if hardwareMuted || savedVolume != nil {
            if let v = unmute() { setVolume(l, v); setVolume(r, v) }
            log("unmuted")
        } else if setMute(l, true) && setMute(r, true) {
            hardwareMuted = true
            log("muted")
        } else {
            savedVolume = getVolume(l) ?? 0.5
            setVolume(l, 0); setVolume(r, 0)
            log("muted (volume 0)")
        }
    case 0, 1: // up, down
        let cur = unmute() ?? getVolume(l) ?? 0.5
        var v = cur + (code == 0 ? step : -step)
        v = (v / step).rounded() * step
        v = max(0, min(1, v))
        setVolume(l, v); setVolume(r, v)
        log("volume \(Int((v * 100).rounded()))%")
    default: break
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // Media keys arrive as NSSystemDefined (14) events with subtype 8.
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let code = (ns.data1 & 0xFFFF0000) >> 16
    let keyDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
    // 0 = volume up, 1 = volume down, 7 = mute. Leave everything else alone, and leave
    // the keys alone too when the pair isn't the sound output (macOS handles those).
    guard [0, 1, 7].contains(code), pairIsOutput() else { return Unmanaged.passUnretained(event) }
    if keyDown {
        let fine = ns.modifierFlags.contains([.option, .shift])
        volumeQueue.async { handleVolumeKey(code, fine: fine) }
    }
    return nil // swallow it, so macOS doesn't show "can't change volume"
}

func installEventTap() -> Bool {
    guard eventTap == nil else { return true }
    let mask = CGEventMask(1 << 14)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - Background helper

final class Helper {
    var pending = false
    var lastSeen = ""                         // which speakers were connected last time
    var connectAttempts = 0
    var lastAttempt = Date.distantPast
    var connecting = false
    var warnedAccessibility = false

    func start() {
        setlinebuf(stdout)
        log("helper started")

        var a = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, DispatchQueue.main) { [weak self] _, _ in self?.schedule() }

        // Ask for Accessibility once (shows the system prompt), then keep checking.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        setupTap()

        // Touch Bluetooth once off the main thread, so macOS asks for Bluetooth access now
        // (during setup) instead of the first time a speaker needs connecting.
        DispatchQueue.global().async {
            let found = ["Left": bluetoothDevice(leftMatch), "Right": bluetoothDevice(rightMatch)]
            let names = found.compactMap { $0.value?.name }.sorted()
            DispatchQueue.main.async { log("bluetooth: found paired \(names.isEmpty ? "nothing" : names.joined(separator: ", "))") }
        }

        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.setupTap()
            self?.schedule()
        }
        schedule()
        RunLoop.main.run()
    }

    func setupTap() {
        if eventTap != nil { return }
        if installEventTap() {
            log("volume keys: active")
        } else if !warnedAccessibility {
            warnedAccessibility = true
            log("volume keys: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > sonos-stereo)")
        }
    }

    /// Debounce: device lists change in bursts while Bluetooth connects.
    func schedule() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.pending = false
            self?.reconcile()
        }
    }

    func reconcile() {
        let s = loadSettings()
        if s.paused { return }
        let l = leftSpeaker(), r = rightSpeaker()
        let seen = "\(l != nil)\(r != nil)"
        if seen != lastSeen { lastSeen = seen; connectAttempts = 0 }

        switch (l, r) {
        case (.some, .some):
            if !pairIsHealthy() {
                do { log(try buildPair(s).replacingOccurrences(of: "\n", with: " |")) }
                catch let e as PairError { log("couldn't pair: \(e.message)") }
                catch { log("couldn't pair: \(error)") }
            }
        case (.some(let have), nil), (nil, .some(let have)):
            // One speaker is here. A pair with a missing speaker is broken, so remove it
            // and let macOS fall back to the speaker that's connected.
            if device(withUID: pairUID) != nil { destroyPair(); log("removed broken pair") }
            // Wired outputs come back when plugged in; only Bluetooth needs connecting.
            if !s.wired { connectOther(missing: l == nil ? leftMatch : rightMatch, have: name(have)) }
        case (nil, nil):
            if device(withUID: pairUID) != nil { destroyPair(); log("both speakers gone, removed pair") }
        }
    }

    /// Connect the missing speaker over Bluetooth. Gives up after 4 tries until something changes.
    func connectOther(missing: String, have: String) {
        guard !connecting, connectAttempts < 4, Date().timeIntervalSince(lastAttempt) > 20 else { return }
        connecting = true
        connectAttempts += 1
        lastAttempt = Date()
        let attempt = connectAttempts
        // All Bluetooth work happens off the main thread so the volume keys never wait on it.
        DispatchQueue.global().async { [weak self] in
            guard let dev = bluetoothDevice(missing) else {
                DispatchQueue.main.async {
                    self?.connecting = false
                    self?.connectAttempts = 4
                    log("\(have) connected, but no paired Bluetooth device matches \"\(missing)\"")
                }
                return
            }
            let devName = dev.name ?? missing
            if dev.isConnected() { // connected, CoreAudio just hasn't caught up yet
                DispatchQueue.main.async { self?.connecting = false; self?.connectAttempts -= 1 }
                return
            }
            DispatchQueue.main.async { log("\(have) connected, connecting \(devName) (try \(attempt))") }
            let result = dev.openConnection()
            DispatchQueue.main.async {
                self?.connecting = false
                log(result == kIOReturnSuccess ? "connected \(devName)" : "couldn't connect \(devName) (IOReturn \(result))")
                self?.schedule()
            }
        }
    }
}

// MARK: - Install / uninstall the background helper

@discardableResult
func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}

let guiDomain = "gui/\(getuid())"

func helperRunning() -> Bool { launchctl(["print", "\(guiDomain)/\(agentLabel)"]) == 0 }

func cmdInstall() {
    let fm = FileManager.default
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Copy this binary out of ~/Desktop: background jobs can't run files from there.
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if me.path != installedBinary.path {
        launchctl(["bootout", "\(guiDomain)/\(agentLabel)"])
        try? fm.removeItem(at: installedBinary)
        do { try fm.copyItem(at: me, to: installedBinary) } catch { die("couldn't copy the helper: \(error)") }
    }

    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [installedBinary.path, "daemon"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Interactive",
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
    ]
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentPlist)
    } catch { die("couldn't write \(agentPlist.path): \(error)") }

    launchctl(["bootout", "\(guiDomain)/\(agentLabel)"])
    let rc = launchctl(["bootstrap", guiDomain, agentPlist.path])
    if rc != 0 { die("launchctl bootstrap failed (\(rc))") }

    var s = loadSettings(); s.paused = false; saveSettings(s)
    print("Background helper installed and running. It starts again at every login.")
    print("macOS will ask you to allow two things for sonos-stereo:")
    print("  - Accessibility (for the volume keys): System Settings > Privacy & Security > Accessibility")
    print("  - Bluetooth (to connect the second speaker)")
    print("Log: \(logURL.path)")
}

func cmdUninstall() {
    launchctl(["bootout", "\(guiDomain)/\(agentLabel)"])
    try? FileManager.default.removeItem(at: agentPlist)
    try? FileManager.default.removeItem(at: installedBinary)
    print("Background helper removed. The pair itself is untouched (use \"off\" to remove it).")
}

// MARK: - Commands

func cmdOn(_ args: [String]) {
    var s = loadSettings()
    s.swap = args.contains("--swap")
    s.btClock = args.contains("--bt-clock")
    s.paused = false
    saveSettings(s)
    do { print(try buildPair(s)) } catch let e as PairError { die(e.message) } catch { die("\(error)") }
    print(helperRunning() ? "Volume keys work while the pair is on." : "Volume keys need the helper: sonos-stereo install")
}

func cmdOff() {
    var s = loadSettings(); s.paused = true; saveSettings(s)
    let wasDefault = pairIsOutput()
    let removed = destroyPair()
    if let l = leftSpeaker(), wasDefault {
        setDefaultOutput(l)
        print("Sound output set back to \(name(l)).")
    }
    print(removed ? "Stereo pair removed." : "No stereo pair was set up.")
    if helperRunning() { print("Auto-pairing is paused until you run \"sonos-stereo on\".") }
}

func cmdStatus() {
    let l = leftSpeaker(), r = rightSpeaker()
    func line(_ label: String, _ id: AudioDeviceID?) {
        guard let id = id else { print("\(label): not connected"); return }
        let vol = getVolume(id).map { " volume \(Int(($0 * 100).rounded()))%" } ?? ""
        print("\(label): \(name(id)), \(outputChannels(id)) ch\(vol)")
    }
    line("Left speaker ", l)
    line("Right speaker", r)
    if let agg = device(withUID: pairUID) {
        let ch = stereoChannels(agg)
        print("Stereo pair  : \(pairIsHealthy() ? "set up" : "BROKEN (a speaker is missing)"), \(outputChannels(agg)) ch, left=ch\(ch[0]) right=ch\(ch[1])")
    } else {
        print("Stereo pair  : not set up")
    }
    print("Sound output : \(name(defaultOutput()))")
    let s = loadSettings()
    print("Helper       : \(helperRunning() ? "running" : "not installed")\(s.paused ? ", auto-pairing paused" : "")")
    if s.extraLeftFrames > 0 || s.extraRightFrames > 0 {
        print(String(format: "Calibration  : Left +%.0f ms, Right +%.0f ms", Double(s.extraLeftFrames) / 44.1, Double(s.extraRightFrames) / 44.1))
    }
}

func cmdVol(_ arg: String?) {
    guard let str = arg, let pct = Double(str), (0...100).contains(pct) else { die("usage: sonos-stereo vol <0-100>") }
    guard let l = leftSpeaker(), let r = rightSpeaker() else { die("both speakers need to be connected") }
    let v = Float32(pct / 100)
    let a = setVolume(l, v), b = setVolume(r, v)
    if !a && !b { die("neither speaker lets the Mac set its volume. Use the buttons on the speakers.") }
    print("Volume \(Int(pct))% on \(a ? name(l) : "-") and \(b ? name(r) : "-")")
}

/// Write a 16-bit stereo WAV file.
func writeStereoWav(_ url: URL, rate: Int, left: [Float], right: [Float]) {
    var pcm = Data(capacity: left.count * 4)
    for i in 0..<left.count {
        let l = Int16(max(-1, min(1, left[i])) * 32767), r = Int16(max(-1, min(1, right[i])) * 32767)
        withUnsafeBytes(of: l.littleEndian) { pcm.append(contentsOf: $0) }
        withUnsafeBytes(of: r.littleEndian) { pcm.append(contentsOf: $0) }
    }
    var h = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
    h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); h.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
    h.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
    try? (h + pcm).write(to: url)
}

func afplay(_ url: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = [url.path]
    try? p.run(); p.waitUntilExit()
}

/// Play a tone on the left, then on the right.
func cmdTest() {
    let rate = 44100, secs = 1.2, freq = 440.0
    let tone: [Float] = (0..<Int(Double(rate) * secs)).map { i in
        let t = Double(i) / Double(rate)
        return Float(sin(2 * .pi * freq * t) * 0.4 * min(1, min(t, secs - t) / 0.05))
    }
    let silence = [Float](repeating: 0, count: tone.count)
    for (side, isLeft) in [("LEFT", true), ("RIGHT", false)] {
        print("Playing tone on the \(side) side...")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sonos-test-\(side).wav")
        writeStereoWav(url, rate: rate, left: isLeft ? tone : silence, right: isLeft ? silence : tone)
        afplay(url)
        settle(0.4)
    }
}

// MARK: - Calibration (line the two speakers up in time using the Mac's microphone)

let calGap = 1.0      // seconds between a Left click and the Right click after it
let calPairs = 5

/// A click track: Left click at 1 s, Right click at 2 s, Left at 3 s, ... (silence elsewhere).
func clickTrack() -> URL {
    let rate = 44100
    let total = Int(Double(rate) * (Double(calPairs) * 2 * calGap + 1.5))
    var l = [Float](repeating: 0, count: total), r = l
    let clickLen = Int(0.006 * Double(rate))
    for k in 0..<(calPairs * 2) {
        let start = Int(Double(rate) * (1.0 + Double(k) * calGap))
        for i in 0..<clickLen {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(clickLen))   // smooth edges
            let v = Float(sin(2 * Double.pi * 2500 * Double(i) / Double(rate)) * w * 0.9)
            if k % 2 == 0 { l[start + i] = v } else { r[start + i] = v }
        }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sonos-clicks.wav")
    writeStereoWav(url, rate: rate, left: l, right: r)
    return url
}

func microphoneAllowed() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        var granted = false, done = false
        AVCaptureDevice.requestAccess(for: .audio) { g in granted = g; done = true }
        let until = Date().addingTimeInterval(60)
        while !done && Date() < until { settle(0.2) }
        return granted
    default: return false
    }
}

/// Plays the click track on the pair while recording with the default microphone.
/// Returns how many ms the Left speaker is AHEAD of the Right one for each click pair
/// (negative = Left is behind).
func measureOffsets() throws -> [Double] {
    let recURL = FileManager.default.temporaryDirectory.appendingPathComponent("sonos-cal-rec.wav")
    try? FileManager.default.removeItem(at: recURL)
    let recSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0,
                                      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let rec = try AVAudioRecorder(url: recURL, settings: recSettings)
    guard rec.record() else { throw PairError(message: "couldn't start recording from the microphone") }
    settle(0.4)
    afplay(clickTrack())
    settle(0.8)   // Bluetooth plays ~0.25 s late, so keep listening a bit longer
    rec.stop()

    let f = try AVAudioFile(forReading: recURL)
    guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
        throw PairError(message: "couldn't read the recording")
    }
    try f.read(into: buf)
    let rate = f.processingFormat.sampleRate
    let x = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    guard x.count > 1, x.contains(where: { $0 != 0 }) else {
        throw PairError(message: "the recording is silent. Allow microphone access for your terminal app (System Settings > Privacy & Security > Microphone)")
    }

    // Listen only for the click's pitch (2.5 kHz): energy in 6 ms windows every 1 ms.
    // Room noise (talking, typing, fans) mostly sits elsewhere, so the clicks stand out.
    let win = Int(0.006 * rate), hop = max(1, Int(rate / 1000))
    let cosT = (0..<win).map { Float(cos(2 * Double.pi * 2500 * Double($0) / rate)) }
    let sinT = (0..<win).map { Float(sin(2 * Double.pi * 2500 * Double($0) / rate)) }
    var env: [Float] = []
    var st = 0
    while st + win < x.count {
        var a: Float = 0, b: Float = 0
        for i in 0..<win { a += x[st + i] * cosT[i]; b += x[st + i] * sinT[i] }
        env.append((a * a + b * b).squareRoot())
        st += hop
    }
    let msPerStep = Double(hop) / rate * 1000
    let noise = env.sorted()[env.count / 2]
    func strongest(from t0: Double, to t1: Double) -> (t: Double, snr: Float)? {
        let i0 = max(0, Int(t0 * 1000 / msPerStep)), i1 = min(env.count, Int(t1 * 1000 / msPerStep))
        guard i1 > i0 else { return nil }
        var best = i0
        for i in i0..<i1 where env[i] > env[best] { best = i }
        return (Double(best) * msPerStep / 1000, env[best] / max(noise, 1e-9))
    }

    // The first Left click is the first strong 2.5 kHz burst. Every other click is then
    // looked for near where it should be (Right can be up to 0.3 s early or late).
    guard let firstIdx = env.firstIndex(where: { $0 > noise * 8 }),
          let first = strongest(from: Double(firstIdx) * msPerStep / 1000, to: Double(firstIdx) * msPerStep / 1000 + 0.02) else {
        throw PairError(message: "didn't hear the clicks. Turn the volume up a bit and keep the room quiet")
    }
    var offsets: [Double] = []
    var weakest: Float = .infinity
    for k in 0..<calPairs {
        let expectL = first.t + Double(2 * k) * calGap
        guard let l = k == 0 ? first : strongest(from: expectL - 0.1, to: expectL + 0.1),
              let r = strongest(from: expectL + calGap - 0.3, to: expectL + calGap + 0.3) else { break }
        weakest = min(weakest, l.snr, r.snr)
        offsets.append((r.t - l.t - calGap) * 1000)
    }
    guard offsets.count == calPairs, weakest >= 4 else {
        throw PairError(message: "couldn't hear every click clearly (weakest was \(Int(weakest))x the room noise). Turn the volume up a bit, keep the room quiet, and try again")
    }
    return offsets
}

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }

func describe(_ ms: Double) -> String {
    abs(ms) < 1 ? "in sync" : String(format: "Left is %.0f ms %@ Right", abs(ms), ms > 0 ? "ahead of" : "behind")
}

func cmdCalibrate() {
    guard microphoneAllowed() else {
        die("no microphone access. Allow it for your terminal app in System Settings > Privacy & Security > Microphone")
    }
    var s = loadSettings()
    s.paused = false
    func rebuild() { do { _ = try buildPair(s) } catch let e as PairError { die(e.message) } catch { die("\(error)") } ; settle(1.0) }
    func measure(_ label: String) -> (Double, Double) {
        print("\(label): playing \(calPairs * 2) clicks, keep the room quiet (~\(Int(Double(calPairs) * 2 * calGap + 3)) s)...")
        do {
            let v = try measureOffsets()
            let m = median(v), wobble = (v.max()! - v.min()!)
            print("  \(describe(m)), wobble \(Int(wobble.rounded())) ms  [\(v.map { String(format: "%.0f", $0) }.joined(separator: ", "))]")
            return (m, wobble)
        } catch let e as PairError { die(e.message) } catch { die("\(error)") }
    }

    s.extraLeftFrames = 0; s.extraRightFrames = 0
    saveSettings(s)
    rebuild()
    let (m0, wobble0) = measure("1) Measuring with no correction")
    if wobble0 > 40 {
        print("  The gap jumps around by \(Int(wobble0)) ms between clicks. A fixed delay can't fix that much wobble;")
        print("  it comes from the two Bluetooth links. Freeing up the Mac's Bluetooth radio helps most.")
    }
    if abs(m0) < 4 { print("Already in sync (within 4 ms). Nothing to change."); return }

    // An aggregate device lines up its sub-devices by their latency, so the direction of
    // "extra latency" is easiest to confirm by measuring. Try it on each speaker, keep the best.
    let frames = Int(abs(m0) / 1000 * 44100)
    var best = (err: abs(m0), left: 0, right: 0)
    for (label, l, r) in [("2) Trying a \(Int(abs(m0))) ms correction on the Left speaker", frames, 0),
                          ("3) Trying a \(Int(abs(m0))) ms correction on the Right speaker", 0, frames)] {
        s.extraLeftFrames = l; s.extraRightFrames = r
        rebuild()
        let (m, _) = measure(label)
        if abs(m) < best.err { best = (abs(m), l, r) }
        if abs(m) < 4 { break }
    }
    s.extraLeftFrames = best.left; s.extraRightFrames = best.right
    saveSettings(s)
    rebuild()
    if best.left == 0 && best.right == 0 {
        print("Neither correction helped, so none is applied. The offset may be coming from the speakers themselves.")
    } else {
        print(String(format: "Done. Correction saved (%@ %.0f ms); the gap is now about %.0f ms.",
                     best.left > 0 ? "Left" : "Right", Double(max(best.left, best.right)) / 44.1, best.err))
        print("Run \"sonos-stereo calibrate\" again any time it sounds off, e.g. after a speaker reconnects.")
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "on", "pair": cmdOn(args)
case "off", "unpair": cmdOff()
case "status": cmdStatus()
case "vol", "volume": cmdVol(args.dropFirst().first)
case "test": cmdTest()
case "calibrate", "sync": cmdCalibrate()
case "install": cmdInstall()
case "uninstall": cmdUninstall()
case "daemon": Helper().start()
default:
    print("usage: sonos-stereo on [--swap] [--bt-clock] | off | status | vol <0-100> | test | calibrate | install | uninstall")
    exit(args.first == "-h" || args.first == "--help" ? 0 : 2)
}
