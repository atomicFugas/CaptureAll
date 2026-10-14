import AVFoundation
import CoreMedia

/// Captures microphone audio as CMSampleBuffers for AVAssetWriter.
final class AudioMixer: NSObject {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "app.captureall.mic")
    private var onMicBuffer: ((CMSampleBuffer) -> Void)?
    private(set) var isRunning = false

    func start(deviceID: String?, handler: @escaping (CMSampleBuffer) -> Void) throws {
        stop()
        onMicBuffer = handler

        session.beginConfiguration()

        for input in session.inputs {
            session.removeInput(input)
        }
        for out in session.outputs {
            session.removeOutput(out)
        }

        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else {
            session.commitConfiguration()
            throw AudioMixerError.noInput
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw AudioMixerError.noInput
            }
            session.addInput(input)

            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw AudioMixerError.noInput
            }
            session.addOutput(output)
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }

        // Must be AFTER commitConfiguration — calling inside begin/commit crashes.
        session.startRunning()
        isRunning = true
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        isRunning = false
        onMicBuffer = nil
    }

    static func availableMicrophones() -> [(id: String, name: String)] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        ).devices.map { ($0.uniqueID, $0.localizedName) }
    }
}

extension AudioMixer: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onMicBuffer?(sampleBuffer)
    }
}

enum AudioMixerError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone found." }
}
