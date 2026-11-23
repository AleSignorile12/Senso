// CameraFraming.swift
// Optional (Settings): looks for the cup before a pour. A cup in view lets a pour be recognised a little
// sooner; Senso never needs it. It also gives aiming tips: "Move the phone left",
// "Move closer", "Cup centred". Vision's built-in image classifier says whether a cup-like object is in
// view; the objectness saliency request says where the main object sits. When neither is sure, the cue
// is "no cup", never a guess. The camera doesn't estimate fill.
// While it runs, it also samples the picture's colours (`sceneColors`) for the pouring screen's background.

import AVFoundation
import Observation
import os
import Vision

nonisolated private let log = Logger(subsystem: "com.senso.app", category: "camera")

nonisolated enum FramingCue: Sendable, Equatable {
    case noCup
    case centered
    case moveLeft, moveRight, moveUp, moveDown
    case moveCloser, moveBack
}

@Observable
final class CameraFraming {
    private(set) var status: SensorStatus = .unavailable
    private(set) var cue: FramingCue?
    /// A cup has been seen in `confirmFrames` analysed frames in a row (~0.7 s), so one wrong glimpse
    /// can't unlock the pour. Stays true until `stop()`.
    private(set) var cupConfirmed = false
    static let confirmFrames = 2
    @ObservationIgnored private var cupStreak = 0
    /// Average colours of the live picture, 3 × 3 row by row from the top left, already darkened for contrast.
    private(set) var sceneColors: [SIMD3<Float>]?

    @ObservationIgnored private var capture: CameraCapture?

    func start() async {
        guard capture == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = .unavailable
            return
        }
        let capture = CameraCapture(onCue: { [weak self] cue in
            Task { @MainActor in
                guard let self, self.capture != nil else { return }
                self.cue = cue
                self.status = cue == .noCup ? .lowConfidence : .active
                self.cupStreak = cue == .noCup ? 0 : self.cupStreak + 1
                if self.cupStreak >= Self.confirmFrames { self.cupConfirmed = true }
            }
        }, onColors: { [weak self] colors in
            Task { @MainActor in
                guard let self, self.capture != nil else { return }
                self.sceneColors = colors
            }
        })
        guard capture.configure() else {
            status = .unavailable
            return
        }
        self.capture = capture
        capture.start()
        status = .lowConfidence
    }

    func stop() {
        capture?.stop()
        capture = nil
        cue = nil
        cupConfirmed = false
        cupStreak = 0
        sceneColors = nil
        status = .unavailable
    }
}

/// Owns the capture session. `@unchecked Sendable`: the session is configured, started and stopped only
/// on `sessionQueue`, and frames arrive only on `videoQueue`, where all frame state lives.
nonisolated final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Vision labels that mean "a cup is in view" (from ClassifyImageRequest.supportedIdentifiers).
    static let cupLabels: Set<String> = ["cup", "mug", "drinking_glass", "coffee", "tea_drink", "drink", "bubble_tea"]
    static let minimumCupConfidence: Float = 0.2
    /// Three frames a second is plenty for spoken cues and keeps the phone cool.
    static let frameInterval = 1.0 / 3
    /// Colour sampling is cheap, so it runs faster: the background follows the camera without lag.
    static let colorInterval = 1.0 / 10

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.senso.camera.session")
    private let videoQueue = DispatchQueue(label: "com.senso.camera.frames")
    private let onCue: @Sendable (FramingCue) -> Void
    private let onColors: @Sendable ([SIMD3<Float>]) -> Void
    private var lastFrameTime = 0.0
    private var lastColorTime = 0.0

    init(onCue: @escaping @Sendable (FramingCue) -> Void, onColors: @escaping @Sendable ([SIMD3<Float>]) -> Void) {
        self.onCue = onCue
        self.onColors = onColors
    }

    func configure() -> Bool {
        sessionQueue.sync {
            // Video only: leave the audio session to AudioCaptureService.
            session.automaticallyConfiguresApplicationAudioSession = false
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = .vga640x480
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
            else { return false }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            // BGRA so the colour sampling can read pixels directly; Vision accepts it too.
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            return true
        }
    }

    func start() { sessionQueue.async { self.session.startRunning() } }
    func stop() { sessionQueue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if time - lastColorTime >= Self.colorInterval {
            lastColorTime = time
            if let colors = Self.sceneColors(in: pixels) { onColors(colors) }
        }
        guard time - lastFrameTime >= Self.frameInterval else { return }
        lastFrameTime = time
        // The sensor is landscape; .right makes Vision's coordinates match the upright portrait phone.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right)
        let classify = VNClassifyImageRequest()
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        do {
            try handler.perform([classify, saliency])
        } catch {
            log.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let cupSeen = (classify.results ?? []).contains {
            Self.cupLabels.contains($0.identifier) && $0.confidence >= Self.minimumCupConfidence
        }
        let box = saliency.results?.first?.salientObjects?.max { $0.boundingBox.area < $1.boundingBox.area }?.boundingBox
        onCue(Self.cue(cupSeen: cupSeen, box: box))
    }

    /// The picture's colours for the glass on the pouring screen: a 3 × 3 grid of averages. No text sits on
    /// them, so they keep their real brightness.
    static func sceneColors(in pixels: CVPixelBuffer) -> [SIMD3<Float>]? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let bgra = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        return portraitGrid(bgra: bgra, width: CVPixelBufferGetWidth(pixels), height: height, bytesPerRow: bytesPerRow)
    }

    /// Average colour (RGB, 0…1) of each cell of a 3 × 3 grid over the upright portrait picture, row by
    /// row from the top left. The buffer is the landscape sensor image; upright portrait is that image
    /// turned 90° clockwise (Vision's `.right`), so buffer left → portrait top, buffer top → portrait right.
    /// Samples every `step`-th pixel each way.
    static func portraitGrid(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, step: Int = 8) -> [SIMD3<Float>] {
        var sums = [SIMD3<Float>](repeating: .zero, count: 9)
        var counts = [Float](repeating: 0, count: 9)
        for y in stride(from: step / 2, to: height, by: step) {
            let column = 2 - min(2, y * 3 / height)
            for x in stride(from: step / 2, to: width, by: step) {
                let row = min(2, x * 3 / width)
                let offset = y * bytesPerRow + x * 4
                sums[row * 3 + column] += SIMD3(Float(bgra[offset + 2]), Float(bgra[offset + 1]), Float(bgra[offset])) / 255
                counts[row * 3 + column] += 1
            }
        }
        return zip(sums, counts).map { sum, count in count > 0 ? sum / count : .zero }
    }

    /// `box` in Vision's normalized coordinates (origin bottom-left, upright image).
    static func cue(cupSeen: Bool, box: CGRect?) -> FramingCue {
        guard cupSeen, let box else { return .noCup }
        // The cup sits left in the picture → move the phone left to bring it to the middle.
        if box.midX < 0.35 { return .moveLeft }
        if box.midX > 0.65 { return .moveRight }
        if box.midY > 0.7 { return .moveUp }
        if box.midY < 0.3 { return .moveDown }
        if box.area < 0.05 { return .moveCloser }
        if box.area > 0.6 { return .moveBack }
        return .centered
    }
}

private extension CGRect {
    nonisolated var area: CGFloat { width * height }
}
