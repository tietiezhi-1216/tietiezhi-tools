import AppKit
import SwiftUI
import Testing
@testable import Untitled

@Suite(.serialized)
struct CaptureFloatingEditorTests {
    @Test func selectionCoordinatesPreserveRetinaSizeAndMultipleScreenOrigins() {
        let screen = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        let selection = CGRect(x: 125.5, y: 100, width: 400, height: 250)
        let frame = CaptureFloatingLayout.screenRect(selection, on: screen)
        #expect(frame == CGRect(x: -1314.5, y: 1450, width: 400, height: 250))
        #expect(CaptureFloatingLayout.imageFrame(size: CGSize(width: 800, height: 500), preferred: frame, screen: screen, pixelsPerPoint: 2) == frame)
    }
    @Test func toolbarAvoidsScreenEdgesAndChoosesTheFreeSide() {
        let visible = CGRect(x: -1280, y: -300, width: 1280, height: 780)
        let middle = CGRect(x: -1100, y: -50, width: 400, height: 250)
        let below = CaptureFloatingLayout.toolbarFrame(image: middle, visible: visible)
        #expect(visible.contains(below))
        #expect(below.maxY <= middle.minY)
        let bottom = CGRect(x: -100, y: -295, width: 80, height: 60)
        let above = CaptureFloatingLayout.toolbarFrame(image: bottom, visible: visible)
        #expect(visible.contains(above))
        #expect(above.minY >= bottom.maxY)
        for image in [visible, CGRect(x: -1280, y: 400, width: 30, height: 30), CGRect(x: -40, y: -290, width: 25, height: 25)] {
            #expect(visible.contains(CaptureFloatingLayout.toolbarFrame(image: image, visible: visible)))
        }
    }
    @Test @MainActor func captureEditsInPlaceAndPinsAtTheSamePosition() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FloatingEditorTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        defer { controller.deactivate() }
        let screen = try #require(NSScreen.main)
        let frame = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 200)
        let image = try fixture(width: 800, height: 400)
        controller.accept(image, at: frame)
        let editor = try #require(controller.editors.first)
        #expect(editor.imageFrame == frame)
        #expect(!editor.canvasPanel.styleMask.contains(.titled))
        #expect(editor.canvasPanel.standardWindowButton(.closeButton) == nil)
        #expect(editor.canvasPanel.contentView?.bounds.size == frame.size)
        #expect(screen.visibleFrame.contains(editor.toolsPanel.frame))
        editor.document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100)], color: .black, width: 3))
        editor.perform(.undo); #expect(editor.document.marks.isEmpty)
        editor.perform(.redo); #expect(editor.document.marks.count == 1)
        editor.perform(.pin)
        #expect(editor.isClosed && controller.editors.isEmpty)
        let pin = try #require(controller.pinManager.records.first)
        #expect(pin.frame == frame)
        let saved = try CaptureImage.load(controller.pinManager.url(pin))
        #expect(NSBitmapImageRep(cgImage: saved).colorAt(x: 60, y: 60)!.brightnessComponent < 0.05)
        #expect(controller.history.count == 1)
    }
    @Test @MainActor func textToolsAndHiddenToolbarKeepTheSameCanvasAndCloseTogether() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FloatingLayoutTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: CaptureDocument(image: try fixture(width: 640, height: 320)), controller: controller)
        defer { editor.close() }
        editor.show()
        let frame = editor.imageFrame
        editor.perform(.text)
        for _ in 0..<3 { await Task.yield() }
        #expect(editor.imageFrame == frame)
        #expect(editor.toolsPanel.frame.height == CaptureFloatingLayout.toolbarSize.height)
        editor.document.add(CaptureMark(tool: .crop, points: [CGPoint(x: 40, y: 40), CGPoint(x: 320, y: 240)], color: .red, width: 2))
        for _ in 0..<3 { await Task.yield() }
        let factor = frame.width / 640
        #expect(abs(editor.imageFrame.minX - (frame.minX + 40 * factor)) < 0.01)
        #expect(abs(editor.imageFrame.maxY - (frame.maxY - 40 * factor)) < 0.01)
        editor.perform(.undo)
        for _ in 0..<3 { await Task.yield() }
        #expect(editor.imageFrame == frame)
        editor.perform(.hideToolbar)
        for _ in 0..<3 { await Task.yield() }
        #expect(!editor.toolsPanel.isVisible && editor.canvasPanel.isVisible)
        editor.perform(.hideToolbar)
        for _ in 0..<3 { await Task.yield() }
        #expect(editor.toolsPanel.isVisible)
        editor.close()
        #expect(editor.isClosed && !editor.toolsPanel.isVisible && !editor.canvasPanel.isVisible)
    }
    @Test @MainActor func placeholderWindowNumbersAreSkippedWithoutIntegerTraps() {
        #expect(CaptureWindowPolicy.captureID(0) == nil)
        #expect(CaptureWindowPolicy.captureID(-1) == nil)
        #expect(CaptureWindowPolicy.captureID(Int.max) == nil)
        #expect(CaptureWindowPolicy.captureID(Int(UInt32.max) + 1) == nil)
        #expect(CaptureWindowPolicy.captureID(1234) == 1234)
    }
    @Test @MainActor func snapshotKeepsMainContentAndPinsButOmitsCaptureControls() throws {
        let main = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let pin = NSPanel(contentRect: CGRect(x: 70, y: 70, width: 120, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        let toolbar = NSPanel(contentRect: CGRect(x: 70, y: 170, width: 150, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let hidden = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        let windows = [main, pin, toolbar, hidden]
        for window in windows { window.isReleasedWhenClosed = false }
        defer { windows.forEach { $0.close() } }
        CaptureWindowPolicy.markControl(toolbar, name: "testToolbar")
        main.orderFront(nil); pin.orderFront(nil); toolbar.orderFront(nil)
        let included = CaptureWindowPolicy.contentWindowIDs(in: windows)
        #expect(included.contains(CGWindowID(main.windowNumber)))
        #expect(included.contains(CGWindowID(pin.windowNumber)))
        #expect(!included.contains(CGWindowID(toolbar.windowNumber)))
        #expect(!included.contains(CGWindowID(hidden.windowNumber)))
    }
    @Test @MainActor func firstDragAfterToolbarFocusCreatesTheSelectedMark() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureFocusTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        let editor = CaptureFloatingEditor(document: CaptureDocument(image: try fixture(width: 640, height: 320)), controller: controller)
        defer { editor.close() }
        editor.show()
        func drawingView(in view: NSView) -> CaptureDrawingView? {
            if let drawing = view as? CaptureDrawingView { return drawing }
            return view.subviews.lazy.compactMap { drawingView(in: $0) }.first
        }
        let root = try #require(editor.canvasPanel.contentView)
        for (index, action) in [CaptureShortcutAction.rectangle, .arrow, .mosaic].enumerated() {
            editor.perform(action)
            for _ in 0..<3 { await Task.yield() }
            root.layoutSubtreeIfNeeded()
            let drawing = try #require(drawingView(in: root))
            #expect(drawing.tool == action.tool)
            #expect(root.acceptsFirstMouse(for: nil))
            #expect(drawing.acceptsFirstMouse(for: nil))
            editor.toolsPanel.makeKeyAndOrderFront(nil)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: drawing.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.canvasPanel.windowNumber,
                    context: nil, eventNumber: index + 1, clickCount: 1, pressure: 1))
            }
            editor.canvasPanel.sendEvent(try event(.leftMouseDown, CGPoint(x: 20, y: 20)))
            editor.canvasPanel.sendEvent(try event(.leftMouseDragged, CGPoint(x: 90, y: 60)))
            editor.canvasPanel.sendEvent(try event(.leftMouseUp, CGPoint(x: 90, y: 60)))
            #expect(editor.document.marks.count == index + 1)
            #expect(editor.document.marks.last?.tool == action.tool)
        }
    }
    @Test @MainActor func defaultDragMovesImageAndToolbarWithoutDrawingOrAccumulatedOffset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMoveTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScreenshotController(directory: folder)
        let original = try fixture(width: 640, height: 320)
        let visible = try #require(NSScreen.main?.visibleFrame)
        let toolbarWidth = min(CaptureFloatingLayout.toolbarSize.width, visible.width - 16)
        let horizontalMove = min(55, max(0, (visible.width - toolbarWidth - 16) / 2))
        // Start with room for the requested motion; boundary clamping is tested separately.
        let preferred = CGRect(x: visible.maxX - 8 - horizontalMove - 640,
                               y: visible.midY - 160, width: 640, height: 320)
        let editor = CaptureFloatingEditor(document: CaptureDocument(image: original), controller: controller,
                                           preferredFrame: preferred)
        defer { editor.close() }
        editor.show()
        for _ in 0..<3 { await Task.yield() }
        let root = try #require(editor.canvasPanel.contentView)
        root.layoutSubtreeIfNeeded()
        func drawingView(in view: NSView) -> CaptureDrawingView? {
            if let drawing = view as? CaptureDrawingView { return drawing }
            return view.subviews.lazy.compactMap { drawingView(in: $0) }.first
        }
        let drawing = try #require(drawingView(in: root))
        #expect(editor.tool == .move && drawing.tool == .move)
        #expect(editor.canvasPanel.collectionBehavior.contains(.canJoinAllApplications))
        #expect(editor.toolsPanel.collectionBehavior.contains(.canJoinAllApplications))
        let before = editor.imageFrame, toolbar = editor.toolsPanel.frame
        let start = editor.canvasPanel.convertPoint(toScreen: drawing.convert(CGPoint(x: 20, y: 20), to: nil))
        func event(_ type: NSEvent.EventType, dx: CGFloat, dy: CGFloat) throws -> NSEvent {
            let point = CGPoint(x: start.x + dx, y: start.y + dy)
            return try #require(NSEvent.mouseEvent(with: type, location: editor.canvasPanel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.canvasPanel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        editor.toolsPanel.makeKeyAndOrderFront(nil)
        editor.canvasPanel.sendEvent(try event(.leftMouseDown, dx: 0, dy: 0))
        editor.canvasPanel.sendEvent(try event(.leftMouseDragged, dx: horizontalMove / 2, dy: -10))
        editor.canvasPanel.sendEvent(try event(.leftMouseDragged, dx: horizontalMove, dy: -35))
        editor.canvasPanel.sendEvent(try event(.leftMouseUp, dx: horizontalMove, dy: -35))
        #expect(editor.imageFrame == before.offsetBy(dx: horizontalMove, dy: -35))
        #expect(editor.toolsPanel.frame == toolbar.offsetBy(dx: horizontalMove, dy: -35))
        #expect(editor.document.marks.isEmpty && editor.document.undoCount == 0)
        #expect(editor.document.image === original)
    }
    @Test @MainActor func hoverHelpWorksWithoutActivationAndDoesNotInterceptClicks() throws {
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 120, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let help = CaptureToolbarHelpView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        help.hint = "箭头（⇧3）"
        panel.contentView = help
        defer { help.dismissHint(); panel.close() }
        panel.orderFrontRegardless()
        help.updateTrackingAreas()
        #expect(help.trackingAreas.contains { $0.options.contains(.activeAlways) })
        #expect(help.hitTest(CGPoint(x: 14, y: 14)) == nil)
        help.showHint()
        let hint = try #require(help.hintPanel)
        #expect(hint.isVisible && hint.ignoresMouseEvents && !hint.canBecomeKey)
        help.dismissHint()
        #expect(!hint.isVisible && help.hintPanel == nil)
    }
    private func fixture(width: Int, height: Int) throws -> CGImage {
        let context = try CaptureImage.context(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
