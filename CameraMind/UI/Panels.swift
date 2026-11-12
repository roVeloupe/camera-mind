import SwiftUI
import CoreImage

// MARK: - 手动参数面板
struct ManualPanel: View {
    @ObservedObject var store: CameraStore
    @ObservedObject var camera: CameraController
    let capabilities: DeviceCapabilities?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                hardwareSection
                toneSection
                colorSection
                detailSection
                resetSection
            }
            .navigationTitle("参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { camera.apply(store.capture); dismiss() }.bold()
                }
            }
        }
        .onDisappear { camera.apply(store.capture) }
    }

    // MARK: 硬件
    private var hardwareSection: some View {
        Section {
            Toggle("手动曝光", isOn: Binding(
                get: { store.capture.exposureMode == "manual" },
                set: { store.capture.exposureMode = $0 ? "manual" : "auto" }
            ))

            if store.capture.exposureMode == "manual" {
                slider("ISO", $store.capture.iso,
                       (capabilities?.minISO ?? 34)...(min(capabilities?.maxISO ?? 3200, 6400)),
                       format: "%.0f")
                slider("快门 1/x 秒", Binding(
                    get: { 1.0 / max(store.capture.shutterSeconds, 0.0001) },
                    set: { store.capture.shutterSeconds = 1.0 / max($0, 1) }
                ), 8...8000, format: "1/%.0f")
            } else {
                slider("曝光补偿", $store.capture.exposureBias, -2...2, format: "%+.1f EV")
            }

            slider("变焦", $store.capture.zoom, 1...Double(min(capabilities?.maxZoom ?? 5, 10)),
                   format: "%.1fx")

            slider("色温", $store.capture.temperature, 2000...9000, format: "%.0f K")
            slider("色调", $store.capture.tint, -100...100, format: "%+.0f")

            Toggle("锁定白平衡", isOn: Binding(
                get: { store.capture.whiteBalanceMode == "locked" },
                set: { store.capture.whiteBalanceMode = $0 ? "locked" : "auto" }
            ))

            if camera.capabilities?.hasTorch == true {
                slider("补光灯", $store.capture.torch, 0...1, format: "%.2f")
            }
        } header: {
            Text("硬件（实时生效）")
        } footer: {
            Text("ISO 与快门只在手动曝光下有效；白平衡锁定后色温、色调才会下发给设备。")
        }
    }

    // MARK: 影调
    private var toneSection: some View {
        Section("影调") {
            slider("曝光", $store.grade.exposureEV, -2...2, format: "%+.2f")
            slider("对比度", $store.grade.contrast, -1...1, format: "%+.2f")
            slider("高光", $store.grade.highlights, -1...1, format: "%+.2f")
            slider("阴影", $store.grade.shadows, -1...1, format: "%+.2f")
            slider("黑场", $store.grade.blacks, -1...1, format: "%+.2f")
            slider("白场", $store.grade.whites, -1...1, format: "%+.2f")
            slider("清晰度", $store.grade.clarity, -1...1, format: "%+.2f")
            slider("纹理", $store.grade.texture, -1...1, format: "%+.2f")
            slider("去雾", $store.grade.dehaze, -1...1, format: "%+.2f")
            slider("褪色", $store.grade.fade, 0...1, format: "%.2f")
            slider("Gamma", $store.grade.gamma, 0.6...1.8, format: "%.2f")
        }
    }

    // MARK: 色彩
    private var colorSection: some View {
        Section("色彩") {
            slider("色温偏移", $store.grade.temperature, -100...100, format: "%+.0f")
            slider("色调偏移", $store.grade.tint, -100...100, format: "%+.0f")
            slider("自然饱和度", $store.grade.vibrance, -1...1, format: "%+.2f")
            slider("饱和度", $store.grade.saturation, -1...1, format: "%+.2f")
            slider("色相旋转", $store.grade.hueShift, -180...180, format: "%+.0f")
            slider("黑白", $store.grade.monochromeMix, 0...1, format: "%.2f")
            slider("暗部染色", $store.grade.splitShadowSat, 0...1, format: "%.2f")
            slider("高光染色", $store.grade.splitHighlightSat, 0...1, format: "%.2f")
        }
    }

    // MARK: 细节
    private var detailSection: some View {
        Section("细节与光学") {
            slider("锐化", $store.grade.sharpness, 0...1, format: "%.2f")
            slider("降噪", $store.grade.noiseReduction, 0...1, format: "%.2f")
            slider("颗粒", $store.grade.grain, 0...1, format: "%.2f")
            slider("暗角", $store.grade.vignette, -1...1, format: "%+.2f")
            slider("光晕", $store.grade.bloom, 0...1, format: "%.2f")
            slider("校正角度", $store.grade.straightenAngle, -15...15, format: "%+.1f°")
            slider("裁切放大", $store.grade.cropZoom, 1...2, format: "%.2f")
        }
    }

    private var resetSection: some View {
        Section {
            Button("重置后期参数", role: .destructive) { store.resetGrade() }
            Button("恢复全部默认", role: .destructive) {
                store.resetAll()
                camera.apply(store.capture)
            }
        }
    }

    // MARK: 通用滑杆
    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if !editing { camera.apply(store.capture) }
            }
            .tint(.orange)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 推理过程
