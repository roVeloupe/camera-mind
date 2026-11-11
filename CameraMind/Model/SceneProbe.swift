import AVFoundation
import CoreImage
import Foundation

/// 从画面里提取客观场景指标，随请求一起发给模型，减少它"瞎猜"。
enum SceneProbe {

    static func hints(for image: CIImage) -> [String: String] {
        let size = 64
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return [:] }
        let scale = CGFloat(size) / max(image.extent.width, image.extent.height)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        guard let small = filter.outputImage else { return [:] }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let ctx = CIContext()
        ctx.render(small.cropped(to: extent),
                   toBitmap: &pixels,
                   rowBytes: size * 4,
                   bounds: extent,
                   format: .RGBA8,
                   colorSpace: CGColorSpaceCreateDeviceRGB())

        var lumaSum = 0.0
        var lumaSqSum = 0.0
        var highlightClip = 0
        var shadowClip = 0
        let count = size * size
        var rSum = 0.0, gSum = 0.0, bSum = 0.0

        for i in 0..<count {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumaSum += y
            lumaSqSum += y * y
            rSum += r; gSum += g; bSum += b
            if y > 0.985 { highlightClip += 1 }
            if y < 0.015 { shadowClip += 1 }
        }

        let n = Double(count)
        let mean = lumaSum / n
        let variance = max(0, lumaSqSum / n - mean * mean)
        let std = variance.squareRoot()

        let rAvg = rSum / n, gAvg = gSum / n, bAvg = bSum / n
        let cast: String
        let maxC = max(rAvg, gAvg, bAvg)
        let minC = min(rAvg, gAvg, bAvg)
        if maxC - minC < 0.03 {
            cast = "中性"
        } else if bAvg > rAvg + 0.02 {
            cast = "偏冷（蓝）"
        } else if rAvg > bAvg + 0.02 {
            cast = "偏暖（黄/红）"
        } else if gAvg > rAvg {
            cast = "偏绿"
        } else {
            cast = "中性偏暖"
        }

        return [
            "平均亮度": String(format: "%.3f", mean),
            "亮度标准差": String(format: "%.3f", std),
            "高光溢出比例": String(format: "%.1f%%", Double(highlightClip) / n * 100),
            "暗部死黑比例": String(format: "%.1f%%", Double(shadowClip) / n * 100),
            "色偏": cast,
            "动态范围压力": std > 0.26 ? "高（大光比）" : (std < 0.10 ? "低（平光）" : "中等")
        ]
    }

    static func exif(for device: AVCaptureDevice?) -> [String: String] {
        var out: [String: String] = [:]
        out["时间"] = ISO8601DateFormatter().string(from: Date())
        if let d = device {
            out["镜头"] = d.localizedName
            out["最小ISO"] = String(format: "%.0f", d.activeFormat.minISO)
            out["最大ISO"] = String(format: "%.0f", d.activeFormat.maxISO)
            out["最长快门"] = String(format: "%.1fs", d.activeFormat.maxExposureDuration.seconds)
        }
        return out
    }
}
