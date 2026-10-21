import CoreMedia
import Foundation
import ScreenCaptureKit

/// System audio via ScreenCaptureKit. Callbacks arrive on a background queue, so this stays off the main actor.
nonisolated final class NativeAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var isStopping = false
    private let onSamples: @Sendable ([Float], Int) -> Void
    private let onError: @Sendable (String) -> Void

    init(onSamples: @escaping @Sendable ([Float], Int) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onSamples = onSamples
        self.onError = onError
    }

    func start(sampleRate: Int = 48_000, channels: Int = 2) async throws {
        guard stream == nil else { return }
        isStopping = false

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw HuebeatError.audio("No display found for ScreenCaptureKit audio capture.")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = sampleRate
        configuration.channelCount = channels
        // Audio only: keep the unavoidable video stream as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        isStopping = true
        self.stream = nil
        try? await stream.stopCapture()
        isStopping = false
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        onError(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        var blockBuffer: CMBlockBuffer?
        var bufferListSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSizeNeeded > 0 else { return }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        // Non-interleaved buffers (one per channel) are flattened channel after channel; the mapper only needs energy.
        var samples: [Float] = []
        let buffers = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for audioBuffer in buffers {
            guard audioBuffer.mDataByteSize > 0, let data = audioBuffer.mData else { continue }
            channels = max(channels, Int(audioBuffer.mNumberChannels))
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride
            let pointer = data.assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        }

        guard !samples.isEmpty else { return }
        onSamples(samples, max(1, channels))
    }
}
