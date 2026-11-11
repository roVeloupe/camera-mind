import SwiftUI
import CoreImage

// MARK: - 思考面板
struct ThinkingView: View {
    @ObservedObject var session: AISession
    @Environment(\.dismiss) private var dismiss
    @State private var showJSON = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $showJSON) {
                        Text("思考").tag(false)
                        Text("JSON").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(12)

                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                if showJSON {
                                    Text(session.rawJSON.isEmpty ? "等待返回…" : session.rawJSON)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.green.opacity(0.9))
                                } else {
                                    Text(session.thinking.isEmpty ? "模型尚未输出思考内容。部分模型需显式开启 thinking 参数。" : session.thinking)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.88))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .id("bottom")
                        }
                        .onChange(of: session.thinking) { _, _ in
                            withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .onChange(of: session.rawJSON) { _, _ in
                            withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }

                    HStack {
                        Circle()
                            .fill(session.isStreaming ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(session.isStreaming ? "流式接收中 · \(String(format: "%.1f", session.elapsed))s" : "已完成")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text("\(session.thinking.count) 字")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("推理过程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 结果面板
struct ResultView: View {
    let base: CIImage?
    let result: AdjustmentParser.Result
    let baseGrade: GradeParameters
    let onApply: () -> Void
    let onClose: () -> Void

    @State private var showOriginal = false
    @State private var rendered: UIImage?

    private let renderer = GradeRenderer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    imageCard
                    if let rationale = headline {
                        Text(rationale)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    diffSection
                    if !result.warnings.isEmpty {
                        warningSection
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI 方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用", action: onApply).bold()
                }
            }
        }
        .onAppear(perform: renderPreview)
        .onChange(of: result.grade) { _, _ in renderPreview() }
    }

    private var headline: String? {
        let r = result.rationale
        let priority = ["exposureEV", "contrast", "highlights", "shadows",
                        "temperature", "tint", "vibrance", "clarity", "style"]
        for key in priority {
            if let v = r[key] { return v }
        }
        return r.values.first
    }

    private var imageCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let rendered {
                    Image(uiImage: rendered).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Color.black.opacity(0.08))
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay(ProgressView())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                showOriginal.toggle()
                renderPreview()
            } label: {
                Label(showOriginal ? "看效果" : "看原图",
                      systemImage: showOriginal ? "wand.and.stars" : "photo")
                    .font(.caption2.bold())
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(10)
        }
        .padding(.horizontal, 16)
    }

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("参数变更 · \(changes.count) 项")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 8)

            ForEach(changes, id: \.key) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.key)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(item.from)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(item.to)
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(.blue)
                    }
                    if let note = result.rationale[item.key] {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 9)

                Divider().padding(.leading, 16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("现场提示", systemImage: "exclamationmark.triangle")
                .font(.footnote.bold())
                .foregroundStyle(.orange)
            ForEach(result.warnings, id: \.self) { w in
                Text("· \(w)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private func renderPreview() {
        guard let base else { return }
        let params = showOriginal ? GradeParameters.identity : result.grade
        rendered = renderer.makeUIImage(renderer.render(base, with: params))
    }

    // MARK: diff
    private struct Change { let key: String; let from: String; let to: String }

    private var changes: [Change] {
        let a = dict(baseGrade), b = dict(result.grade)
        var out: [Change] = []
        for (k, v) in b {
            let old = a[k] ?? "-"
            if old != v {
                out.append(Change(key: k, from: fmt(old), to: fmt(v)))
            }
        }
        return out.sorted { $0.key < $1.key }
    }

    private func dict<T: Encodable>(_ value: T) -> [String: String] {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let arr = v as? [Any] { continue }
            out[k] = "\(v)"
        }
        return out
    }

    private func fmt(_ s: String) -> String {
        guard let d = Double(s) else { return s }
        return String(format: "%.2f", d)
    }
}

// MARK: - 当前参数
struct ParamsView: View {
    let capture: CaptureParameters
    let grade: GradeParameters
    let capabilities: DeviceCapabilities?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("硬件") {
                    row("镜头", capture.lens)
                    row("变焦", String(format: "%.1f×", capture.zoom))
                    row("曝光模式", capture.exposureMode)
                    row("ISO", String(format: "%.0f", capture.iso))
                    row("快门", String(format: "1/%.0fs", 1 / max(capture.shutterSeconds, 0.0001)))
                    row("曝光补偿", String(format: "%+.1f EV", capture.exposureBias))
                    row("对焦", capture.focusMode)
                    row("白平衡", "\(capture.whiteBalanceMode) · \(Int(capture.temperature))K")
                }
                if let c = capabilities {
                    Section("设备能力") {
                        row("镜头组", c.lenses.joined(separator: " / "))
                        row("ISO", "\(Int(c.minISO)) – \(Int(c.maxISO))")
                        row("最大变焦", String(format: "%.1f×", c.maxZoom))
                    }
                }
                Section("后期") {
                    row("曝光", String(format: "%+.2f", grade.exposureEV))
                    row("对比度", String(format: "%+.2f", grade.contrast))
                    row("高光", String(format: "%+.2f", grade.highlights))
                    row("阴影", String(format: "%+.2f", grade.shadows))
                    row("饱和度", String(format: "%+.2f", grade.saturation))
                    row("自然饱和度", String(format: "%+.2f", grade.vibrance))
                    row("清晰度", String(format: "%+.2f", grade.clarity))
                    row("风格", "\(grade.style) · \(String(format: "%.2f", grade.styleStrength))")
                }
            }
            .navigationTitle("当前参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.footnote)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Text(probeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("需支持 OpenAI 兼容的 /chat/completions 与图片输入。思考内容读取 reasoning_content / reasoning / thinking 字段；若模型不支持，思考面板会为空，但 JSON 仍会流式解析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { settings.save(); dismiss() } }
            }
        }
    }
}
