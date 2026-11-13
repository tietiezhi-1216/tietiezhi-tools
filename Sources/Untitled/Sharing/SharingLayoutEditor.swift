import SwiftUI

struct SharingLayoutEditor: View {
    let localName: String
    let remoteName: String
    @Binding var peerOffset: SharingLayoutPoint
    var localAspect = 1.6
    var peerAspect = 1.6
    var localPixels: SharingScreenPixels?
    var peerPixels: SharingScreenPixels?
    var isConnected = false
    var canEdit = true
    var controllingRemote = false
    @ViewState private var camera: SharingCanvasViewport?
    @ViewState private var dragStart: SharingLayoutPoint?
    @ViewState private var dragPreview: SharingLayoutPoint?
    @ViewState private var draggingLocal = false
    @ViewState private var panStart: SharingCanvasViewport?
    @ViewState private var zoomStart: SharingCanvasViewport?
    private let space = "sharing.free-canvas"
    private var layout: SharingDisplayLayout { .init(peerOffset: peerOffset, localAspect: localAspect, peerAspect: peerAspect, localPixels: localPixels, peerPixels: peerPixels) }

    var body: some View {
        GeometryReader { proxy in
            let viewport = camera ?? SharingCanvasViewport.fit(layout, in: proxy.size)
            ZStack(alignment: .bottomTrailing) {
                Canvas { context, size in
                    var step = 20 * viewport.scale
                    while step < 16 { step *= 2 }
                    while step > 40 { step /= 2 }
                    let origin = viewport.project(.zero, in: size)
                    let firstX = origin.x.truncatingRemainder(dividingBy: step)
                    let firstY = origin.y.truncatingRemainder(dividingBy: step)
                    for x in stride(from: firstX, through: size.width, by: step) {
                        for y in stride(from: firstY, through: size.height, by: step) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.2)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .named(space)).onChanged { value in
                    if panStart == nil { panStart = viewport }
                    guard var next = panStart else { return }
                    next.center.x -= value.translation.width / next.scale; next.center.y -= value.translation.height / next.scale
                    camera = next
                }.onEnded { _ in panStart = nil })
                .accessibilityLabel("屏幕布局画布，可拖动空白区域平移")
                device(local: true, viewport: viewport, size: proxy.size)
                device(local: false, viewport: viewport, size: proxy.size)
                HStack(spacing: 1) {
                    Button { camera = viewport.zoomed(by: 0.8) } label: { Image(systemName: "minus") }.help("缩小")
                    Button { camera = SharingCanvasViewport.fit(layout, in: proxy.size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("显示全部设备")
                    Button { camera = viewport.zoomed(by: 1.25) } label: { Image(systemName: "plus") }.help("放大")
                }.buttonStyle(.borderless).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(12)
            }
            .background(SharingCanvasWheelInput { delta, zoom in
                if zoom { camera = viewport.zoomed(by: exp(delta.height / 140)) }
                else {
                    var next = viewport
                    next.center.x -= delta.width / next.scale; next.center.y -= delta.height / next.scale
                    camera = next
                }
            })
            .coordinateSpace(name: space)
            .background(.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if zoomStart == nil { zoomStart = viewport }
                camera = zoomStart?.zoomed(by: value.magnification)
            }.onEnded { _ in zoomStart = nil })
        }
        .frame(height: 320)
        .onChange(of: localPixels) { _, _ in camera = nil }
        .onChange(of: peerPixels) { _, _ in camera = nil }
        .onChange(of: canEdit) { _, value in if !value { dragStart = nil; dragPreview = nil } }
        .panelRegion("sharing.layout.editor")
    }
    private func device(local: Bool, viewport: SharingCanvasViewport, size: CGSize) -> some View {
        let rect = local ? layout.localRect : layout.peerRect
        let point = local ? (draggingLocal ? dragPreview?.point ?? .zero : .zero) : (!draggingLocal ? dragPreview?.point ?? peerOffset.point : peerOffset.point)
        let active = local ? !controllingRemote : controllingRemote
        let width = rect.width * viewport.scale, height = rect.height * viewport.scale
        let pixels = local ? localPixels : peerPixels
        return VStack(alignment: .leading, spacing: 5) {
            if width >= 100, height >= 70 {
                HStack(spacing: 5) {
                    Circle().fill(local || isConnected ? Color.green : .secondary.opacity(0.5)).frame(width: 5, height: 5)
                    Text(local ? "这台 Mac" : "对端 Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "desktopcomputer").font(.system(size: 13)).foregroundStyle(active ? Color.accentColor : .secondary)
                }
                Spacer(minLength: 0)
                Text(local ? localName : remoteName).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.65)
                if let pixels { Text(pixels.label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .padding(min(12, min(width, height) / 4)).frame(width: width, height: height).clipped()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color.accentColor : .secondary.opacity(0.35), lineWidth: active ? 2 : 1))
        .shadow(color: .black.opacity(dragStart == nil ? 0.04 : 0.13), radius: dragStart == nil ? 2 : 10, y: 3)
        .panelRegion(local ? "sharing.layout.local" : "sharing.layout.remote")
        .position(viewport.project(point, in: size))
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(space)).onChanged { value in
            guard canEdit else { return }
            if dragStart == nil { dragStart = local ? .zero : peerOffset; draggingLocal = local; camera = viewport }
            guard let dragStart else { return }
            dragPreview = SharingLayoutPoint(x: dragStart.x + value.translation.width / viewport.scale, y: dragStart.y + value.translation.height / viewport.scale)
        }.onEnded { _ in
            guard canEdit, let preview = dragPreview else { dragStart = nil; dragPreview = nil; return }
            let desired = local ? SharingLayoutPoint(x: peerOffset.x - preview.x, y: peerOffset.y - preview.y) : preview
            let adjusted = layout.adjusted(desired, magnet: 8 / viewport.scale)
            if local {
                var next = viewport
                next.center.x += adjusted.x - peerOffset.x; next.center.y += adjusted.y - peerOffset.y
                camera = next
            }
            peerOffset = adjusted; dragStart = nil; dragPreview = nil
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel((local ? localName : remoteName) + (pixels.map { "，" + $0.label } ?? ""))
        .accessibilityHint("自由拖放，调整设备相对位置")
    }
}

/// Own-window scrolling only; never installs a global input monitor or requests TCC.
private struct SharingCanvasWheelInput: NSViewRepresentable {
    let changed: (CGSize, Bool) -> Void
    func makeNSView(context: Context) -> CanvasWheelView { let view = CanvasWheelView(); view.changed = changed; return view }
    func updateNSView(_ view: CanvasWheelView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: CanvasWheelView, coordinator: ()) { view.stop() }
    @MainActor final class CanvasWheelView: NSView {
        var changed: (CGSize, Bool) -> Void = { _, _ in }
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    self.changed(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), event.modifierFlags.contains(.option))
                    return true
                }
                return consumed ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}
