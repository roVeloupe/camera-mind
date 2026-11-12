import AVFoundation
import CoreImage
import UIKit

final class CameraController: NSObject, ObservableObject {

    // MARK: 对外状态
    @Published private(set) var isRunning = false
    @Published private(set) var capabilities: DeviceCapabilities?
    @Published var captureParams = CaptureParameters.default
    @Published var lastError: String?

    /// 每帧回调（实时预览调色用）
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// 当前缩放（与 Apple 一致：虚拟设备直接改 videoZoomFactor，系统负责切镜头）
    @Published private(set) var zoom: Double = 1.0
    @Published private(set) var minZoom: Double = 1.0
    @Published private(set) var maxZoom: Double = 5.0
    @Published private(set) var switchOvers: [Double] = []

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<(Data, [String: Any]), Error>?
    private let ciContext = CIContext()

    // 最新一帧（用于 AI 分析，比拍照快）
    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    // MARK: 启动
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            boot()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.boot()
                    } else {
                        self.lastError = "相机权限被拒绝，请到「设置 → AI 相机」里打开"
                    }
                }
            }
        default:
            lastError = "相机权限被拒绝，请到「设置 → AI 相机」里打开"
        }
    }

    private func boot() {
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
        publishZoomRange(for: dev)
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

    private func publishZoomRange(for dev: AVCaptureDevice) {
        let lo = Double(dev.minAvailableVideoZoomFactor)
        let hi = Double(min(dev.maxAvailableVideoZoomFactor, 15))
        let overs = dev.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
        DispatchQueue.main.async {
            self.minZoom = lo
            self.maxZoom = hi
            self.switchOvers = overs
            self.zoom = Double(dev.videoZoomFactor)
        }
    }

    /// 当前镜头的人话描述（Apple 用 0.5×/1×/3×，这里给中文名）
    var lensDescription: String {
        if zoom < 0.99 { return "超广角" }
        if let first = switchOvers.first, zoom >= first { return "长焦" }
        return "广角（主摄）"
    }

    /// 捏合缩放：直接改虚拟设备的 videoZoomFactor，物理镜头由系统切换
    func setZoom(_ value: Double) {
        guard let dev = device, session.isRunning else { return }
        let clamped = min(max(value, minZoom), maxZoom)
        do { try dev.lockForConfiguration() } catch { return }
        dev.videoZoomFactor = CGFloat(clamped)
        dev.unlockForConfiguration()

        zoom = clamped
        captureParams.zoom = clamped
    }

    // MARK: 应用硬件参数
    func apply(_ p: CaptureParameters) {
        // session 停止时写参数会抛 NSException（Swift 接不住，直接 abort）
        guard let dev = device, session.isRunning else { return }
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

        // 白平衡：一律自动。硬件锁定要传 DeviceWhiteBalanceGains，
        // 越界时 AVFoundation 抛 ObjC 异常（Swift 无法 catch），改由后期 CITemperatureAndTint 完成。
        if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
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

    /// 给 AI 的帧：长边缩到原图的 1/4（4032 → 约 1008），再压到 0.7。
    /// 只影响上传，不影响成片。
    func captureData() async throws -> Data {
        let (original, _) = try await captureRawPhoto()
        guard let image = UIImage(data: original) else { return original }
        let longSide = max(image.size.width, image.size.height)
        let target = min(max(longSide / 4.0, 384), 1024)
        return image.resized(maxDimension: target).jpegData(compressionQuality: 0.7) ?? original
    }

    /// 快门：原图直出，不缩放、不二次压缩，交给调用方套调色后保存。
    func shoot() async throws -> (UIImage, [String: Any]) {
        let (data, metadata) = try await captureRawPhoto()
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "camera", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "照片解码失败"])
        }
        return (image, metadata)
    }

    /// 原图数据（系统直接给的 HEIC/JPEG，未经我们重编码）+ 相机原始元数据
    private func captureRawPhoto() async throws -> (Data, [String: Any]) {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, [String: Any]), Error>) in
            self.photoContinuation = cont
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func currentPixelBuffer() -> CVPixelBuffer? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return latestPixelBuffer
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
        onFrame?(buffer)
    }
}

// MARK: - 拍照回调
extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        defer { photoContinuation = nil }
        if let error { photoContinuation?.resume(throwing: error); return }
        guard let data = photo.fileDataRepresentation() else {
            photoContinuation?.resume(throwing: NSError(domain: "camera", code: -1))
            return
        }
        photoContinuation?.resume(returning: (data, photo.metadata))
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
