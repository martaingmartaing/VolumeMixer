import AppKit
import AudioToolbox
import CoreAudio
import ServiceManagement

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let isPlaying: Bool
}

final class MixerModel: ObservableObject {
    static let shared = MixerModel()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var volumes: [String: Float]
    @Published private(set) var muted: Set<String>
    @Published private(set) var outputName = ""
    @Published private(set) var masterVolume: Float = 1
    @Published private(set) var masterMuted = false
    @Published private(set) var masterAdjustable = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private struct Group {
        var identity: AppIdentity
        var objects: [AudioObjectID] = []
        var isPlaying = false
    }

    /// System services hidden from the list (macOS system sounds).
    private static let hiddenProcesses = ["systemsoundserverd"]

    private var groups: [String: Group] = [:]
    private var taps: [String: AppTap] = [:]
    private var identities: [AudioObjectID: AppIdentity] = [:]
    private var observedProcesses: Set<AudioObjectID> = []
    private var observedDevices: Set<AudioObjectID> = []
    private var seen: Set<String> = []
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var refreshPending = false
    private let ownPID = getpid()
    private let defaults = UserDefaults.standard

    private init() {
        let stored = defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        volumes = stored.mapValues { Float($0) }
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])

        addListener(systemObject, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleRefresh() }
        addListener(systemObject, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.scheduleRefresh() }
        refresh()

        // Core Audio notifications are not always delivered:
        // periodic polling keeps the list up to date.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Per-app volume

    func volume(for key: String) -> Float { volumes[key] ?? 1 }
    func isMuted(_ key: String) -> Bool { muted.contains(key) }

    func setVolume(_ value: Float, for key: String) {
        volumes[key] = min(max(value, 0), 1)
        persist()
        syncTaps()
    }

    func toggleMute(_ key: String) {
        if muted.contains(key) { muted.remove(key) } else { muted.insert(key) }
        persist()
        syncTaps()
    }

    /// Gain actually applied (quadratic curve, which sounds more natural).
    private func gain(for key: String) -> Float {
        if muted.contains(key) { return 0 }
        let value = volume(for: key)
        return value * value
    }

    private func persist() {
        defaults.set(volumes.mapValues { Double($0) }, forKey: "volumes")
        defaults.set(Array(muted), forKey: "muted")
    }

    // MARK: - Master volume

    func setMasterVolume(_ value: Float) {
        masterVolume = value
        setAudioValue(outputDevice, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                      scope: kAudioDevicePropertyScopeOutput, value: Float32(value))
    }

    func toggleMasterMute() {
        let newValue: UInt32 = masterMuted ? 0 : 1
        if setAudioValue(outputDevice, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, value: newValue) {
            masterMuted = newValue == 1
        }
    }

    private func readMaster() {
        let scope = kAudioDevicePropertyScopeOutput
        // Only assign published properties when they change, to avoid redrawing the UI.
        let name = audioString(outputDevice, kAudioObjectPropertyName) ?? L("Output", "Sortie")
        if name != outputName { outputName = name }
        let adjustable = isSettable(outputDevice, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        if adjustable != masterAdjustable { masterAdjustable = adjustable }
        if let value = audioValue(outputDevice, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  scope: scope, initial: Float32(1)), value != masterVolume {
            masterVolume = value
        }
        let isMuted = (audioValue(outputDevice, kAudioDevicePropertyMute, scope: scope, initial: UInt32(0)) ?? 0) != 0
        if isMuted != masterMuted { masterMuted = isMuted }
    }

    // MARK: - Audio process tracking

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        // Output device
        let device = audioValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice,
                                initial: AudioObjectID(kAudioObjectUnknown)) ?? AudioObjectID(kAudioObjectUnknown)
        if device != outputDevice {
            outputDevice = device
            taps.removeAll() // recreated below on the new device
            if observedDevices.insert(device).inserted {
                let scope = kAudioDevicePropertyScopeOutput
                addListener(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) { [weak self] in self?.readMaster() }
                addListener(device, kAudioDevicePropertyMute, scope: scope) { [weak self] in self?.readMaster() }
            }
        }
        readMaster()

        // Audio processes, grouped by app
        let objects = audioArray(systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        let alive = Set(objects)
        identities = identities.filter { alive.contains($0.key) }
        observedProcesses.formIntersection(alive)

        var newGroups: [String: Group] = [:]
        for object in objects {
            guard let pid = audioValue(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0, pid != ownPID else { continue }
            if observedProcesses.insert(object).inserted {
                addListener(object, kAudioProcessPropertyIsRunningOutput) { [weak self] in self?.scheduleRefresh() }
            }
            let identity = identities[object]
                ?? identify(pid: pid, audioBundleID: audioString(object, kAudioProcessPropertyBundleID))
            identities[object] = identity
            guard !Self.hiddenProcesses.contains(where: { identity.key.hasSuffix($0) || identity.name == $0 }) else { continue }

            let running = (audioValue(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            var group = newGroups[identity.key] ?? Group(identity: identity)
            group.objects.append(object)
            group.isPlaying = group.isPlaying || running
            newGroups[identity.key] = group
        }
        groups = newGroups

        for (key, group) in groups where group.isPlaying { seen.insert(key) }
        seen.formIntersection(groups.keys)

        let newApps = groups.values
            .filter { seen.contains($0.identity.key) }
            .map { AudioApp(id: $0.identity.key, name: $0.identity.name, icon: $0.identity.icon, isPlaying: $0.isPlaying) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let unchanged = newApps.count == apps.count && zip(newApps, apps).allSatisfy {
            $0.id == $1.id && $0.name == $1.name && $0.isPlaying == $1.isPlaying
        }
        if !unchanged { apps = newApps }

        syncTaps()
    }

    /// A tap only exists for apps that are currently playing
    /// and whose volume is not 100%.
    private func syncTaps() {
        var failure: String?
        for (key, tap) in taps {
            let group = groups[key]
            let needed = group?.isPlaying == true && gain(for: key) != 1
            if !needed || tap.processObjects != group?.objects.sorted() {
                taps[key] = nil
            }
        }
        guard outputDevice != kAudioObjectUnknown else { return }
        for (key, group) in groups where group.isPlaying {
            let gain = gain(for: key)
            guard gain != 1 else { continue }
            if let tap = taps[key] {
                tap.setGain(gain)
            } else {
                do {
                    taps[key] = try AppTap(processObjects: group.objects.sorted(), outputDevice: outputDevice, gain: gain)
                } catch {
                    failure = "\(group.identity.name): \(error.localizedDescription)"
                }
            }
        }
        if errorMessage != failure { errorMessage = failure }
    }

    func shutdown() {
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "\(L("Launch at login", "Lancement au démarrage")): \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
