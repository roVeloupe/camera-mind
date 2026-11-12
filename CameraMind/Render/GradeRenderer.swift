import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// 把 GradeParameters 真正渲染到画面上。
/// 色彩部分走自建 3D LUT（一次生成、按参数缓存），空间部分走 Core Image 滤镜链。
final class GradeRenderer {

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lutCache: [String: Data] = [:]
    private let cubeDimension = 32

    // MARK: 入口
    /// fast = 实时预览：用 16³ LUT、跳过逐帧噪声类滤镜
    func render(_ image: CIImage, with p: GradeParameters,
                showOriginal: Bool = false, fast: Bool = false) -> CIImage {
        if showOriginal { return image }

        var img = image
        img = geometry(img, p)

        if p.exposureEV != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": p.exposureEV])
        }

        if p.temperature != 0 || p.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + p.temperature * 25, y: p.tint)
            ])
        }

        img = applyLUT(img, p, fast: fast)

        if p.clarity != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": 10.0, "inputIntensity": p.clarity * 1.2
            ])
        }
        if p.texture != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": 2.0, "inputIntensity": p.texture * 0.9
            ])
        }

        if p.highlights != 0 || p.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputRadius": 8.0,
                "inputHighlightAmount": 1.0 - p.highlights * 0.7,
                "inputShadowAmount": p.shadows
            ])
        }

        if p.brightness != 0 || p.contrast != 0 || p.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: p.brightness * 0.35,
                kCIInputContrastKey: 1.0 + p.contrast * 0.6,
                kCIInputSaturationKey: 1.0 + p.saturation * 0.8
            ])
        }

        if p.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance])
        }

        if p.dehaze != 0 {
            // Core Image 没有原生去雾，用对比 + 饱和度近似
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + p.dehaze * 0.25,
                kCIInputSaturationKey: 1.0 + p.dehaze * 0.12
            ])
        }

        if p.gamma != 1.0 {
            img = img.applyingFilter("CIGammaAdjust", parameters: ["inputPower": p.gamma])
        }

        if p.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": p.sharpness * 1.5])
        }

        if !fast, p.noiseReduction > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": p.noiseReduction * 0.06,
                "inputSharpness": p.noiseReductionDetail * 0.6
            ])
        }

        if !fast, p.bloom > 0 {
            img = img.applyingFilter("CIBloom", parameters: [
                "inputRadius": 12.0, "inputIntensity": p.bloom
            ])
        }

        if p.vignette != 0 {
            img = img.applyingFilter("CIVignette", parameters: [
                "inputIntensity": p.vignette * 1.6,
                "inputRadius": 1.0 + (1.0 - p.vignetteFeather) * 1.5
            ])
        }

        if !fast, p.grain > 0 {
            img = applyGrain(img, amount: p.grain, size: p.grainSize)
        }

        return img.cropped(to: image.extent)
    }

    // MARK: 几何
    private func geometry(_ image: CIImage, _ p: GradeParameters) -> CIImage {
        var out = image
        let origin = image.extent

        if p.rotate90 != 0 {
            let angle = CGFloat(p.rotate90) * .pi / 2
            out = out.transformed(by: CGAffineTransform(rotationAngle: angle))
            out = out.transformed(by: CGAffineTransform(
                translationX: -out.extent.minX, y: -out.extent.minY))
        }

        if p.straightenAngle != 0 {
            let rad = CGFloat(p.straightenAngle) * .pi / 180
            out = out.transformed(by: CGAffineTransform(rotationAngle: rad))
            // 旋转后裁回原尺寸，避免黑边
            out = out.cropped(to: CGRect(
                x: (out.extent.width - origin.width) / 2,
                y: (out.extent.height - origin.height) / 2,
                width: origin.width,
                height: origin.height))
        }

        if p.perspectiveVertical != 0 || p.perspectiveHorizontal != 0 {
            let e = out.extent
            let dv = CGFloat(p.perspectiveVertical) * e.height * 0.10
            let dh = CGFloat(p.perspectiveHorizontal) * e.width * 0.10
            out = out.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": CIVector(x: e.minX + dh, y: e.maxY - dv),
                "inputTopRight": CIVector(x: e.maxX - dh, y: e.maxY - dv),
                "inputBottomLeft": CIVector(x: e.minX - dh, y: e.minY + dv),
                "inputBottomRight": CIVector(x: e.maxX + dh, y: e.minY + dv)
            ])
        }

        if p.cropZoom > 1.0 {
            let e = out.extent
            let w = e.width / CGFloat(p.cropZoom)
            let h = e.height / CGFloat(p.cropZoom)
            out = out.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
        }

        return out.transformed(by: CGAffineTransform(
            translationX: -out.extent.minX, y: -out.extent.minY))
    }

    // MARK: LUT
    private func applyLUT(_ image: CIImage, _ p: GradeParameters, fast: Bool) -> CIImage {
        let dim = fast ? 16 : cubeDimension
        let key = lutKey(p) + "|" + String(dim)
        let data: Data
        if let cached = lutCache[key] {
            data = cached
        } else {
            data = buildCube(p, dimension: dim)
            if lutCache.count > 16 { lutCache.removeAll(keepingCapacity: true) }
            lutCache[key] = data
        }
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace"),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        filter.setValue(dim, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(space, forKey: "inputColorSpace")
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    private func lutKey(_ p: GradeParameters) -> String {
        String(describing: p)
    }

    private func buildCube(_ p: GradeParameters, dimension: Int) -> Data {
        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var idx = 0

        for bi in 0..<n {
            let b = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let g = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    var (rr, gg, bb) = (r, g, b)

                    // ① 影调映射（逐通道）
                    rr = tone(rr, p); gg = tone(gg, p); bb = tone(bb, p)

                    let lum = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb

                    // ② HSL 分色调整
                    var (h, s, l) = rgb2hsl(rr, gg, bb)
                    if !p.hsl.isEmpty {
                        for band in p.hsl {
                            let d = angularDistance(h * 360, band.center)
                            guard d < 35 else { continue }
                            let w = 1.0 - d / 35.0
                            h = (h * 360 + band.hue * w).truncatingRemainder(dividingBy: 360) / 360
                            if h < 0 { h += 1 }
                            s = clamp01(s * (1 + band.saturation * w))
                            l = clamp01(l * (1 + band.luminance * w))
                        }
                    }
                    if p.hueShift != 0 {
                        h = (h * 360 + p.hueShift).truncatingRemainder(dividingBy: 360) / 360
                        if h < 0 { h += 1 }
                    }
                    (rr, gg, bb) = hsl2rgb(h, s, l)

                    // ③ 分离色调
                    if p.splitShadowSat > 0 {
                        let w = pow(1 - lum, 2) * p.splitShadowSat
                        let (tr, tg, tb) = hueColor(p.splitShadowHue)
                        rr = rr * (1 - w) + tr * w
                        gg = gg * (1 - w) + tg * w
                        bb = bb * (1 - w) + tb * w
                    }
                    if p.splitHighlightSat > 0 {
                        let w = pow(lum, 2) * p.splitHighlightSat
                        let (tr, tg, tb) = hueColor(p.splitHighlightHue)
                        rr = rr * (1 - w) + tr * w
                        gg = gg * (1 - w) + tg * w
                        bb = bb * (1 - w) + tb * w
                    }

                    // ④ 黑白混合
                    if p.monochromeMix > 0 {
                        let m = p.monochromeMix
                        let y = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
                        rr = rr * (1 - m) + y * m
                        gg = gg * (1 - m) + y * m
                        bb = bb * (1 - m) + y * m
                    }

                    cube[idx] = Float(clamp01(rr))
                    cube[idx + 1] = Float(clamp01(gg))
                    cube[idx + 2] = Float(clamp01(bb))
                    cube[idx + 3] = 1.0
                    idx += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 单通道传递函数：高光/阴影/黑白场/三段曲线/褪色/gamma
    private func tone(_ x0: Double, _ p: GradeParameters) -> Double {
        var x = x0
        let lum = x

        // 阴影 / 高光（按亮度加权）
        x += p.shadows * 0.16 * pow(1 - lum, 2)
        x += p.highlights * 0.16 * pow(lum, 2)

        // 黑场 / 白场
        x = x * (1 + p.whites * 0.15) + p.blacks * 0.10

        // 三段曲线
        x += p.curveShadows * 0.12 * (1 - smoothstep(0.0, 0.40, x))
        x += p.curveHighlights * 0.12 * smoothstep(0.55, 1.0, x)
        let midW = 1 - abs(2 * x - 1)
        x += p.curveMidtones * 0.10 * midW

        // 褪色（提黑场、压白场）
        if p.fade > 0 {
            x = x * (1 - 0.28 * p.fade) + 0.10 * p.fade
        }

        // gamma
        if p.gamma != 1.0, x > 0 {
            x = pow(x, 1.0 / p.gamma)
        }
        return clamp01(x)
    }

    // MARK: 颗粒
    private func applyGrain(_ image: CIImage, amount: Double, size: Double) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let extent = image.extent
        var n = noise.cropped(to: extent)
        if size > 0.55 {
            n = n.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": (size - 0.5) * 2.0])
                .cropped(to: extent)
        }
        let gray = n.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let soft = gray.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])
        let alpha = CGFloat(min(max(amount, 0), 1)) * 0.5
        let faded = soft.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
        ])
        return faded.composited(over: image)
    }

    // MARK: 输出
    func makeCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    func makeUIImage(_ image: CIImage) -> UIImage? {
        guard let cg = makeCGImage(image) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 数学工具
private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    guard b != a else { return x >= b ? 1 : 0 }
    let t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

private func angularDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
}

private func hueColor(_ hue: Double) -> (Double, Double, Double) {
    hsl2rgb(hue / 360, 0.75, 0.5)
}

private func rgb2hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let maxV = max(r, g, b), minV = min(r, g, b)
    let l = (maxV + minV) / 2
    guard maxV != minV else { return (0, 0, l) }
    let d = maxV - minV
    let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
    var h: Double
    if maxV == r {
        h = (g - b) / d + (g < b ? 6 : 0)
    } else if maxV == g {
        h = (b - r) / d + 2
    } else {
        h = (r - g) / d + 4
    }
    return (h / 6, s, l)
}

private func hsl2rgb(_ h0: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    let h = h0 < 0 ? h0 + 1 : h0
    guard s != 0 else { return (l, l, l) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    return (hue2rgb(p, q, h + 1.0 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3))
}
