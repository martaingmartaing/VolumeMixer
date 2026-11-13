import AppKit
import CoreAudio
import Darwin

// MARK: - Localization

private let isFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false

/// Returns the French string on French systems, the English one otherwise.
func L(_ english: String, _ french: String) -> String { isFrench ? french : english }

// MARK: - Generic Core Audio property access

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioValue<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    initial: T
) -> T? {
    var address = propertyAddress(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func audioArray<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    of type: T.Type
) -> [T] {
    var address = propertyAddress(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let capacity = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
}

@discardableResult
func setAudioValue<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    value: T
) -> Bool {
    var address = propertyAddress(selector, scope)
    var value = value
    return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
}

func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Bool {
    var address = propertyAddress(selector, scope)
    guard AudioObjectHasProperty(object, &address) else { return false }
    var settable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
}

func addListener(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    handler: @escaping () -> Void
) {
    var address = propertyAddress(selector, scope)
    AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main) { _, _ in handler() }
}

// MARK: - Mapping an audio process to the app that owns it

struct AppIdentity {
    let key: String
    let name: String
    let icon: NSImage
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsiblePIDFn: ResponsibleFn? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsibleFn.self)
}()

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

private func processName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// Helper processes (e.g. "Google Chrome Helper", Safari's WebKit engine)
/// are attributed to the visible app responsible for them.
private func owningApplication(of pid: pid_t) -> NSRunningApplication? {
    if let responsible = responsiblePIDFn?(pid), responsible > 0,
       let app = NSRunningApplication(processIdentifier: responsible), app.activationPolicy == .regular {
        return app
    }
    var current = pid
    for _ in 0..<8 {
        if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
            return app
        }
        guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
        current = parent
    }
    return NSRunningApplication(processIdentifier: pid)
}

func identify(pid: pid_t, audioBundleID: String?) -> AppIdentity {
    let genericIcon = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil) ?? NSImage()

    if let app = owningApplication(of: pid) {
        let key = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let name = app.localizedName ?? processName(of: pid) ?? key
        return AppIdentity(key: key, name: name, icon: app.icon ?? genericIcon)
    }
    if let bundleID = audioBundleID, !bundleID.isEmpty {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return AppIdentity(key: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        return AppIdentity(key: bundleID, name: processName(of: pid) ?? bundleID, icon: genericIcon)
    }
    let name = processName(of: pid) ?? "\(L("Process", "Processus")) \(pid)"
    return AppIdentity(key: "proc.\(name)", name: name, icon: genericIcon)
}
