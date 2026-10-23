import AVFoundation
import CabinCore

/// Hosts the EQ / room-and-vinyl DSP (`AudioEQ`) as an in-process audio unit, so the varispeed
/// (Slowed + Reverb) engine gets the same tone shaping the AVPlayer path applies through its
/// `MTAudioProcessingTap`. Without this, engaging Slowed + Reverb on a downloaded track silently
/// dropped the Room & vinyl effects and the EQ.
///
/// Registered once as an in-process v3 component; `AVAudioUnitEffect(audioComponentDescription:)`
/// then instantiates it synchronously, so it can sit in the chain from the engine's init.
final class RoomEffectAU: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("cbrm"),
        componentManufacturer: fourCC("Cabn"),
        componentFlags: 0, componentFlagsMask: 0)

    /// Register the subclass with the system (idempotent — run before the first instantiation).
    static let register: Void = {
        AUAudioUnit.registerSubclass(RoomEffectAU.self, as: componentDescription,
                                     name: "Cabin: Room & vinyl", version: 1)
    }()

    /// The DSP. Push gains / room / amount here exactly as for the AVPlayer taps.
    let eq = AudioEQ(gains: EQ.flat.gains, room: Room.off, amount: 1)

    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inBusses: AUAudioUnitBusArray!
    private var outBusses: AUAudioUnitBusArray!
    /// Backing storage for hosts that pull with null output buffers.
    private var scratch: AVAudioPCMBuffer?

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: fmt)
        outputBus = try AUAudioUnitBus(format: fmt)
        try super.init(componentDescription: componentDescription, options: options)
        inBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inBusses }
    override var outputBusses: AUAudioUnitBusArray { outBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let fmt = outputBus.format
        eq.prepare(sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount),
                   maxFrames: Int(maximumFramesToRender))
        scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: maximumFramesToRender)
    }

    override func deallocateRenderResources() {
        eq.unprepareTap()
        scratch = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let eq = self.eq
        let scratch = self.scratch
        return { _, timestamp, frameCount, _, outputData, _, pullInput in
            guard let pull = pullInput else { return kAudioUnitErr_NoConnection }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            if let s = scratch {
                let src = UnsafeMutableAudioBufferListPointer(s.mutableAudioBufferList)
                for i in 0..<min(abl.count, src.count) where abl[i].mData == nil { abl[i].mData = src[i].mData }
            }
            for i in 0..<abl.count { abl[i].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size) }
            var flags: AudioUnitRenderActionFlags = []
            let err = pull(&flags, timestamp, frameCount, 0, outputData)
            guard err == noErr else { return err }
            eq.process(outputData, frames: CMItemCount(frameCount))
            return noErr
        }
    }
}

private func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
