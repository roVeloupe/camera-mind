import Foundation
import SwiftUI

/// 相机状态唯一真源：硬件参数 + 后期参数，改动即持久化。
final class CameraStore: ObservableObject {

    @Published var capture: CaptureParameters {
        didSet { persist() }
    }

    @Published var grade: GradeParameters {
        didSet { persist() }
    }

    /// 对比原图（长按/切换）
    @Published var showOriginal = false

    private let defaults = UserDefaults.standard
    private let captureKey = "cam.capture.v1"
    private let gradeKey = "cam.grade.v1"

    init() {
        capture = Self.decode(CaptureParameters.self, key: captureKey, fallback: .default, defaults: defaults)
        grade = Self.decode(GradeParameters.self, key: gradeKey, fallback: .identity, defaults: defaults)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(capture) { defaults.set(d, forKey: captureKey) }
        if let d = try? JSONEncoder().encode(grade) { defaults.set(d, forKey: gradeKey) }
    }

    func resetGrade() {
        grade = .identity
    }

    func resetAll() {
        capture = .default
        grade = .identity
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String,
                                             fallback: T, defaults: UserDefaults) -> T {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }
}
