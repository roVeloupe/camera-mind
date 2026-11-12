import Foundation

/// 把流式 JSON 增量合并回参数结构。缺失字段沿用当前值，越界值夹到合法区间。
enum AdjustmentParser {

    struct Result: Equatable {
        var capture: CaptureParameters
        var grade: GradeParameters
        var rationale: [String: String]
        var warnings: [String]
        var confidence: Double?
        var isComplete: Bool
    }

    static func parse(raw: String,
                      baseCapture: CaptureParameters,
                      baseGrade: GradeParameters) -> Result? {
        guard let (obj, complete) = StreamingJSON.extract(raw) else { return nil }

        let capture = merge(baseCapture, obj["capture"] as? [String: Any]) ?? baseCapture
        let grade = (merge(baseGrade, obj["grade"] as? [String: Any]) ?? baseGrade).clamped()

        var rationale: [String: String] = [:]
        if let r = obj["rationale"] as? [String: Any] {
            for (k, v) in r { rationale[k] = (v as? String) ?? "\(v)" }
        }

        let warnings = (obj["warnings"] as? [Any])?.compactMap { $0 as? String } ?? []
        let confidence = obj["confidence"] as? Double

        return Result(capture: capture, grade: grade,
                      rationale: rationale, warnings: warnings,
                      confidence: confidence, isComplete: complete)
    }

    /// 把 patch 覆盖到 base 上再解码，天然支持"只返回部分字段"
    private static func merge<T: Codable>(_ base: T, _ patch: [String: Any]?) -> T? {
        guard let patch, !patch.isEmpty else { return base }

        guard let baseData = try? JSONEncoder().encode(base) else { return nil }
        let raw = try? JSONSerialization.jsonObject(with: baseData)
        guard let rawDict = raw, var dict = rawDict as? [String: Any] else { return nil }

        for (k, v) in patch where !(v is NSNull) {
            dict[k] = v
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - 变更清单
struct ParamChange: Identifiable {
    let id: String
    var key: String { id }
    let from: String
    let to: String
    let note: String?
}

extension AdjustmentParser {
    /// 比较两套后期参数，列出真正变化的字段（最多 40 条）
    static func diff(from old: GradeParameters,
                     to new: GradeParameters,
                     rationale: [String: String] = [:]) -> [ParamChange] {
        let a = flatten(old), b = flatten(new)
        var out: [ParamChange] = []
        for (k, v) in b {
            guard let o = a[k], o != v else { continue }
            out.append(ParamChange(id: k, from: o, to: v, note: rationale[k]))
        }
        return out.sorted { $0.id < $1.id }.prefix(40).map { $0 }
    }

    private static func flatten<T: Encodable>(_ value: T) -> [String: String] {
        guard let data = try? JSONEncoder().encode(value),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if v is [Any] { continue }
            if let d = v as? Double { out[k] = String(format: "%.2f", d) }
            else { out[k] = "\(v)" }
        }
        return out
    }
}

// MARK: - 越界保护
extension GradeParameters {
    func clamped() -> GradeParameters {
        var p = self
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

        p.exposureEV = c(p.exposureEV, -3, 3)
        p.brightness = c(p.brightness, -1, 1)
        p.contrast = c(p.contrast, -1, 1)
        p.highlights = c(p.highlights, -1, 1)
        p.shadows = c(p.shadows, -1, 1)
        p.blacks = c(p.blacks, -1, 1)
        p.whites = c(p.whites, -1, 1)
        p.gamma = c(p.gamma, 0.5, 2.0)
        p.clarity = c(p.clarity, -1, 1)
        p.texture = c(p.texture, -1, 1)
        p.dehaze = c(p.dehaze, -1, 1)
        p.fade = c(p.fade, 0, 1)
        p.curveShadows = c(p.curveShadows, -1, 1)
        p.curveMidtones = c(p.curveMidtones, -1, 1)
        p.curveHighlights = c(p.curveHighlights, -1, 1)

        p.temperature = c(p.temperature, -100, 100)
        p.tint = c(p.tint, -100, 100)
        p.vibrance = c(p.vibrance, -1, 1)
        p.saturation = c(p.saturation, -1, 1)
        p.hueShift = c(p.hueShift, -180, 180)
        p.monochromeMix = c(p.monochromeMix, 0, 1)
        p.splitShadowHue = c(p.splitShadowHue, 0, 360)
        p.splitShadowSat = c(p.splitShadowSat, 0, 1)
        p.splitHighlightHue = c(p.splitHighlightHue, 0, 360)
        p.splitHighlightSat = c(p.splitHighlightSat, 0, 1)

        p.sharpness = c(p.sharpness, 0, 1)
        p.noiseReduction = c(p.noiseReduction, 0, 1)
        p.noiseReductionDetail = c(p.noiseReductionDetail, 0, 1)
        p.grain = c(p.grain, 0, 1)
        p.grainSize = c(p.grainSize, 0, 1)

        p.vignette = c(p.vignette, -1, 1)
        p.vignetteFeather = c(p.vignetteFeather, 0, 1)
        p.bloom = c(p.bloom, 0, 1)
        p.halation = c(p.halation, 0, 1)
        p.chromaticAberration = c(p.chromaticAberration, -1, 1)

        p.straightenAngle = c(p.straightenAngle, -45, 45)
        p.cropZoom = c(p.cropZoom, 1, 2)
        p.perspectiveVertical = c(p.perspectiveVertical, -1, 1)
        p.perspectiveHorizontal = c(p.perspectiveHorizontal, -1, 1)
        p.rotate90 = ((p.rotate90 % 4) + 4) % 4
        p.styleStrength = c(p.styleStrength, 0, 1)

        if p.hsl.count != 8 {
            p.hsl = HSLBand.defaultBands
        }
        for i in p.hsl.indices {
            p.hsl[i].center = c(p.hsl[i].center, 0, 360)
            p.hsl[i].hue = c(p.hsl[i].hue, -30, 30)
            p.hsl[i].saturation = c(p.hsl[i].saturation, -1, 1)
            p.hsl[i].luminance = c(p.hsl[i].luminance, -1, 1)
        }
        return p
    }
}
