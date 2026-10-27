import AudioToolbox
import CoreAudio
import CoreMedia

enum ProcessTapError: LocalizedError {
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status):
            return String(localized: "The other side's audio couldn't be captured (Core Audio: \(step), error \(status)).")
        }
    }
}

final class ProcessTap {
    enum Target {
        case processes(where: (AudioProcess) -> Bool)
        case everythingExcept(where: (AudioProcess) -> Bool)

        fileprivate var isExclusive: Bool {
            if case .everythingExcept = self { return true }
            return false
        }

        fileprivate var matches: (AudioProcess) -> Bool {
            switch self {
            case .processes(let match), .everythingExcept(let match): return match
            }
        }
    }

    var onFailure: ((Error) -> Void)?

    private let target: Target
    private let muted: Bool
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var queue: DispatchQueue?
    private let ioQueue = DispatchQueue(label: "com.digisensus.recorder.tap-io", qos: .userInteractive)
    private var handler: (([Float], CMTime) -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let converter = MonoConverter(downmix: .average)
    private let tapBuffer = AudioBufferList.allocate(maximumBuffers: 1)

    deinit {
        tapBuffer.unsafeMutablePointer.deallocate()
    }

    init(target: Target, muted: Bool = false) {
        self.target = target
        self.muted = muted
        let processes = Self.objects(matching: target)
        description = target.isExclusive
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = muted ? .muted : .unmuted
        description.isPrivate = true
    }

    var processCount: Int { description.processes.count }

    func start(queue: DispatchQueue, handler: @escaping ([Float], CMTime) -> Void) throws {
        self.queue = queue
        self.handler = handler
        Log.write("tap: \(target.isExclusive ? "all audio except" : "audio of") \(processCount) process object(s)")
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the process tap")
        do {
            try startDevice()
            let system = AudioObjectID(kAudioObjectSystemObject)
            listen(to: kAudioHardwarePropertyProcessObjectList, of: system) { [weak self] in self?.followProcesses() }
            listen(to: kAudioHardwarePropertyDefaultOutputDevice, of: system) { [weak self] in
                self?.rebuildDevice(because: "output device changed")
            }
            listen(to: kAudioTapPropertyFormat, of: tapID) { [weak self] in self?.rebuildDevice(because: "tap format changed") }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners = []
        if let queue { queue.sync(execute: tearDown) } else { tearDown() }
    }

    private func tearDown() {
        stopDevice()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        handler = nil
    }

    private func startDevice() throws {
        var outputID = AudioObjectID(kAudioObjectUnknown)
        try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                      into: &outputID, "find the output device")
        var outputUID: CFString = "" as CFString
        try Self.read(outputID, kAudioDevicePropertyDeviceUID, into: &outputUID, "read the output device UID")
        let outputInputs = Self.inputStreamCount(of: outputID)
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
        let handler = handler
        let tapBuffer = tapBuffer
        let queue = queue
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let last = list.last else { return }
            tapBuffer[0] = last
            guard let mono = converter.convert(tapBuffer, asbd: format) else { return }
            let time = CMClockMakeHostTimeFromSystemUnits(inputTime.pointee.mHostTime)
            queue?.async { handler?(mono, time) }
        }, "install the tap callback")
        switchOffInputs(count: outputInputs)
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start the tap device")
    }

    private func switchOffInputs(count: Int) {
        guard count > 0, let ioProcID else { return }
        var address = Self.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size else { return }
        let usage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                     alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { usage.deallocate() }
        usage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        usage.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, usage) == noErr else { return }
        guard let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams),
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let streams = Int(usage.load(fromByteOffset: countOffset, as: UInt32.self))
        let flags = usage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        for stream in 0..<min(count, max(streams - 1, 0)) { flags[stream] = 0 }
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, usage)
        Log.write("tap: left \(count) output-device input stream(s) off, status \(status)")
    }

    private func stopDevice() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func followProcesses() {
        guard tapID != kAudioObjectUnknown else { return }
        let processes = Self.objects(matching: target)
        guard Set(processes) != Set(description.processes) else { return }
        description.processes = processes
        var reference = Unmanaged.passUnretained(description).toOpaque()
        var address = Self.address(kAudioTapPropertyDescription)
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
        Log.write("tap now follows \(processes.count) process object(s), status \(status)")
    }

    private func rebuildDevice(because reason: String) {
        guard tapID != kAudioObjectUnknown else { return }
        Log.write("\(reason), rebuilding the tap device")
        stopDevice()
        do {
            try startDevice()
        } catch {
            Log.write("tap rebuild failed: \(error)")
            onFailure?(error)
        }
    }

    private func listen(to selector: AudioObjectPropertySelector, of object: AudioObjectID,
                        _ action: @escaping () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        listeners.append((object, address, block))
    }

    private static func inputStreamCount(of device: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func objects(matching target: Target) -> [AudioObjectID] {
        AudioProcess.all().filter(target.matches).map(\.object)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                into value: inout T, _ step: String) throws {
        var address = address(selector)
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
