import AppKit

/// Exemplar-based local repair: copies nearby matching texture into a rectangular mask.
/// This is deliberately local image processing, with no model or network dependency.
enum CaptureTextureRepair {
    static func repair(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let mask = rect.integral.intersection(bounds)
        guard mask.width >= 1, mask.height >= 1, mask != bounds else { throw PluginError.invalid("请框选需要修补的局部区域，并保留周围背景。") }
        let margin = max(32, min(180, max(mask.width, mask.height)))
        let neighborhood = mask.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral
        guard let source = image.cropping(to: neighborhood) else { throw PluginError.invalid("无法读取修补区域。") }
        let scale = min(1, 96 / max(mask.width, mask.height), 320 / max(neighborhood.width, neighborhood.height))
        let w = max(8, Int(neighborhood.width * scale)), h = max(8, Int(neighborhood.height * scale))
        guard let work = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let raw = work.data else { throw PluginError.invalid("无法分配修补缓存。") }
        work.interpolationQuality = .high; work.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let original = Array(UnsafeBufferPointer(start: bytes, count: w * h * 4))
        let local = CGRect(x: (mask.minX - neighborhood.minX) * CGFloat(w) / neighborhood.width,
                           y: (mask.minY - neighborhood.minY) * CGFloat(h) / neighborhood.height,
                           width: mask.width * CGFloat(w) / neighborhood.width, height: mask.height * CGFloat(h) / neighborhood.height).integral
        let x0 = max(0, Int(local.minX)), y0 = max(0, Int(local.minY)), x1 = min(w, Int(local.maxX)), y1 = min(h, Int(local.maxY))
        var unknown = [Bool](repeating: false, count: w * h)
        for y in y0..<y1 { for x in x0..<x1 { unknown[y * w + x] = true } }
        let radius = 3
        var candidates: [(Int, Int)] = []
        let strideSize = max(2, Int(sqrt(Double(w * h) / 500)))
        for y in stride(from: radius, to: h - radius, by: strideSize) {
            for x in stride(from: radius, to: w - radius, by: strideSize) {
                if x + radius < x0 || x - radius >= x1 || y + radius < y0 || y - radius >= y1 { candidates.append((x, y)) }
            }
        }
        guard !candidates.isEmpty else { throw PluginError.invalid("周围背景太少，无法进行纹理修补。") }
        var remaining = (x1 - x0) * (y1 - y0)
        while remaining > 0 {
            try Task.checkCancellation()
            // Fill from the existing boundary inward; every patch has known context to match.
            var target: (Int, Int)?
            search: for y in y0..<y1 {
                for x in x0..<x1 where unknown[y * w + x] {
                    if (x > 0 && !unknown[y * w + x - 1]) || (x + 1 < w && !unknown[y * w + x + 1]) ||
                       (y > 0 && !unknown[(y - 1) * w + x]) || (y + 1 < h && !unknown[(y + 1) * w + x]) {
                        target = (x, y); break search
                    }
                }
            }
            guard let (tx, ty) = target else { break }
            var known: [(Int, Int)] = []
            for dy in -radius...radius { for dx in -radius...radius {
                let x = tx + dx, y = ty + dy
                if x >= 0, y >= 0, x < w, y < h, !unknown[y * w + x] { known.append((dx, dy)) }
            } }
            var best = candidates[0], score = Double.infinity
            for (cx, cy) in candidates {
                var difference = Double((cx - tx) * (cx - tx) + (cy - ty) * (cy - ty)) * 0.005
                for (dx, dy) in known {
                    let targetIndex = ((ty + dy) * w + tx + dx) * 4, candidateIndex = ((cy + dy) * w + cx + dx) * 4
                    for channel in 0..<3 {
                        let delta = Int(bytes[targetIndex + channel]) - Int(original[candidateIndex + channel])
                        difference += Double(delta * delta)
                    }
                    if difference > score { break }
                }
                if difference < score { score = difference; best = (cx, cy) }
            }
            for dy in -radius...radius { for dx in -radius...radius {
                let x = tx + dx, y = ty + dy
                guard x >= 0, y >= 0, x < w, y < h, unknown[y * w + x] else { continue }
                let to = (y * w + x) * 4, from = ((best.1 + dy) * w + best.0 + dx) * 4
                for channel in 0..<4 { bytes[to + channel] = original[from + channel] }
                unknown[y * w + x] = false; remaining -= 1
            } }
        }
        guard let repaired = work.makeImage(), let patch = repaired.cropping(to: local) else { throw PluginError.invalid("纹理修补失败。") }
        let output = try CaptureImage.context(width: image.width, height: image.height, colorSpace: image.colorSpace)
        output.draw(image, in: bounds)
        output.interpolationQuality = .high
        // Core Graphics destinations are bottom-up while capture selection rectangles are top-down.
        output.draw(patch, in: CGRect(x: mask.minX, y: bounds.height - mask.maxY, width: mask.width, height: mask.height))
        guard let result = output.makeImage() else { throw PluginError.invalid("无法生成修补图片。") }
        return result
    }
}
