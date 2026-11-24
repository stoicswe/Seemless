import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// Turns a scanout IOSurface into an image file. Alpha is ignored: scanouts
/// are x8r8g8b8, so the fourth byte is undefined.
public enum DisplayImage {
    public enum ImageError: Error, CustomStringConvertible {
        case unsupportedFormat(UInt32)
        case encodeFailed
        public var description: String {
            switch self {
            case .unsupportedFormat(let f): "unsupported surface format 0x\(String(f, radix: 16))"
            case .encodeFailed: "PNG encoding failed"
            }
        }
    }

    /// Copies the surface's pixels (under a read lock) into a CGImage.
    public static func cgImage(_ surface: IOSurfaceRef) throws -> CGImage {
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let format = IOSurfaceGetPixelFormat(surface)
        let info: CGBitmapInfo
        switch format {
        case 0x4247_5241:  // 'BGRA': B,G,R,X in memory
            info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.noneSkipFirst.rawValue)
        case 0x5247_4241:  // 'RGBA': R,G,B,X in memory
            info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                                | CGImageAlphaInfo.noneSkipLast.rawValue)
        default:
            throw ImageError.unsupportedFormat(format)
        }
        IOSurfaceLock(surface, .readOnly, nil)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: stride * h)
        IOSurfaceUnlock(surface, .readOnly, nil)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ImageError.encodeFailed }
        return image
    }

    public static func png(_ surface: IOSurfaceRef) throws -> Data {
        let image = try cgImage(surface)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.encodeFailed }
        return out as Data
    }

    /// Fraction of sampled pixels that are not (near) black: a quick
    /// "is anything on screen" check for scripts and tests.
    public static func nonBlackFraction(_ surface: IOSurfaceRef, threshold: UInt8 = 16) -> Double {
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        guard w > 0, h > 0 else { return 0 }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let stride = IOSurfaceGetBytesPerRow(surface)
        var lit = 0, total = 0
        for y in Swift.stride(from: 0, to: h, by: 4) {
            for x in Swift.stride(from: 0, to: w, by: 4) {
                let p = base + y * stride + x * 4
                if p[0] > threshold || p[1] > threshold || p[2] > threshold { lit += 1 }
                total += 1
            }
        }
        return Double(lit) / Double(total)
    }

    /// Same check for any image (e.g. a QMP screendump PNG).
    public static func nonBlackFraction(_ image: CGImage, threshold: UInt8 = 16) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let base = data.assumingMemoryBound(to: UInt8.self)
        var lit = 0, total = 0
        for y in Swift.stride(from: 0, to: h, by: 4) {
            for x in Swift.stride(from: 0, to: w, by: 4) {
                let p = base + y * w * 4 + x * 4
                if p[0] > threshold || p[1] > threshold || p[2] > threshold { lit += 1 }
                total += 1
            }
        }
        return Double(lit) / Double(total)
    }
}
