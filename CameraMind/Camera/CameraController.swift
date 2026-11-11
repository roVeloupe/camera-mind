import AVFoundation
import CoreImage
import UIKit

final class CameraController: NSObject, ObservableObject {

    // MARK: 对外状态
    @Published private(set) var isRunning = false
    @Published private(set) var capabilities: DeviceCapabilities?
    @Published var captureParams = CaptureParameters.default
    @Published var lastError: String?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private let ciContext = CIContext()

    // 最新一帧（用于 AI 分析，比拍照快）
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    // MARK: 启动
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let dev = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.lastError = "没有可用的后置摄像头" }
            return
        }
        device = dev

        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frames"))
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        publishCapabilities(for: dev)
    }

    private func publishCapabilities(for dev: AVCaptureDevice) {
        let lenses = [
            ("ultraWide", AVCaptureDevice.DeviceType.builtInUltraWideCamera),
            ("wide", .builtInWideAngleCamera),
            ("tele", .builtInTelephotoCamera)
        ].compactMap { name, type -> String? in
            AVCaptureDevice.default(type, for: .video, position: .back) != nil ? name : nil
        }
        let f = dev.activeFormat
        let caps = DeviceCapabilities(
            lenses: lenses,
            minISO: Double(f.minISO),
            maxISO: Double(f.maxISO),
            minShutterSeconds: f.minExposureDuration.seconds,
            maxShutterSeconds: f.maxExposureDuration.seconds,
            maxZoom: Double(min(dev.maxAvailableVideoZoomFactor, 15)),
            maxWhiteBalanceGain: Double(dev.maxWhiteBalanceGain),
            hasTorch: dev.hasTorch,
            supportsHDR: dev.activeFormat.isVideoHDRSupported,
            sensorWidth: Int(dev.activeFormat.formatDescription.dimensions.width),
            sensorHeight: Int(dev.activeFormat.formatDescription.dimensions.height)
        )
        DispatchQueue.main.async { self.capabilities = caps }
    }

    // MARK: 应用硬件参数
    func apply(_ p: CaptureParameters) {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.lastError = "锁定设备失败：\(error.localizedDescription)" }
            return
        }
        defer { dev.unlockForConfiguration() }

        // 变焦
        let zoom = max(1.0, min(p.zoom, Double(min(dev.maxAvailableVideoZoomFactor, 15))))
        dev.videoZoomFactor = CGFloat(zoom)

        // 曝光
        if p.exposureMode == "manual", dev.isExposureModeSupported(.custom) {
            let fmt = dev.activeFormat
            let lo = fmt.minExposureDuration.seconds
            let hi = fmt.maxExposureDuration.seconds
            let secs = max(lo, min(p.shutterSeconds, hi))
            let duration = CMTime(seconds: secs, preferredTimescale: 1_000_000_000)
            let iso = Float(max(Double(fmt.minISO), min(p.iso, Double(fmt.maxISO))))
            dev.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        } else {
            dev.exposureMode = .continuousAutoExposure
            let bias = Float(max(Double(dev.minExposureTargetBias), min(p.exposureBias, Double(dev.maxExposureTargetBias))))
            dev.setExposureTargetBias(bias, completionHandler: nil)
        }

        // 对焦
        if p.focusMode == "locked", dev.isFocusModeSupported(.locked) {
            dev.setFocusModeLocked(lensPosition: Float(max(0, min(p.lensPosition, 1))))
        } else {
            dev.focusMode = .continuousAutoFocus
        }

        // 白平衡
        if p.whiteBalanceMode == "locked", dev.isWhiteBalanceModeSupported(.locked) {
            let gains = WhiteBalance.gains(kelvin: p.temperature, tint: p.tint, maxGain: dev.maxWhiteBalanceGain)
            dev.setWhiteBalanceModeLocked(with: gains)
        } else {
            dev.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        // 补光灯
        if dev.hasTorch {
            if p.torch > 0.01 {
                try? dev.setTorchModeOn(level: max(0.01, min(Float(p.torch), 1)))
            } else if dev.torchMode == .on {
                dev.torchMode = .off
            }
        }

        DispatchQueue.main.async { self.captureParams = p }
    }

    // MARK: 抓帧
    func captureData(maxDimension: CGFloat = 1536, quality: CGFloat = 0.85) async throws -> Data {
        // 走拍照通道：画质更好，且缓冲由系统管理，不会读到已回收的帧
        return try await capturePhotoData(maxDimension: maxDimension, quality: quality)
    }

    private func currentPixelBuffer() -> CVPixelBuffer? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return latestPixelBuffer
    }

    private func capturePhotoData(maxDimension: CGFloat, quality: CGFloat) async throws -> Data {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.photoContinuation = cont
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    static func encode(buffer: CVPixelBuffer, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        let image = UIImage(cgImage: cg, scale: 1, orientation: .right)
        return image.resized(maxDimension: maxDimension).jpegData(compressionQuality: quality)
    }
}

// MARK: - 视频帧回调
extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestPixelBuffer = buffer
        bufferLock.unlock()
    }
}

// MARK: - 拍照回调
extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        defer { photoContinuation = nil }
        if let error { photoContinuation?.resume(throwing: error); return }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            photoContinuation?.resume(throwing: NSError(domain: "camera", code: -1))
            return
        }
        photoContinuation?.resume(returning: image.resized(maxDimension: 1536).jpegData(compressionQuality: 0.85) ?? data)
    }
}

// MARK: - 工具
extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

enum WhiteBalance {
    /// 开尔文 → RGB（Tanner Helland 近似），再归一化为设备增益
    static func gains(kelvin: Double, tint: Double, maxGain: Float) -> AVCaptureDevice.WhiteBalanceGains {
        let t = max(2000, min(kelvin, 10000)) / 100
        var r: Double, g: Double, b: Double

        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }

        r = min(max(r, 1), 255) / 255
        g = min(max(g, 1), 255) / 255
        b = min(max(b, 1), 255) / 255

        // tint：洋红/绿偏移，作用在绿通道
        let tintFactor = 1.0 - (tint / 150.0) * 0.25
        g *= tintFactor

        // 归一化到绿=1，并夹到设备允许范围
        let nr = r / g, nb = b / g
        let clamp: (Double) -> Float = { Float(min(max($0, 1.0), Double(maxGain))) }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(nr), greenGain: 1.0, blueGain: clamp(nb))
    }
}
