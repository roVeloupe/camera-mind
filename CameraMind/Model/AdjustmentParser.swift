import Foundation

/// 把流式 JSON 增量合并回参数结构。缺失字段沿用当前值，越界值夹到合法区间。
enum AdjustmentParser {

    struct Result {
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
        let enc = JSONEncoder()
        guard var dict = (try? enc.encode(base))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else {
            return nil
        }
        for (k, v) in patch { dict[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
