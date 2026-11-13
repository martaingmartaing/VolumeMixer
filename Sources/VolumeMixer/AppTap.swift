import CoreAudio
import Foundation

struct TapError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) (\(L("error", "erreur")) \(status))" }
}

private struct GainState {
    var target: Float32
    var current: Float32
}

private struct ChannelRef {
    let samples: UnsafeMutablePointer<Float32>
    let stride: Int
    let frames: Int
}

private func channelRef(_ buffer: AudioBuffer, _ channel: Int) -> ChannelRef? {
    let count = Int(buffer.mNumberChannels)
    guard count > 0, channel < count, let data = buffer.mData else { return nil }
    return ChannelRef(
        samples: data.assumingMemoryBound(to: Float32.self) + channel,
        stride: count,
        frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * count)
    )
}

/// Finds a channel by its global index in a buffer list (interleaved or not).
private func channelRef(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> ChannelRef? {
    var base = 0
    for buffer in list {
        let count = Int(buffer.mNumberChannels)
        if index < base + count { return channelRef(buffer, index - base) }
        base += count
    }
    return nil
}

private func render(_ source: ChannelRef, to destination: ChannelRef?, from start: Float32, to end: Float32) {
    guard let destination else { return }
    let frames = min(source.frames, destination.frames)
    guard frames > 0 else { return }
    let step = (end - start) / Float32(frames)
    var gain = start
    var src = source.samples
    var dst = destination.samples
    for _ in 0..<frames {
        dst.pointee = src.pointee * gain
        gain += step
        src += source.stride
        dst += destination.stride
    }
}

/// Taps an app's audio (which is then muted at the source), applies a gain,
/// and plays it back on the output device.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputDevice: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let state: UnsafeMutablePointer<GainState>

    init(processObjects: [AudioObjectID], outputDevice: AudioObjectID, gain: Float) throws {
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        state = .allocate(capacity: 1)
        state.initialize(to: GainState(target: gain, current: gain))

        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
    }

    func setGain(_ gain: Float) {
        state.pointee.target = gain
    }

    private func start() throws {
        guard let outputUID = audioString(outputDevice, kAudioDevicePropertyDeviceUID) else {
            throw TapError(step: L("Output device not found", "Périphérique de sortie introuvable"), status: -1)
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "VolumeMixer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError(step: L("Could not create the audio tap", "Création de la capture audio impossible"), status: status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError(step: L("Could not create the mixing device", "Création du périphérique de mixage impossible"), status: status) }

        // The device's left/right channels (1-based).
        let stereo = audioArray(outputDevice, kAudioDevicePropertyPreferredChannelsForStereo,
                                scope: kAudioDevicePropertyScopeOutput, of: UInt32.self)
        let left = stereo.count == 2 ? max(Int(stereo[0]) - 1, 0) : 0
        let right = stereo.count == 2 ? max(Int(stereo[1]) - 1, 0) : 1
        let state = self.state

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, outputData, _ in
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in output {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            // The tap stream comes after the device's own inputs (microphone), if any.
            guard let tapBuffer = input.last, let sourceLeft = channelRef(tapBuffer, 0) else { return }
            let sourceRight = channelRef(tapBuffer, 1) ?? sourceLeft

            let start = state.pointee.current
            let end = state.pointee.target
            render(sourceLeft, to: channelRef(output, left), from: start, to: end)
            if right != left {
                render(sourceRight, to: channelRef(output, right), from: start, to: end)
            }
            state.pointee.current = end
        }
        guard status == noErr else { throw TapError(step: L("Could not start mixing", "Démarrage du mixage impossible"), status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(step: L("Could not start mixing", "Démarrage du mixage impossible"), status: status) }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        invalidate()
        // The audio thread may still be finishing a cycle: free the state later.
        let state = self.state
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { state.deallocate() }
    }
}
