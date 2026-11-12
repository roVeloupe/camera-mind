import SwiftUI
import AVFoundation
import CoreImage
import UIKit

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

// MARK: - 主界面
struct CameraView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ai = AISession()
    @StateObject private var settings = AppSettings()
    @StateObject private var store = CameraStore()
    @StateObject private var location = LocationProvider()

    @State private var showSettings = false
    @State private var showThinking = false
    @State private var showManual = false
    @State private var isCapturing = false
    @State private var isShooting = false
    @State private var toast: String?
    @State private var baseline: GradeParameters = .identity
    @State private var changes: [ParamChange] = []

    private let renderer = GradeRenderer()
    @Environment(\.scenePhase) private var scenePhase

    /// 有弹层盖住取景，或 App 不在前台时，停掉采集省电
    private var cameraShouldRun: Bool {
        !showThinking && !showManual && !showSettings && scenePhase == .active
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalCameraPreview(controller: camera, grade: store.grade, showOriginal: store.showOriginal)
                .ignoresSafeArea()

            VStack {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 230)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                if ai.isStreaming { streamingStrip }
                zoomBadge
                bottomBar
            }

            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 96)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            if !camera.isRunning, let err = camera.lastError {
                permissionCard(err)
            }
        }
        .statusBarHidden()
        .onAppear { camera.start(); location.start() }
        .onDisappear { camera.stop(); location.stop() }
        .onChange(of: camera.isRunning) { _, running in
            // 每次恢复取景都重新下发一次，避免系统重置自动曝光
            if running { camera.apply(store.capture) }
        }
        .onChange(of: cameraShouldRun) { _, shouldRun in
            if shouldRun { camera.start(); location.start() }
            else { camera.stop(); location.stop() }
        }
        .onChange(of: camera.zoom) { _, z in
            store.capture.zoom = z
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if cameraShouldRun { camera.start() }
            } else {
                camera.stop()
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings) }
        .sheet(isPresented: $showManual) {
            ManualPanel(store: store, camera: camera, capabilities: camera.capabilities)
        }
        .sheet(isPresented: $showThinking) {
            ThinkingView(session: ai, changes: changes)
        }
        .onChange(of: ai.result) { _, result in
            guard let result else { return }
            // 边收边套：预览立刻能看到效果
            store.grade = result.grade
            if result.isComplete {
                store.capture = result.capture
                camera.apply(result.capture)
                changes = AdjustmentParser.diff(from: baseline, to: result.grade,
                                                rationale: result.rationale ?? [:])
                flash("已应用到相机 · \(changes.count) 项调色")
            }
        }
        .onChange(of: ai.errorMessage) { _, msg in
            if let msg { flash(msg) }
        }
        .onChange(of: camera.lastError) { _, msg in
            if let msg { flash(msg) }
        }
    }

    // MARK: 顶栏
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { showManual = true } label: {
                Label(paramSummary, systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(.black.opacity(0.38), in: Capsule())
                    .foregroundStyle(.white)
            }

            Spacer()

            if ai.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().tint(.white).scaleEffect(0.65)
                    Text("\(String(format: "%.1f", ai.elapsed))s")
                        .font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.38), in: Capsule())
                .foregroundStyle(.white)
                .onTapGesture { showThinking = true }
            }

            Button {
                store.showOriginal.toggle()
            } label: {
                Image(systemName: store.showOriginal ? "eye.slash" : "eye")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.38), in: Circle())
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.38), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var paramSummary: String {
        let p = store.capture
        if p.exposureMode == "manual" {
            return String(format: "ISO%.0f · 1/%.0f", p.iso, 1 / max(p.shutterSeconds, 0.0001))
        }
        return String(format: "EV%+.1f · %.1fx", p.exposureBias, p.zoom)
    }

    // MARK: 流式条
    private var streamingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ai.thinking.isEmpty ? "正在读取画面…" : "AI 思考中")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Button("展开") { showThinking = true }
                    .font(.caption2).foregroundStyle(.white)
            }
            Text(String(ai.thinking.suffix(150)))
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var zoomBadge: some View {
        Button { camera.setZoom(1.0) } label: {
            HStack(spacing: 6) {
                Text(String(format: "%.1f×", camera.zoom))
                    .font(.caption.bold().monospacedDigit())
                Text(camera.lensDescription)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
        }
        .padding(.bottom, 4)
    }

    // MARK: 底栏
    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button { showManual = true } label: {
                VStack(spacing: 5) {
                    Image(systemName: "camera.aperture").font(.system(size: 20))
                    Text("手动").font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 62)
            }

            Spacer()

            // AI：只截帧 + 下发参数，不拍照
            Button(action: askAI) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.white, .white.opacity(0.8)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 72, height: 72)
                        .shadow(color: .white.opacity(0.22), radius: 14)
                    VStack(spacing: 1) {
                        Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold))
                        Text("AI").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    if isCapturing {
                        Circle().stroke(.white.opacity(0.55), lineWidth: 3)
                            .frame(width: 82, height: 82)
                    }
                }
            }
            .disabled(ai.isStreaming || isCapturing || isShooting)
            .opacity(ai.isStreaming ? 0.5 : 1)

            Spacer()

            // 快门：用当前参数拍一张并保存
            Button(action: shoot) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 66, height: 66)
                    Circle().fill(.white).frame(width: 54, height: 54)
                    if isShooting {
                        ProgressView().tint(.black)
                    }
                }
            }
            .disabled(isShooting || ai.isStreaming)
            .frame(width: 62)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 26)
    }

    private func permissionCard(_ err: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 38, weight: .light))
            Text(err).font(.callout).multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .padding(40)
    }

    // MARK: 动作
    private func askAI() {
        guard !ai.isStreaming else { return }
        isCapturing = true
        baseline = store.grade
        changes = []

        Task { @MainActor in
            do {
                let data = try await camera.captureData()
                let ci = CIImage(data: data, options: [.applyOrientationProperty: true])
                var exif = SceneProbe.exif(for: nil)
                exif["当前镜头"] = camera.lensDescription
                exif["变焦倍率"] = String(format: "%.2f×", camera.zoom)
                if let loc = location.location {
                    exif["GPS"] = String(format: "%.5f, %.5f (±%.0fm)",
                                         loc.coordinate.latitude,
                                         loc.coordinate.longitude,
                                         loc.horizontalAccuracy)
                } else {
                    exif["GPS"] = "未获取"
                }
                let snapshot = CameraSnapshot(
                    capture: store.capture,
                    grade: store.grade,
                    capabilities: camera.capabilities ?? .fallback,
                    exifSummary: exif,
                    sceneHints: ci.map { SceneProbe.hints(for: $0) } ?? [:]
                )
                ai.analyze(imageData: data, snapshot: snapshot,
                           client: VisionClient(config: settings.config))
                showThinking = true
            } catch {
                flash(error.localizedDescription)
            }
            isCapturing = false
        }
    }

    private func shoot() {
        isShooting = true
        let grade = store.grade
        Task { @MainActor in
            do {
                let (image, metadata) = try await camera.shoot()
                // UIImage 已带上方向信息，避免再转一次
                guard let ci = CIImage(image: image,
                                       options: [.applyOrientationProperty: true]) else {
                    throw NSError(domain: "photo", code: -1)
                }
                let out = renderer.render(ci, with: grade)
                guard let ui = renderer.makeUIImage(out) else {
                    throw NSError(domain: "photo", code: -2)
                }
                try await PhotoSaver.save(image: ui,
                                          metadata: metadata,
                                          grade: grade,
                                          location: location.location)
                flash("已保存 HEIC 到相册")
            } catch {
                flash(error.localizedDescription)
            }
            isShooting = false
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
