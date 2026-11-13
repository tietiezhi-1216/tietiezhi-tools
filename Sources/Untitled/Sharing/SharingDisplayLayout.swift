import CoreGraphics
import Foundation

/// Current framebuffer pixels, not AppKit points (Retina modes must not be halved).
struct SharingScreenPixels: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var size: CGSize { CGSize(width: width, height: height) }
    var aspect: Double { Double(width) / Double(max(1, height)) }
    var label: String { "\(width) × \(height)" }
    func validate() throws {
        guard (1...65_536).contains(width), (1...65_536).contains(height),
              width * height <= 1_000_000_000, (0.1...10).contains(aspect) else { throw PluginError.invalid("屏幕像素尺寸无效。") }
    }
    static var current: Self? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let pixels = Self(width: mode.pixelWidth, height: mode.pixelHeight)
        return (try? pixels.validate()) != nil ? pixels : nil
    }
}

struct SharingDisplayLayout: Equatable, Sendable {
    static let deviceWidth: CGFloat = 200
    var peerOffset: SharingLayoutPoint
    var localAspect: Double = 1.6
    var peerAspect: Double = 1.6
    var localPixels: SharingScreenPixels?
    var peerPixels: SharingScreenPixels?
    private var localSize: CGSize { localPixels?.size ?? CGSize(width: Self.deviceWidth, height: Self.deviceWidth / max(0.1, min(10, localAspect))) }
    private var peerSize: CGSize { peerPixels?.size ?? CGSize(width: localSize.width, height: localSize.width / max(0.1, min(10, peerAspect))) }
    var localRect: CGRect { rect(center: .zero, size: localSize) }
    var peerRect: CGRect { rect(center: peerOffset.point, size: peerSize) }
    var bounds: CGRect { localRect.union(peerRect) }
    private func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
    static func touching(_ side: SharingEdge, localAspect: Double = 1.6, peerAspect: Double = 1.6,
                         localPixels: SharingScreenPixels? = nil, peerPixels: SharingScreenPixels? = nil) -> SharingLayoutPoint {
        let layout = Self(peerOffset: .zero, localAspect: localAspect, peerAspect: peerAspect, localPixels: localPixels, peerPixels: peerPixels)
        let horizontal = Double(layout.localRect.width + layout.peerRect.width) / 2
        let vertical = Double(layout.localRect.height + layout.peerRect.height) / 2
        switch side {
        case .left: return .init(x: -horizontal, y: 0)
        case .right: return .init(x: horizontal, y: 0)
        case .top: return .init(x: 0, y: -vertical)
        case .bottom: return .init(x: 0, y: vertical)
        }
    }
    /// Symmetric conversion preserves mirrored offsets and old contact/offset intent.
    /// Old releases used width 200 for BOTH screens, irrespective of resolution.
    func offsetFromLegacyUnits(_ offset: SharingLayoutPoint) -> SharingLayoutPoint {
        let oldHeight = Double(Self.deviceWidth) / localAspect + Double(Self.deviceWidth) / peerAspect
        return .init(x: offset.x * Double(localRect.width + peerRect.width) / (2 * Double(Self.deviceWidth)),
                     y: offset.y * Double(localRect.height + peerRect.height) / oldHeight)
    }
    var primaryEdge: SharingEdge {
        let x = peerOffset.x / (Double(localRect.width + peerRect.width) / 2)
        let y = peerOffset.y / (Double(localRect.height + peerRect.height) / 2)
        return abs(x) >= abs(y) ? (x < 0 ? .left : .right) : (y < 0 ? .top : .bottom)
    }
    /// Free movement, with edge magnetism only near contact. No cardinal slots or
    /// forced centering: perpendicular offset and empty space remain meaningful.
    func adjusted(_ desired: SharingLayoutPoint, magnet: Double = 8) -> SharingLayoutPoint {
        guard (try? desired.validate()) != nil else { return peerOffset }
        var result = desired
        var other = rect(center: desired.point, size: peerSize)
        if localRect.intersects(other) {
            let candidates = [
                SharingLayoutPoint(x: Double(localRect.minX - other.width / 2), y: desired.y),
                SharingLayoutPoint(x: Double(localRect.maxX + other.width / 2), y: desired.y),
                SharingLayoutPoint(x: desired.x, y: Double(localRect.minY - other.height / 2)),
                SharingLayoutPoint(x: desired.x, y: Double(localRect.maxY + other.height / 2))]
            result = candidates.min { hypot($0.x - desired.x, $0.y - desired.y) < hypot($1.x - desired.x, $1.y - desired.y) } ?? desired
            other = rect(center: result.point, size: peerSize)
        }
        if other.maxY > localRect.minY, other.minY < localRect.maxY {
            if abs(other.minX - localRect.maxX) <= magnet { result.x = Double(localRect.maxX + other.width / 2) }
            else if abs(other.maxX - localRect.minX) <= magnet { result.x = Double(localRect.minX - other.width / 2) }
        }
        if other.maxX > localRect.minX, other.minX < localRect.maxX {
            if abs(other.minY - localRect.maxY) <= magnet { result.y = Double(localRect.maxY + other.height / 2) }
            else if abs(other.maxY - localRect.minY) <= magnet { result.y = Double(localRect.minY - other.height / 2) }
        }
        return result
    }
    struct Handoff: Equatable {
        let entryEdge: SharingEdge
        let position: SharingCursorPosition
        var wireEdge: SharingEdge { entryEdge.opposite }
        var fraction: Double { entryEdge == .left || entryEdge == .right ? position.y : position.x }
    }
    func handoff(point: CGPoint, delta: CGPoint, screen: CGRect) -> Handoff? {
        guard screen.width > 0, screen.height > 0, delta.x.isFinite, delta.y.isFinite else { return nil }
        guard SharingEdge.allCases.contains(where: { $0.isCrossing(point, delta: delta, bounds: screen) }) else { return nil }
        let normalized = CGPoint(x: min(1, max(0, (point.x - screen.minX) / screen.width)), y: min(1, max(0, (point.y - screen.minY) / screen.height)))
        let world = CGPoint(x: localRect.minX + normalized.x * localRect.width, y: localRect.minY + normalized.y * localRect.height)
        let direction = CGPoint(x: delta.x * localRect.width / screen.width, y: delta.y * localRect.height / screen.height)
        return intersection(from: world, direction: direction)
    }
    var defaultEntry: Handoff? { intersection(from: .zero, direction: peerOffset.point) }
    private func intersection(from point: CGPoint, direction: CGPoint) -> Handoff? {
        guard abs(direction.x) + abs(direction.y) > 0 else { return nil }
        var near = -Double.infinity, far = Double.infinity
        var entry = SharingEdge.left
        for (origin, delta, minimum, maximum, low, high) in [
            (point.x, direction.x, peerRect.minX, peerRect.maxX, SharingEdge.left, SharingEdge.right),
            (point.y, direction.y, peerRect.minY, peerRect.maxY, SharingEdge.top, SharingEdge.bottom)] {
            if abs(delta) < 0.0000001 { if origin < minimum || origin > maximum { return nil }; continue }
            let first = (minimum - origin) / delta, second = (maximum - origin) / delta
            let start = min(first, second), end = max(first, second)
            if start > near { near = start; entry = delta > 0 ? low : high }
            far = min(far, end)
        }
        guard near.isFinite, near >= -0.00001, far >= max(0, near) else { return nil }
        let distance = max(0, near)
        let hit = CGPoint(x: point.x + direction.x * distance, y: point.y + direction.y * distance)
        let normalized = SharingCursorPosition(x: min(1, max(0, (hit.x - peerRect.minX) / peerRect.width)), y: min(1, max(0, (hit.y - peerRect.minY) / peerRect.height)))
        return Handoff(entryEdge: entry, position: normalized)
    }
}

struct SharingCanvasViewport: Equatable {
    var center: CGPoint
    var scale: CGFloat
    static func fit(_ layout: SharingDisplayLayout, in size: CGSize) -> Self {
        let bounds = layout.bounds
        return Self(center: CGPoint(x: bounds.midX, y: bounds.midY), scale: max(0.0001, min(2, min(max(1, size.width - 100) / max(1, bounds.width), max(1, size.height - 80) / max(1, bounds.height)))))
    }
    func project(_ point: CGPoint, in size: CGSize) -> CGPoint { CGPoint(x: (point.x - center.x) * scale + size.width / 2, y: (point.y - center.y) * scale + size.height / 2) }
    func unproject(_ point: CGPoint, in size: CGSize) -> CGPoint { CGPoint(x: (point.x - size.width / 2) / scale + center.x, y: (point.y - size.height / 2) / scale + center.y) }
    func zoomed(by factor: CGFloat) -> Self { Self(center: center, scale: max(0.0001, min(5, scale * factor))) }
}
