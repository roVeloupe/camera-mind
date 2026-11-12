import Foundation
import CoreImage
import SwiftUI

@MainActor
final class AISession: ObservableObject {

    @Published var thinking: String = ""
    @Published var rawJSON: String = ""
    @Published var result: AdjustmentParser.Result?
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var baseImage: CIImage?        // AI 看到的那一帧
    @Published var elapsed: Double = 0

    private var task: Task<Void, Never>?

    var hasResult: Bool { result != nil }

    func analyze(imageData: Data, snapshot: CameraSnapshot, client: VisionClient) {
        cancel()
        thinking = ""
        rawJSON = ""
        result = nil
        errorMessage = nil
        isStreaming = true
        baseImage = CIImage(data: imageData, options: [.applyOrientationProperty: true])

        let started = Date()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in client.analyze(imageJPEG: imageData, snapshot: snapshot) {
                    if Task.isCancelled { return }
                    switch event {
                    case .reasoning(let s):
                        self.thinking += s
                        self.elapsed = Date().timeIntervalSince(started)
                    case .toolArgs(let s):
                        // tool call 的 arguments，结构与直接返回的 JSON 一致
                        self.rawJSON += s
                        self.elapsed = Date().timeIntervalSince(started)
                        if let parsed = self.parse(baseCapture: snapshot.capture,
                                                   baseGrade: snapshot.grade) {
                            self.result = parsed
                        }
                    case .content(let s):
                        self.rawJSON += s
                        self.elapsed = Date().timeIntervalSince(started)
                        // 边收边解析，让参数逐步落到界面上
                        if let parsed = self.parse(baseCapture: snapshot.capture,
                                                   baseGrade: snapshot.grade) {
                            self.result = parsed
                        }
                    case .done:
                        break
                    }
                }
                // 收尾：再解析一次，标记完整性
                if let parsed = self.parse(baseCapture: snapshot.capture,
                                           baseGrade: snapshot.grade) {
                    self.result = parsed
                } else if !self.rawJSON.isEmpty || !self.thinking.isEmpty {
                    self.errorMessage = "该模型没有返回参数（不支持工具调用/JSON）。请换一个支持结构化输出的模型"
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isStreaming = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    /// 正文优先；有些"只推理"的模型会把 JSON 塞进 reasoning 通道，所以两条都试。
    private func parse(baseCapture: CaptureParameters,
                       baseGrade: GradeParameters) -> AdjustmentParser.Result? {
        if let r = AdjustmentParser.parse(raw: rawJSON,
                                          baseCapture: baseCapture,
                                          baseGrade: baseGrade) { return r }
        // 思考通道里常有示例 JSON，只在解析出完整对象时才采信
        if let r = AdjustmentParser.parse(raw: thinking,
                                          baseCapture: baseCapture,
                                          baseGrade: baseGrade), r.isComplete {
            return r
        }
        return nil
    }
}
