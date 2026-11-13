import AppKit
import SwiftUI
import Testing
@testable import Untitled

@Suite(.serialized) struct SharingLayoutTests {
    @Test func freePositionsDoNotSnapToFourCardinalSlots() {
        let layout = SharingDisplayLayout(peerOffset: .init(x: 200, y: 0))
        #expect(layout.adjusted(.init(x: 420, y: 37)) == .init(x: 420, y: 37))
        #expect(layout.adjusted(.init(x: -630, y: -280)) == .init(x: -630, y: -280))
        #expect(layout.adjusted(.init(x: 205, y: 37)) == .init(x: 200, y: 37))
        let nonoverlap = SharingDisplayLayout(peerOffset: layout.adjusted(.init(x: 40, y: 20)))
        #expect(!nonoverlap.localRect.intersects(nonoverlap.peerRect))
    }
    @Test func mirroringPreservesTheSameWorldForDifferentScreenShapes() {
        let a = SharingDisplayLayout(peerOffset: .init(x: 250, y: -60), localAspect: 1.8, peerAspect: 1.2)
        let b = SharingDisplayLayout(peerOffset: a.peerOffset.mirrored, localAspect: a.peerAspect, peerAspect: a.localAspect)
        #expect(a.peerRect.offsetBy(dx: -250, dy: 60) == b.localRect)
        #expect(a.localRect.offsetBy(dx: -250, dy: 60) == b.peerRect)
    }
    @Test func offsetScreensOnlyCrossWhereTheRayReachesTheOtherDisplay() throws {
        let screen = CGRect(x: -1600, y: -40, width: 1600, height: 1000)
        let a = SharingDisplayLayout(peerOffset: .init(x: 200, y: 50))
        let across = try #require(a.handoff(point: CGPoint(x: -1, y: 860), delta: CGPoint(x: 5, y: 0), screen: screen))
        #expect(across.entryEdge == .left && abs(across.position.y - 0.5) < 0.001)
        #expect(a.handoff(point: CGPoint(x: -1, y: -40), delta: CGPoint(x: 5, y: 0), screen: screen) == nil)
        let b = SharingDisplayLayout(peerOffset: a.peerOffset.mirrored)
        let back = try #require(b.handoff(point: CGPoint(x: 0, y: 500), delta: CGPoint(x: -5, y: 0), screen: CGRect(x: 0, y: 0, width: 1600, height: 1000)))
        #expect(back.entryEdge == .right && abs(back.position.y - 0.9) < 0.001)
    }
    @Test func emptySpaceAndDiagonalPlacementHaveRealSpatialCrossing() throws {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let gap = SharingDisplayLayout(peerOffset: .init(x: 350, y: 50))
        #expect(gap.handoff(point: CGPoint(x: 1599, y: 800), delta: CGPoint(x: 10, y: 0), screen: screen) != nil)
        #expect(gap.handoff(point: CGPoint(x: 1599, y: 0), delta: CGPoint(x: 10, y: 0), screen: screen) == nil)
        let diagonal = SharingDisplayLayout(peerOffset: .init(x: 300, y: 200))
        #expect(diagonal.handoff(point: CGPoint(x: 1599, y: 999), delta: CGPoint(x: 6, y: 6), screen: screen) != nil)
        #expect(diagonal.handoff(point: CGPoint(x: 1599, y: 500), delta: CGPoint(x: 6, y: 0), screen: screen) == nil)
    }
    @Test func pixelDimensionsUseOneScaleInsteadOfEqualCardWidths() {
        let own = SharingScreenPixels(width: 2560, height: 1080), other = SharingScreenPixels(width: 1920, height: 1080)
        let offset = SharingDisplayLayout.touching(.left, localPixels: own, peerPixels: other)
        let layout = SharingDisplayLayout(peerOffset: offset, localPixels: own, peerPixels: other)
        #expect(layout.localRect.size == own.size && layout.peerRect.size == other.size)
        #expect(layout.localRect.height == layout.peerRect.height && offset.x == -2240)
        #expect(!layout.localRect.intersects(layout.peerRect) && layout.peerRect.maxX == layout.localRect.minX)
        let viewport = SharingCanvasViewport.fit(layout, in: CGSize(width: 560, height: 320))
        #expect(abs((layout.localRect.width * viewport.scale) / (layout.peerRect.width * viewport.scale) - 4.0 / 3) < 0.001)
    }
    @Test func retinaPixelSizeAndLogicalCursorCoordinatesRemainSeparate() throws {
        let own = SharingScreenPixels(width: 3840, height: 2160), peer = SharingScreenPixels(width: 1920, height: 1080)
        let layout = SharingDisplayLayout(peerOffset: .init(x: 2880, y: 0), localPixels: own, peerPixels: peer)
        let logicalScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let handoff = try #require(layout.handoff(point: CGPoint(x: 1919, y: 540), delta: CGPoint(x: 5, y: 0), screen: logicalScreen))
        #expect(handoff.position.y == 0.5 && layout.localRect.width == 3840)
        #expect(layout.handoff(point: CGPoint(x: 1919, y: 1000), delta: CGPoint(x: 5, y: 0), screen: logicalScreen) == nil)
    }
    @Test func oldEqualWidthOffsetsMigrateSymmetricallyWithoutLosingStaggerOrGap() {
        let own = SharingScreenPixels(width: 2560, height: 1080), peer = SharingScreenPixels(width: 1920, height: 1080)
        let a = SharingDisplayLayout(peerOffset: .zero, localAspect: own.aspect, peerAspect: peer.aspect, localPixels: own, peerPixels: peer)
        let b = SharingDisplayLayout(peerOffset: .zero, localAspect: peer.aspect, peerAspect: own.aspect, localPixels: peer, peerPixels: own)
        let old = SharingLayoutPoint(x: -320, y: 25), converted = a.offsetFromLegacyUnits(old)
        #expect(converted == b.offsetFromLegacyUnits(old.mirrored).mirrored)
        #expect(converted.x == -3584 && converted.y > 0)
    }
    @Test func pixelProtocolRejectsGuessedMissingAndImpossibleDimensions() throws {
        for dimensions in [SharingScreenPixels(width: 0, height: 1080), .init(width: Int.max, height: 1080), .init(width: 65_536, height: 65_536)] {
            #expect(throws: PluginError.self) { try dimensions.validate() }
        }
        let stamp = SharingLayoutStamp(counter: 1, author: UUID().uuidString)
        #expect(throws: PluginError.self) { try SharingMessage(kind: .layout, edge: .left, layoutVersion: 3, screenAspect: 1.6, layoutOffset: .init(x: -2240, y: 0), layoutStamp: stamp).validate() }
        try SharingMessage(kind: .layout, edge: .left, layoutVersion: 3, screenAspect: 1920.0 / 1080, layoutOffset: .init(x: -2240, y: 0), layoutStamp: stamp, screenPixels: .init(width: 1920, height: 1080)).validate()
        #expect(throws: PluginError.self) { try SharingMessage(kind: .layout, edge: .left, layoutVersion: 3, screenAspect: 1.6, layoutOffset: .init(x: -2240, y: 0), layoutStamp: stamp, screenPixels: .init(width: 1920, height: 1080)).validate() }
    }
    @Test func canvasPansZoomsAndFitsWithoutBoundingDevicePositions() {
        let layout = SharingDisplayLayout(peerOffset: .init(x: 7000, y: -2800))
        let size = CGSize(width: 560, height: 320)
        var view = SharingCanvasViewport.fit(layout, in: size)
        for point in [CGPoint.zero, layout.peerOffset.point, CGPoint(x: -9000, y: 20000)] {
            let roundtrip = view.unproject(view.project(point, in: size), in: size)
            #expect(abs(roundtrip.x - point.x) < 0.0001 && abs(roundtrip.y - point.y) < 0.0001)
        }
        #expect(CGRect(origin: .zero, size: size).contains(view.project(layout.peerOffset.point, in: size)))
        view.center = CGPoint(x: -25000, y: 19000)
        #expect(view.zoomed(by: 2).center == view.center)
        #expect(view.zoomed(by: 2).scale > view.scale)
    }
    @Test @MainActor func freeLayoutPersistsWithoutStartingOrChangingDeviceIdentity() throws {
        let domain = "free-layout-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let a = PeripheralSharingController(defaults: settings, screenPixels: .init(width: 2560, height: 1080))
        let identity = settings.string(forKey: "sharing.deviceID")
        a.setLayoutOffset(.init(x: -3390, y: 44))
        let b = PeripheralSharingController(defaults: settings, screenPixels: .init(width: 2560, height: 1080))
        #expect(b.layoutOffset == .init(x: -3390, y: 44) && a.layoutStamp == b.layoutStamp)
        #expect(settings.string(forKey: "sharing.deviceID") == identity)
        #expect(!b.isRunning && !b.keyboardMouseEnabled && b.transport.port == nil)
        #expect(!b.microphoneOffered && !b.isSendingMicrophone)
    }
    @Test func spatialProtocolValidatesBoundsAndKeepsOldHelloCompatible() throws {
        let legacy = Data("{\"kind\":\"hello\",\"version\":1,\"deviceID\":\"\(UUID().uuidString)\",\"name\":\"Old Mac\"}".utf8)
        let hello = try JSONDecoder().decode(SharingMessage.self, from: legacy)
        try hello.validate(); #expect(hello.layoutVersion == nil)
        #expect(throws: PluginError.self) { try SharingMessage(kind: .layout, edge: .left, layoutVersion: 2).validate() }
        #expect(throws: PluginError.self) { try SharingLayoutPoint(x: .infinity, y: 0).validate() }
        #expect(throws: PluginError.self) { try SharingCursorPosition(x: -0.1, y: 0.5).validate() }
        #expect(throws: PluginError.self) { try SharingLayoutStamp(counter: 1, author: "not-a-device").validate() }
        let stamp = SharingLayoutStamp(counter: 1, author: UUID().uuidString)
        try SharingMessage(kind: .layout, edge: .right, layoutVersion: 2, screenAspect: 1.6, layoutOffset: .init(x: 300, y: 40), layoutStamp: stamp).validate()
        try SharingMessage(kind: .end, returnPosition: .init(x: 0, y: 0.6)).validate()
    }
    @Test func basicInterfaceHasNoDuplicateToolbarOrEdgeSwitch() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/peripheral-sharing/manifest.json")))
        let ui = try #require(manifest.ui)
        #expect(ui.items(in: .toolbarLeading).isEmpty && ui.items(in: .toolbarTrailing).isEmpty)
        #expect(ui.items(in: .menuBar).contains { $0.command == "sharing.stop" })
        let source = try String(contentsOfFile: "Sources/Untitled/Sharing/SharingPluginView.swift", encoding: .utf8)
        #expect(!source.contains("边缘穿越") && !source.contains("edgeSwitching"))
        #expect(!source.contains("键盘与鼠标") && !source.contains("返回本机") && !source.contains("麦克风"))
        #expect(source.components(separatedBy: "Toggle(").count - 1 == 1)
    }
    @Test func publicAndRuntimeIdentitiesUseUntitled() throws {
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil) as? [String: Any])
        #expect(HostInfo.name == "Untitled" && plist["CFBundleDisplayName"] as? String == HostInfo.name)
        #expect(plist["CFBundleIdentifier"] as? String == "com.untitled.app")
        #expect(SharingAudioDevices.inputUID == "com.untitled.app.microphone.input.v1")
    }
    @Test @MainActor func freeCanvasRendersArbitraryPositionsInLightAndDark() throws {
        for scheme in [ColorScheme.light, .dark] {
            for offset in [SharingLayoutPoint(x: -270, y: -35), .init(x: 250, y: 60), .init(x: 80, y: -180), .init(x: 1400, y: 500)] {
                let observation = Bounds()
                let view = SharingLayoutEditor(localName: "Main Mac", remoteName: "Second Mac", peerOffset: .constant(offset), isConnected: true)
                    .padding(16).coordinateSpace(name: PanelLayout.coordinateSpace).environment(\.colorScheme, scheme)
                    .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { observation.frames = value } }
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 352), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
                for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                let canvas = try #require(observation.frames["sharing.layout.editor"])
                #expect(canvas.contains(try #require(observation.frames["sharing.layout.local"])))
                #expect(canvas.contains(try #require(observation.frames["sharing.layout.remote"])))
            }
        }
    }
    @Test @MainActor func basicDashboardRendersWithoutReadingKeychainOrStartingCapture() throws {
        let domain = "canvas-dashboard-\(UUID().uuidString)", directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = UserDefaults(suiteName: domain)!; settings.set("macmini-worker-1", forKey: "sharing.lastPeerName")
        settings.set("left", forKey: "sharing.edge")
        settings.set(try JSONEncoder().encode(SharingScreenPixels(width: 1920, height: 1080)), forKey: "sharing.peerPixels")
        defer { settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let controller = PeripheralSharingController(defaults: settings, screenPixels: .init(width: 2560, height: 1080)), store = PluginStore(directory: directory)
        let observation = Bounds()
        let view = SharingPluginView(controller: controller, keyAvailable: { true }).environmentObject(store)
            .padding(20).background(Color(nsColor: .windowBackgroundColor)).coordinateSpace(name: PanelLayout.coordinateSpace)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { observation.frames = value } }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let root = try #require(observation.frames["sharing.dashboard"])
        #expect(root.contains(try #require(observation.frames["sharing.layout.editor"])))
        #expect(observation.frames["sharing.input.controls"] == nil && observation.frames["sharing.microphone.disclosure"] == nil)
        let ownFrame = try #require(observation.frames["sharing.layout.local"]), peerFrame = try #require(observation.frames["sharing.layout.remote"])
        #expect(abs(ownFrame.height - peerFrame.height) < 0.01)
        #expect(abs(ownFrame.width / peerFrame.width - 4.0 / 3) < 0.001)
        #expect(!controller.isRunning && controller.transport.port == nil && !controller.isSendingMicrophone)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/untitled-sharing-pixels-preview.png"))
        }
    }
    @MainActor private final class Bounds { var frames: [String: CGRect] = [:] }
}
