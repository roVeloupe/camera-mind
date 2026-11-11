import Foundation

// MARK: - 硬件参数（AVFoundation 可直接生效）
struct CaptureParameters: Codable, Equatable {
    var lens: String = "wide"          // ultraWide | wide | tele
    var zoom: Double = 1.0             // 1.0 ... maxZoom
    var iso: Double = 100              // device minISO ... maxISO
    var shutterSeconds: Double = 1.0 / 120.0   // minExposureDuration ... maxExposureDuration
    var exposureMode: String = "auto"  // auto | manual
    var exposureBias: Double = 0       // -8 ... +8 EV（auto 模式下生效）
    var focusMode: String = "auto"     // auto | locked
    var lensPosition: Double = 0.5     // 0.0(无穷远) ... 1.0(最近)
    var whiteBalanceMode: String = "auto"  // auto | locked
    var temperature: Double = 5200     // 2000 ... 10000 K
    var tint: Double = 0               // -150 ... +150
    var torch: Double = 0              // 0 ... 1
    var hdr: Bool = true
    var stabilization: String = "standard"  // off | standard | cinematic
    var aspect: String = "4:3"         // 4:3 | 16:9 | 1:1
}

// MARK: - 后期参数（Core Image 渲染链）
struct HSLBand: Codable, Equatable {
    var center: Double = 0       // 目标色相中心 0-360
    var hue: Double = 0          // -30 ... +30 度
    var saturation: Double = 0   // -1 ... +1
    var luminance: Double = 0    // -1 ... +1
}

struct GradeParameters: Codable, Equatable {
    // ① 影调
    var exposureEV: Double = 0        // -3 ... +3
    var brightness: Double = 0        // -1 ... +1
    var contrast: Double = 0          // -1 ... +1
    var highlights: Double = 0        // -1 ... +1（负=压高光）
    var shadows: Double = 0           // -1 ... +1（正=提暗部）
    var blacks: Double = 0            // -1 ... +1（负=黑场更深）
    var whites: Double = 0            // -1 ... +1（正=白场更亮）
    var gamma: Double = 1.0           // 0.5 ... 2.0
    var clarity: Double = 0           // -1 ... +1（中频局部对比）
    var texture: Double = 0           // -1 ... +1（高频纹理）
    var dehaze: Double = 0            // -1 ... +1
    var fade: Double = 0              // 0 ... 1（褪色/胶片感）
    var curveShadows: Double = 0      // -1 ... +1
    var curveMidtones: Double = 0     // -1 ... +1
    var curveHighlights: Double = 0   // -1 ... +1

    // ② 色彩
    var temperature: Double = 0       // -100 ... +100（冷↔暖）
    var tint: Double = 0              // -100 ... +100（绿↔洋红）
    var vibrance: Double = 0          // -1 ... +1（保护肤色）
    var saturation: Double = 0        // -1 ... +1
    var hueShift: Double = 0          // -180 ... +180
    var monochromeMix: Double = 0     // 0 ... 1
    var splitShadowHue: Double = 0    // 0 ... 360
    var splitShadowSat: Double = 0    // 0 ... 1
    var splitHighlightHue: Double = 0 // 0 ... 360
    var splitHighlightSat: Double = 0 // 0 ... 1
    var hsl: [HSLBand] = HSLBand.defaultBands

    // ③ 细节
    var sharpness: Double = 0         // 0 ... 1
    var noiseReduction: Double = 0    // 0 ... 1
    var noiseReductionDetail: Double = 0.5  // 0 ... 1（保留细节）
    var grain: Double = 0             // 0 ... 1
    var grainSize: Double = 0.5       // 0 ... 1

    // ④ 光学与光线
    var vignette: Double = 0          // -1 ... +1
    var vignetteFeather: Double = 0.5 // 0 ... 1
    var bloom: Double = 0             // 0 ... 1
    var halation: Double = 0          // 0 ... 1（高光边缘红光晕）
    var chromaticAberration: Double = 0 // -1 ... +1（校正量）

    // ⑤ 几何
    var straightenAngle: Double = 0   // -45 ... +45 度
    var cropZoom: Double = 1.0        // 1.0 ... 2.0
    var perspectiveVertical: Double = 0   // -1 ... +1（建筑透视）
    var perspectiveHorizontal: Double = 0 // -1 ... +1
    var rotate90: Int = 0             // 0 | 1 | 2 | 3

    // ⑥ 风格
    var style: String = "natural"     // natural | cinematic | portrait | landscape | street | film | moody | vivid
    var styleStrength: Double = 0     // 0 ... 1
}

extension HSLBand {
    static let defaultBands: [HSLBand] = [
        HSLBand(center: 0), HSLBand(center: 30), HSLBand(center: 60), HSLBand(center: 120),
        HSLBand(center: 180), HSLBand(center: 240), HSLBand(center: 300), HSLBand(center: 330)
    ]
}

// MARK: - 设备能力（发给模型，让它输出的数值合法）
struct DeviceCapabilities: Codable {
    var lenses: [String]
    var minISO: Double
    var maxISO: Double
    var minShutterSeconds: Double
    var maxShutterSeconds: Double
    var maxZoom: Double
    var maxWhiteBalanceGain: Double
    var hasTorch: Bool
    var supportsHDR: Bool
    var sensorWidth: Int
    var sensorHeight: Int
}

// MARK: - 快照（一次请求的完整上下文）
struct CameraSnapshot: Codable {
    var capture: CaptureParameters
    var grade: GradeParameters
    var capabilities: DeviceCapabilities
    var exifSummary: [String: String]
    var sceneHints: [String: String]
}

// MARK: - 模型返回结构
struct AIAdjustment: Codable {
    var analysis: String?
    var capture: CaptureParameters?
    var grade: GradeParameters?
    var rationale: [String: String]?
    var confidence: Double?
    var warnings: [String]?
}

// MARK: - 默认值
extension CaptureParameters {
    static let `default` = CaptureParameters()
}
extension GradeParameters {
    static let identity = GradeParameters()
}
