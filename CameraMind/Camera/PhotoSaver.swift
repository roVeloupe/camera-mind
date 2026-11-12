import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreLocation

/// 保存成片：在相机原始 metadata 上覆盖尺寸/方向/位置/调色，再写成 HEIC。
/// 走 PHAssetCreationRequest.addResource，避免 UIImageWriteToSavedPhotosAlbum 把 EXIF 洗掉。
enum PhotoSaver {

    static func save(image: UIImage,
                     metadata: [String: Any],
                     grade: GradeParameters,
                     location: CLLocation?) async throws {
        guard let cg = image.cgImage else {
            throw NSError(domain: "photo", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "图片无法编码"])
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "photo", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"])
        }

        var meta = metadata

        // EXIF：尺寸按调色后的像素写，方向已经摆正
        var exif = (meta[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cg.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cg.height
        if exif[kCGImagePropertyExifDateTimeOriginal as String] == nil {
            exif[kCGImagePropertyExifDateTimeOriginal as String] = timestamp()
        }
        // 把这次用的调色参数写进 UserComment，方便以后回溯
        exif[kCGImagePropertyExifUserComment as String] = gradeJSON(grade)
        meta[kCGImagePropertyExifDictionary as String] = exif
        meta[kCGImagePropertyOrientation as String] = 1

        if let location {
            meta[kCGImagePropertyGPSDictionary as String] = gps(location)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw NSError(domain: "photo", code: -12,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 HEIC"])
        }
        CGImageDestinationAddImage(dest, cg, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "photo", code: -13,
                          userInfo: [NSLocalizedDescriptionKey: "HEIC 写入失败"])
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 工具
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func gradeJSON(_ grade: GradeParameters) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(grade),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func gps(_ location: CLLocation) -> [String: Any] {
        var dict: [String: Any] = [:]
        let coord = location.coordinate
        dict[kCGImagePropertyGPSLatitude as String] = abs(coord.latitude)
        dict[kCGImagePropertyGPSLatitudeRef as String] = coord.latitude >= 0 ? "N" : "S"
        dict[kCGImagePropertyGPSLongitude as String] = abs(coord.longitude)
        dict[kCGImagePropertyGPSLongitudeRef as String] = coord.longitude >= 0 ? "E" : "W"
        dict[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
        dict[kCGImagePropertyGPSAltitudeRef as String] = location.altitude >= 0 ? 0 : 1
        dict[kCGImagePropertyGPSTimeStamp as String] = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: location.timestamp)
        }()
        dict[kCGImagePropertyGPSDateStamp as String] = {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: location.timestamp)
        }()
        dict[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
        return dict
    }
}
