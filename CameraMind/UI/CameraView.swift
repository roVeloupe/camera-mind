import SwiftUI
import AVFoundation
import CoreImage

// MARK: - 设置
final class AppSettings: ObservableObject {
    @Published var baseURL: String
    @Published var apiKey: String
    @Published var model: String
    @Published var thinkingStyle: String

    private let d = UserDefaults.standard

    init() {
        baseURL = d.string(forKey: "api.baseURL") ?? "http://cheap-host1.cheapyun.com:20033/v1"
        apiKey = d.string(forKey: "api.key") ?? ""
        model = d.string(forKey: "api.model") ?? "hy4free"
        thinkingStyle = d.string(forKey: "api.thinking") ?? "none"
    }

    func save() {
        d.set(baseURL, forKey: "api.baseURL")
        d.set(apiKey, forKey: "api.key")
        d.set(model, forKey: "api.model")
        d.set(thinkingStyle, forKey: "api.thinking")
    }

    var config: VisionClient.Config {
        VisionClient.Config(baseURL: baseURL, apiKey: apiKey, model: model,
                            thinkingStyle: thinkingStyle)
    }
}

// MARK: - 预览层
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - 主界面
struct CameraView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ai = AISession()
    @StateObject private var settings = AppSettings()

    @State private var appliedGrade = GradeParameters.identity
    @State private var showSettings = false
    @State private var showThinking = false
    @State private var showResult = false
    @State private var showParams = false
    @State private var isCapturing = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            // 顶部 / 底部渐变
            VStack {
                LinearGradient(colors: [.black.opacity(0.65), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                if ai.isStreaming { streamingStrip }
                bottomBar
            }

            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 100)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            if !camera.isRunning, let err = camera.lastError {
                VStack(spacing: 14) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 40, weight: .light))
                    Text(err)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(28)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
                .padding(40)
            }
        }
        .statusBarHidden()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings) }
        .sheet(isPresented: $showThinking) { ThinkingView(session: ai) }
        .sheet(isPresented: $showResult) {
            if let result = ai.result {
                ResultView(base: ai.baseImage,
                           result: result,
                           baseGrade: appliedGrade,
                           onApply: {
                               camera.apply(result.capture)
                               appliedGrade = result.grade
                               showResult = false
                               flash("参数已应用")
                           },
                           onClose: { showResult = false })
            }
        }
        .sheet(isPresented: $showParams) {
            ParamsView(capture: camera.captureParams,
                       grade: appliedGrade,
                       capabilities: camera.capabilities)
        }
        .onChange(of: ai.result?.isComplete) { _, complete in
            if complete == true, !showResult { showResult = true }
        }
        .onChange(of: ai.errorMessage) { _, msg in
            if let msg { flash(msg) }
        }
        .onChange(of: camera.lastError) { _, msg in
            if let msg { flash(msg) }
        }
    }

    // MARK: 顶部
    private var topBar: some View {
        HStack(spacing: 14) {
            Button { showParams = true } label: {
                Label(paramSummary, systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
            }

            Spacer()

            if ai.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().tint(.white).scaleEffect(0.7)
                    Text("思考中 \(String(format: "%.1f", ai.elapsed))s")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.35), in: Capsule())
                .onTapGesture { showThinking = true }
            }

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var paramSummary: String {
        let p = camera.captureParams
        if p.exposureMode == "manual" {
            return String(format: "ISO%.0f · 1/%.0fs", p.iso, 1 / max(p.shutterSeconds, 0.0001))
        }
        return String(format: "EV%+.1f · %.1f×", p.exposureBias, p.zoom)
    }

    // MARK: 流式条
    private var streamingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ai.thinking.isEmpty ? "正在读取画面…" : "思考中")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("展开") { showThinking = true }
                    .font(.caption2)
                    .foregroundStyle(.white)
            }
            Text(String(ai.thinking.suffix(160)))
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: 底部
    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button { showParams = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "camera.aperture")
                    Text("参数").font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 60)
            }

            Spacer()

            // AI 主键
            Button(action: askAI) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.white, .white.opacity(0.82)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 82, height: 82)
                        .shadow(color: .white.opacity(0.25), radius: 18)
                    VStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .semibold))
                        Text("AI").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    if isCapturing {
                        Circle().stroke(.white.opacity(0.5), lineWidth: 3)
                            .frame(width: 92, height: 92)
                    }
                }
            }
            .disabled(ai.isStreaming || isCapturing)
            .opacity(ai.isStreaming ? 0.55 : 1)

            Spacer()

            Button {
                showThinking = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text("思考").font(.caption2)
                }
                .foregroundStyle(.white.opacity(ai.thinking.isEmpty ? 0.35 : 0.9))
                .frame(width: 60)
            }
            .disabled(ai.thinking.isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 26)
    }

    // MARK: 触发
    private func askAI() {
        guard !ai.isStreaming else { return }
        isCapturing = true
        Task { @MainActor in
            do {
                let data = try await camera.captureData()
                let ci = CIImage(data: data, options: [.applyOrientationProperty: true])
                let snap = CameraSnapshot(
                    capture: camera.captureParams,
                    grade: appliedGrade,
                    capabilities: camera.capabilities ?? .fallback,
                    exifSummary: SceneProbe.exif(for: nil),
                    sceneHints: ci.map { SceneProbe.hints(for: $0) } ?? [:]
                )
                ai.analyze(imageData: data, snapshot: snap, client: VisionClient(config: settings.config))
                showThinking = true
            } catch {
                flash(error.localizedDescription)
            }
            isCapturing = false
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toast = nil }
        }
    }
}

extension DeviceCapabilities {
    static let fallback = DeviceCapabilities(
        lenses: ["wide"], minISO: 34, maxISO: 3200,
        minShutterSeconds: 1.0 / 8000, maxShutterSeconds: 1.0,
        maxZoom: 15, maxWhiteBalanceGain: 4,
        hasTorch: true, supportsHDR: true,
        sensorWidth: 4032, sensorHeight: 3024)
}
