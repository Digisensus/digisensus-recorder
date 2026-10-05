import AudioToolbox
import CoreAudio
import CoreMedia

enum ProcessTapError: LocalizedError {
    case noProcesses([String])
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noProcesses(let names):
            return "None of these audio processes are running: \(names.joined(separator: ", "))."
        case .coreAudio(let step, let status):
            return "Core Audio failed to \(step) (error \(status))."
        }
    }
}

final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let converter = MonoConverter(downmix: .average)

    func start(processNames: [String], queue: DispatchQueue,
               handler: @escaping ([Float], CMTime) -> Void) throws {
        let processes = Self.audioProcessObjects(named: processNames)
        guard !processes.isEmpty else { throw ProcessTapError.noProcesses(processNames) }
        Log.write("tapping \(processes.count) process object(s) for \(processNames)")

        var outputID = AudioObjectID(kAudioObjectUnknown)
        try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                      into: &outputID, "find the output device")
        var outputUID: CFString = "" as CFString
        try Self.read(outputID, kAudioDevicePropertyDeviceUID, into: &outputUID, "read the output device UID")

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the process tap")

        do {
            var format = AudioStreamBasicDescription()
            try Self.read(tapID, kAudioTapPropertyFormat, into: &format, "read the tap format")
            Log.write("tap format: \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, "
                + "\(format.mBitsPerChannel) bit, flags 0x\(String(format.mFormatFlags, radix: 16))")

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Digisensus Recorder Tap",
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
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "create the tap device")

            let converter = converter
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, inputTime, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let mono = converter.convert(list, asbd: format) else { return }
                handler(mono, CMClockMakeHostTimeFromSystemUnits(inputTime.pointee.mHostTime))
            }, "install the tap callback")
            try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start the tap device")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func audioProcessObjects(named names: [String]) -> [AudioObjectID] {
        AudioProcess.all().filter { names.contains($0.name) }.map(\.object)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                into value: inout T, _ step: String) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw ProcessTapError.coreAudio(step, status) }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw ProcessTapError.coreAudio(step, status) }
    }
}