struct ThinkingView: View {
    @ObservedObject var session: AISession
    let changes: [ParamChange]

    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("思考").tag(0)
                        Text("JSON").tag(1)
                        Text("变更 \(changes.isEmpty ? "" : "\(changes.count)")").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(12)

                    content
                    footer
                }
            }
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 0:
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.thinking.isEmpty
                         ? "模型尚未输出思考内容。若该模型需要显式开启 thinking，请在设置里切换思考模式。"
                         : session.thinking)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .id("bottom")
                }
                .onChange(of: session.thinking) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        case 1:
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.rawJSON.isEmpty ? "等待返回…" : session.rawJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .textSelection(.enabled)
                        .id("bottom")
                }
                .onChange(of: session.rawJSON) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        default:
            List {
                if changes.isEmpty {
                    Text("本次没有产生可显示的变更（参数与当前一致，或解析尚未完成）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(changes) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(c.key).font(.caption.monospaced())
                                Spacer()
                                Text(c.from).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                                Text(c.to).font(.caption2.monospacedDigit().bold()).foregroundStyle(.orange)
                            }
                            if let note = c.note {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack {
            Circle().fill(session.isStreaming ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(session.isStreaming ? "流式接收中 · \(String(format: "%.1f", session.elapsed))s" : "已完成")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text("\(session.rawJSON.count) 字符")
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - 设置
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var probeMessage: String?
    @State private var probing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("接口") {
                    TextField("Base URL", text: $settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: $settings.apiKey)
                    TextField("模型名", text: $settings.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("思考模式") {
                    Picker("启用方式", selection: $settings.thinkingStyle) {
                        Text("Qwen（chat_template_kwargs）").tag("qwen")
                        Text("通用（reasoning_effort）").tag("reasoning")
                        Text("关闭").tag("none")
                    }
                    Text("模型是否输出 reasoning 由服务端决定。选错不会报错，只是思考面板可能为空。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("检查") {
                    Button {
                        probing = true
                        probeMessage = nil
                        Task { @MainActor in
                            let (ok, msg) = await VisionClient.probe(settings.config)
                            probeMessage = (ok ? "✅ " : "❌ ") + msg
                            probing = false
                        }
                    } label: {
                        HStack {
                            Text("测试连通性")
                            Spacer()
                            if probing { ProgressView() }
                        }
                    }
                    .disabled(probing || settings.apiKey.isEmpty)
                    if let probeMessage {
                        Text(probeMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("参数改动会立即生效并自动保存，下次打开相机直接沿用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { settings.save(); dismiss() }
                }
            }
        }
    }
}
