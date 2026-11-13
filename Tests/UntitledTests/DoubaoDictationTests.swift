import AppKit
import Carbon
import Foundation
import Testing
@testable import Untitled

@Suite(.serialized) struct DoubaoDictationTests {
    @Test func utf16SelectionAndFinalRevisionOwnOnlyTheDictationSpan() throws {
        let original = "前😀选中后"
        let selected = (original as NSString).range(of: "选中")
        var anchor = try DictationTextAnchor(value: original, selection: selected)
        let draft = try anchor.replacement("下午三点", value: original, selected: selected)
        #expect(draft == "前😀下午三点后")
        anchor.commit("下午三点")
        #expect(anchor.range == NSRange(location: selected.location, length: 4))
        let final = try anchor.replacement("下午 3 点。", value: draft, selected: anchor.expectedSelection)
        #expect(final == "前😀下午 3 点。后")
        #expect(throws: DictationTargetError.self) {
            try anchor.replacement("新文字", value: draft + "手改", selected: anchor.expectedSelection)
        }
        #expect(throws: DictationTargetError.self) {
            try anchor.replacement("新文字", value: draft, selected: NSRange(location: 0, length: 0))
        }
        #expect(throws: DictationTargetError.self) {
            try DictationTextAnchor(value: "小", selection: NSRange(location: 2, length: Int.max))
        }
    }

    @Test func hotkeyRepeatsAndReleasesAreBalanced() {
        var presses = HotKeyPressState()
        let transitions = [presses.transition(1, pressed: false), presses.transition(1, pressed: true),
                           presses.transition(1, pressed: true), presses.transition(1, pressed: false),
                           presses.transition(1, pressed: false), presses.transition(2, pressed: true),
                           presses.transition(3, pressed: true)]
        #expect(transitions == [false, true, false, true, false, true, true])
        let releases = presses.clear(), empty = presses.clear()
        let staleRelease = presses.transition(2, pressed: false)
        #expect(releases == [2, 3])
        #expect(empty.isEmpty)
        #expect(!staleRelease)
    }

    @Test @MainActor func nativeCarbonReleaseEventsAndRebindingBalanceHolds() throws {
        _ = NSApplication.shared
        let manager = HotKeyManager()
        defer { manager.clear() }
        var downs = 0, ups = 0
        try manager.register(HotKey(keyCode: UInt32(kVK_F20), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "F20"),
                             onRelease: { ups += 1 }) { downs += 1 }
        func send(_ kind: UInt32) throws {
            var raw: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &raw) == noErr)
            let event = try #require(raw)
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x554E544C, id: 1)
            #expect(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
            #expect(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
        }
        try send(UInt32(kEventHotKeyPressed)); try send(UInt32(kEventHotKeyPressed))
        try send(UInt32(kEventHotKeyReleased)); try send(UInt32(kEventHotKeyReleased))
        #expect(downs == 1 && ups == 1)
        try send(UInt32(kEventHotKeyPressed))
        manager.clear()
        #expect(downs == 2 && ups == 2)
        try send(UInt32(kEventHotKeyReleased))
        #expect(ups == 2)
    }

    @Test @MainActor func unverifiedProductionInputRefusesBeforePermissionOrCapture() throws {
        let controller = DoubaoDictationController(showsHUD: false)
        var permissionChecks = 0
        controller.isAllowed = { true }
        controller.requirePermissions = { _ in permissionChecks += 1; throw HostPermissionError.missing }
        #expect(!controller.realtimeInputVerified && controller.preferences.liveInput)
        #expect(throws: PluginError.self) { try controller.toggle() }
        #expect(throws: PluginError.self) { try controller.holdPressed(UUID()) }
        #expect(permissionChecks == 0 && controller.phase == .idle && !controller.isPreviewing)
        #expect(controller.notice == DoubaoDictationController.realtimeInputUnavailable)
        #expect(controller.preferences.liveInput)
    }

    @Test func oldPreferencesNeverOptIntoExperimentalInputDuringUpgrade() throws {
        let data = Data(#"{"liveInput":false,"maximumSeconds":60}"#.utf8)
        let preferences = try JSONDecoder().decode(DictationPreferences.self, from: data)
        #expect(!preferences.experimentalRealtimeInput && !preferences.liveInput && preferences.maximumSeconds == 60 && preferences.inputDeviceUID == nil)
        #expect(try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }

    @Test func existingSelfTestPreferenceSurvivesAddingInputDeviceSelection() throws {
        let data = Data(#"{"liveInput":true,"maximumSeconds":180,"experimentalRealtimeInput":true}"#.utf8)
        let preferences = try JSONDecoder().decode(DictationPreferences.self, from: data)
        #expect(preferences.liveInput && preferences.experimentalRealtimeInput && preferences.inputDeviceUID == nil)
        let selected = DictationPreferences(liveInput: true, maximumSeconds: 60, experimentalRealtimeInput: true, inputDeviceUID: "test.input")
        #expect(try JSONDecoder().decode(DictationPreferences.self, from: JSONEncoder().encode(selected)) == selected)
    }

    @Test @MainActor func explicitSelfTestingEnablesInputWithoutClaimingVerification() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.controller(realtimeInputVerified: false)
        controller.isAllowed = { true }
        var required: [Set<HostPermissionID>] = []
        controller.requirePermissions = { required.append($0) }
        var preferences = controller.preferences; preferences.liveInput = false
        try controller.savePreferences(preferences)
        try controller.setExperimentalRealtimeInput(true)
        #expect(!controller.realtimeInputVerified && controller.realtimeInputAvailable)
        #expect(controller.preferences.liveInput && controller.preferences.experimentalRealtimeInput)
        #expect(required.isEmpty && dependencies.sessions.isEmpty && dependencies.microphones.isEmpty)
        try controller.holdPressed(UUID())
        try await wait { controller.phase == .listening }
        #expect(!controller.isPreviewing && required.first == [.microphone, .accessibility])
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(!dependencies.target.writes.isEmpty)
        try controller.setExperimentalRealtimeInput(false)
        #expect(!controller.realtimeInputAvailable && controller.preferences.liveInput)
        #expect(throws: PluginError.self) { try controller.toggle() }
        #expect(dependencies.sessions.count == 1)
    }

    @Test @MainActor func microphoneSelectionIsLazyAndPreservedOnCancel() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        var settings = controller.preferences; settings.inputDeviceUID = "test.microphone"
        try controller.savePreferences(settings)
        #expect(dependencies.microphones.isEmpty && dependencies.sessions.isEmpty)
        try controller.toggle(previewOnly: true)
        try await wait { controller.phase == .listening }
        #expect(dependencies.microphones[0].configuredUID == "test.microphone")
        controller.cancel()
        #expect(dependencies.microphones[0].stopped > 0 && controller.preferences.inputDeviceUID == "test.microphone")
        for invalid in ["", "\u{0}", String(repeating: "x", count: 1025)] {
            settings.inputDeviceUID = invalid
            #expect(throws: PluginError.self) { try settings.validate() }
        }
    }

    @Test @MainActor func emptyRecognitionKeepsCaptureDiagnosticsAfterStopping() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle(previewOnly: true)
        try await wait { controller.phase == .listening }
        dependencies.microphones[0].currentDiagnostics = .init(inputName: "Test input", callbacks: 4, capturedBytes: 1280, peakRMS: 0)
        dependencies.sessions[0].finalText = ""
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(controller.audioDiagnostics?.capturedBytes == 1280)
        #expect(controller.notice.contains("静音音频"))
        #expect(dependencies.microphones[0].stopped > 0)
    }

    @Test @MainActor func emptyFinalCannotMaskTheEarlierInputFailure() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].finalText = ""
        dependencies.target.changed = true
        dependencies.sessions[0].onTranscript?("待校验")
        try await wait { controller.phase == .idle }
        #expect(controller.notice == DictationTargetError.changed.localizedDescription)
    }

    @Test @MainActor func unverifiedRuntimeOnlyAllowsExplicitOrConfiguredPreview() async throws {
        for explicitPreview in [true, false] {
            let dependencies = Dependencies()
            let controller = dependencies.controller(realtimeInputVerified: false)
            controller.isAllowed = { true }
            var required: [Set<HostPermissionID>] = []
            controller.requirePermissions = { required.append($0) }
            if !explicitPreview {
                var preferences = controller.preferences; preferences.liveInput = false
                try controller.savePreferences(preferences)
            }
            try controller.toggle(previewOnly: explicitPreview)
            try await wait { controller.phase == .listening }
            #expect(controller.isPreviewing && dependencies.target.writes.isEmpty)
            try controller.toggle(previewOnly: explicitPreview)
            try await wait { controller.phase == .idle }
            #expect(required.allSatisfy { $0 == [.microphone] })
            #expect(dependencies.target.writes.isEmpty && dependencies.microphones[0].stopped > 0)
            #expect(controller.preferences.liveInput == explicitPreview)
        }
    }

    @Test @MainActor func permissionsAndSecureFieldsFailBeforeCreatingAnySession() throws {
        let dependencies = Dependencies()
        let controller = dependencies.controller()
        controller.isAllowed = { true }
        controller.requirePermissions = { _ in throw HostPermissionError.missing }
        #expect(throws: HostPermissionError.self) { try controller.toggle() }
        #expect(dependencies.sessions.isEmpty && dependencies.microphones.isEmpty)
        controller.requirePermissions = { _ in }
        dependencies.secure = true
        #expect(throws: DictationTargetError.self) { try controller.toggle() }
        #expect(dependencies.sessions.isEmpty)
        #expect(controller.phase == .idle)
    }

    @Test @MainActor func toggleStreamsThenReplacesWithFinalAndReleasesResources() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = try #require(dependencies.sessions.first)
        session.onTranscript?("下午三点")
        try await wait { dependencies.target.writes.last == "下午三点" }
        try controller.toggle()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes.last == "下午 3 点。")
        #expect(controller.lastResult == "下午 3 点。")
        #expect(session.finished == 1 && session.cancelled > 0)
        #expect(dependencies.microphones[0].stopped > 0)
    }

    @Test @MainActor func emptyFinalNeverErasesDraftOrClaimsSuccessfulPolishing() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].finalText = ""
        dependencies.sessions[0].onTranscript?("中间草稿")
        try await wait { dependencies.target.writes.last == "中间草稿" }
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(controller.transcript == "中间草稿")
        #expect(dependencies.target.writes.last == "中间草稿")
        #expect(controller.notice.contains("草稿"))
    }

    @Test @MainActor func holdReleaseDuringConnectingFinishesTheCapturedShortUtterance() async throws {
        let dependencies = Dependencies()
        dependencies.startDelay = .milliseconds(150)
        let controller = dependencies.allowedController()
        let command = UUID()
        try controller.holdPressed(command)
        #expect(dependencies.microphones.first?.started == 1)
        try await wait { dependencies.sessions.first?.started == 1 }
        controller.holdReleased(command)
        #expect(controller.phase == .finishing)
        #expect(dependencies.microphones.first?.stopped == 1)
        try await wait { controller.phase == .idle }
        #expect(dependencies.microphones.first?.started == 1)
        #expect(dependencies.sessions.first?.finished == 1)
        #expect(dependencies.sessions.first?.sentBytes == 640)
    }

    @Test @MainActor func cancelWhileConnectingNeverRestartsAudioOrWritesALateFinal() async throws {
        let dependencies = Dependencies()
        dependencies.suspendStart = true
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { dependencies.sessions.first?.started == 1 }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.phase == .idle)
        #expect(dependencies.microphones.first?.started == 1)
        #expect(dependencies.microphones.first?.stopped == 1)
        #expect(dependencies.sessions.first?.finished == 0)
        #expect(dependencies.sessions.first?.cancelled == 1)
        #expect(dependencies.target.writes.isEmpty)
    }

    @Test @MainActor func holdOwnsItsSessionAndDoesNotStopAnExistingToggle() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        let command = UUID()
        try controller.holdPressed(command)
        try await wait { controller.phase == .listening }
        controller.holdReleased(UUID())
        #expect(controller.phase == .listening)
        controller.holdReleased(command)
        try await wait { controller.phase == .idle }
        try controller.toggle()
        try await wait { controller.phase == .listening }
        try controller.holdPressed(command)
        controller.holdReleased(command)
        #expect(controller.phase == .listening)
        #expect(dependencies.sessions.count == 2)
        controller.cancel()
    }

    @Test @MainActor func unsupportedEditorFailsBeforeCaptureUnlessPreviewWasExplicit() async throws {
        let dependencies = Dependencies()
        dependencies.unsupported = true
        let controller = dependencies.allowedController()
        #expect(throws: DictationTargetError.self) { try controller.toggle() }
        #expect(dependencies.sessions.isEmpty && dependencies.microphones.isEmpty)
        try controller.toggle(previewOnly: true)
        try await wait { controller.phase == .listening }
        #expect(controller.isPreviewing)
        dependencies.sessions[0].onTranscript?("仅预览")
        #expect(controller.transcript == "仅预览")
        #expect(dependencies.target.writes.isEmpty)
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(controller.lastResult == "下午 3 点。")
        #expect(controller.acknowledgedTextLength == 0)
    }

    @Test @MainActor func externalEditStopsWritingAndOldCallbacksCannotReachANewSession() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let stale = dependencies.sessions[0].onTranscript
        dependencies.target.changed = true
        dependencies.sessions[0].onTranscript?("不应强行输入")
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes.isEmpty)
        #expect(controller.notice.contains("改变"))
        dependencies.target.changed = false
        try controller.toggle()
        try await wait { controller.phase == .listening }
        stale?("过期回调")
        #expect(controller.transcript.isEmpty)
        #expect(dependencies.target.writes.isEmpty)
        controller.cancel()
    }

    @Test @MainActor func lateValidationFromCancelledSessionCannotStopANewSession() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        defer { controller.cancel() }
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.target.suspendNextValidation = true
        try await wait { dependencies.target.validationIsSuspended }
        controller.cancel()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.target.resumeValidation(failing: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .listening)
        #expect(dependencies.sessions.count == 2 && dependencies.sessions[1].cancelled == 0)
        #expect(dependencies.microphones[1].stopped == 0)
    }

    @Test @MainActor func finishingRevisionsAreObservedButOnlyTheFinalIsCommitted() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = dependencies.sessions[0]
        session.onTranscript?("明天下午三点")
        try await wait { dependencies.target.writes.last == "明天下午三点" }
        let before = dependencies.target.writes.count
        session.finishUpdates = ["明天下午三点，", "明天下午 3 点，开会"]
        session.finalText = "明天下午 3 点，开会。"
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(Array(dependencies.target.writes.dropFirst(before)) == [session.finalText])
        #expect(dependencies.target.finalCalls == 1)
    }

    @Test @MainActor func stoppingDropsTheThrottledPartialInsteadOfRewritingItBeforeFinal() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = dependencies.sessions[0]
        session.onTranscript?("已上屏草稿")
        try await wait { dependencies.target.writes.count == 1 }
        session.onTranscript?("不应再单独写入的中间稿")
        session.finishDelay = .milliseconds(220)
        session.finalText = "只提交这一次定稿。"
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes == ["已上屏草稿", session.finalText])
        #expect(dependencies.target.finalCalls == 1)
    }

    @Test @MainActor func finalWaitsForAnAlreadyIssuedPartialAcknowledgement() async throws {
        let dependencies = Dependencies()
        dependencies.target.delay = .milliseconds(120)
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        let session = dependencies.sessions[0]
        session.onTranscript?("已发出的草稿")
        try await wait { dependencies.target.writeCalls == 1 }
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes == ["已发出的草稿", session.finalText])
        #expect(dependencies.target.finalCalls == 1 && dependencies.target.maximumConcurrentWrites == 1)
    }

    @Test @MainActor func cancelDuringFinalAcknowledgementNeverReplaysIt() async throws {
        let dependencies = Dependencies()
        dependencies.target.delay = .seconds(5)
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        controller.stopRecording()
        try await wait { dependencies.target.finalCalls == 1 }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.phase == .idle && dependencies.target.writes.isEmpty)
        #expect(dependencies.target.finalCalls == 1)
    }

    @Test @MainActor func partialsCoalesceBehindOneAcknowledgedWriterAndFinalFlushes() async throws {
        let dependencies = Dependencies()
        dependencies.target.delay = .milliseconds(100)
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].onTranscript?("草")
        try await wait { dependencies.target.writeCalls == 1 }
        for value in ["草稿", "草稿再修", "草稿最终版"] { dependencies.sessions[0].onTranscript?(value) }
        controller.stopRecording()
        try await wait { controller.phase == .idle }
        #expect(dependencies.target.writes.first == "草")
        #expect(dependencies.target.writes.last == "下午 3 点。")
        #expect(!dependencies.target.writes.contains("草稿再修"))
        #expect(dependencies.target.writeCalls <= 3)
        #expect(controller.acknowledgedTextLength == "下午 3 点。".utf16.count)
    }

    @Test @MainActor func cancellationCancelsAnUnacknowledgedInputWrite() async throws {
        let dependencies = Dependencies()
        dependencies.target.delay = .seconds(5)
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].onTranscript?("不要迟到写入")
        try await wait { dependencies.target.writeCalls == 1 }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(dependencies.target.writes.isEmpty)
        #expect(controller.acknowledgedTextLength == 0)
    }

    @Test @MainActor func networkFailureAndPermissionRevocationStopAudio() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        try controller.toggle()
        try await wait { controller.phase == .listening }
        dependencies.sessions[0].onFailure?(PluginError.invalid("模拟断网"))
        #expect(controller.phase == .idle)
        #expect(dependencies.microphones[0].stopped > 0)
        #expect(controller.notice == "模拟断网")
        try controller.toggle()
        try await wait { controller.phase == .listening }
        controller.requirePermissions = { _ in throw HostPermissionError.missing }
        try await wait { controller.phase == .idle }
        #expect(dependencies.microphones[1].stopped > 0)
        #expect(dependencies.sessions[1].cancelled > 0)
    }

    @Test @MainActor func installDisableUpgradeAndUninstallAreLazyAndKeepUserBindings() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = Dependencies()
        let center = permissionCenter()
        let store = PluginStore(directory: root, permissions: center,
                                dictationFactory: { dependencies.controller(preferencesURL: $0) })
        let manifest = try pluginManifest()
        try store.installManifest(manifest)
        #expect(dependencies.sessions.isEmpty)
        #expect(store.installed[0].commands.count == 3)
        #expect(Set(store.installed[0].commands.compactMap { $0.hotKey?.identity }).count == 3)
        let controller = store.doubaoDictation(for: manifest.id)
        var settings = controller.preferences
        settings.liveInput = false
        try controller.savePreferences(settings)
        let command = store.installed[0].commands[0]
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id)
        try await wait { controller.phase == .listening }
        store.setEnabled(false, pluginID: manifest.id)
        #expect(controller.phase == .idle)
        #expect(dependencies.sessions[0].cancelled > 0)
        #expect(dependencies.microphones[0].stopped > 0)
        store.setEnabled(true, pluginID: manifest.id)
        var edited = command; edited.hotKey = nil
        try store.saveCommand(edited, pluginID: manifest.id)
        try store.installManifest(manifest)
        #expect(store.installed[0].commands.first(where: { $0.id == edited.id })?.hotKey == nil)
        #expect(store.doubaoDictation(for: manifest.id).preferences.liveInput == false)
        try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id)
        try await wait { controller.phase == .listening }
        #expect(await store.prepareForQuit())
        #expect(controller.phase == .idle)
        #expect(throws: PluginError.self) { try store.performDictationAction(.toggleDoubaoDictation, pluginID: manifest.id) }
        store.uninstall(manifest.id)
        #expect(store.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.id + ".json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Preferences/" + manifest.id + ".dictation.json").path))
    }

    @Test @MainActor func tenCancelCyclesReleaseEachSessionAndMicrophone() async throws {
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        for _ in 0..<10 {
            try controller.toggle()
            try await wait { controller.phase == .listening }
            controller.cancel()
            #expect(controller.phase == .idle)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(dependencies.sessions.count == 10)
        #expect(dependencies.sessions.allSatisfy { $0.cancelled == 1 && $0.onTranscript == nil && $0.onFailure == nil })
        #expect(dependencies.microphones.allSatisfy { $0.started == 1 && $0.stopped > 0 })
    }

    @Test @MainActor func blackAndWhiteHUDNeverTakesKeyboardFocus() async throws {
        _ = NSApplication.shared
        let dependencies = Dependencies()
        let controller = dependencies.allowedController()
        let hud = DictationHUD()
        let key = NSApp.keyWindow
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hud.show(controller: controller)
        defer { hud.close() }
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue == "doubao.dictation.hud" })
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.frame.size == NSSize(width: 72, height: 30))
        #expect(window.ignoresMouseEvents)
        #expect(NSApp.keyWindow === key)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
        if let path = ProcessInfo.processInfo.environment["UNTITLED_DICTATION_HUD_PREVIEW"],
           let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    @Test @MainActor func nativeCapabilityRequiresCorrectHostAndPermissionDeclarations() throws {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        try PluginComposition.makeUIRegistry().validate(manifest)
        try permissionCenter().validate(manifest)
        #expect(!ActionKind.toggleDoubaoDictation.isScreenshotAction)
        #expect(!ActionKind.holdDoubaoDictation.isScreenshotAction)
        #expect(!ActionKind.cancelDoubaoDictation.isScreenshotAction)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["minimumHostVersion"] = "0.9.7"
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: PluginError.self) { try JSONDecoder().decode(PluginManifest.self, from: oldData).validate() }
    }

    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Plugins/doubao-speech-input/manifest.json")
    }
    private func pluginManifest() throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PluginError.invalid("等待模拟听写状态超时。")
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor private func permissionCenter() -> HostPermissionCenter {
        HostPermissionCenter(drivers: [HostPermissionID.microphone, .accessibility].map { id in
            HostPermissionDriver(descriptor: .init(id: id, title: id.rawValue, summary: "测试", symbol: "checkmark"),
                                 status: { .authorized }, request: {}, openSettings: {})
        })
    }

    @MainActor private final class Dependencies {
        var sessions: [Session] = []
        var microphones: [Microphone] = []
        let target = Target()
        var secure = false, unsupported = false, suspendStart = false
        var startDelay: Duration = .zero
        func controller(preferencesURL: URL? = nil, realtimeInputVerified: Bool = true) -> DoubaoDictationController {
            DoubaoDictationController(preferencesURL: preferencesURL, showsHUD: false, realtimeInputVerified: realtimeInputVerified, makeSession: { [self] in
                let session = Session(); session.suspendStart = suspendStart; session.startDelay = startDelay; sessions.append(session); return session
            }, makeMicrophone: { [self] in
                let microphone = Microphone(); microphones.append(microphone); return microphone
            }, makeTarget: { [self] in
                if secure { throw DictationTargetError.secure }
                if unsupported { throw DictationTargetError.unavailable }
                return target
            })
        }
        func allowedController() -> DoubaoDictationController {
            let result = controller(); result.isAllowed = { true }; result.requirePermissions = { _ in }; return result
        }
    }
    @MainActor private final class Session: DoubaoSpeechSession {
        var onTranscript: ((String) -> Void)?
        var onFailure: ((Error) -> Void)?
        var started = 0, cancelled = 0, finished = 0, sentBytes = 0
        var suspendStart = false
        var finalText = "下午 3 点。"
        var finishUpdates: [String] = []
        var finishDelay: Duration = .zero
        var startDelay: Duration = .zero
        func start() async throws {
            started += 1
            if suspendStart { try await Task.sleep(for: .seconds(60)) }
            if startDelay > .zero { try await Task.sleep(for: startDelay) }
        }
        func send(_ pcm: Data) async throws { sentBytes += pcm.count }
        func finish() async throws -> String {
            finished += 1
            for text in finishUpdates { onTranscript?(text); try await Task.sleep(for: .milliseconds(20)) }
            if finishDelay > .zero { try await Task.sleep(for: finishDelay) }
            if !finalText.isEmpty { onTranscript?(finalText) }
            return finalText
        }
        func cancel() { cancelled += 1; onTranscript = nil; onFailure = nil }
    }
    @MainActor private final class Microphone: DictationAudioSource {
        var started = 0, stopped = 0
        var buffered = Data()
        var configuredUID: String?
        var currentDiagnostics: DictationAudioDiagnostics?
        var diagnostics: DictationAudioDiagnostics? { currentDiagnostics }
        func configureInputDevice(_ uid: String?) throws { configuredUID = uid }
        func start() throws { started += 1; buffered = Data(repeating: 0, count: 640) }
        func read() throws -> (pcm: Data, level: Float) { let value = buffered; buffered = Data(); return (value, 0) }
        func setStreaming() {}
        func validateBuffer() throws {}
        func stop() { stopped += 1 }
    }
    @MainActor private final class Target: DictationTextInserting {
        var writes: [String] = []
        var changed = false
        var delay: Duration = .zero
        private(set) var writeCalls = 0
        private(set) var finalCalls = 0
        private(set) var maximumConcurrentWrites = 0
        private var activeWrites = 0
        var suspendNextValidation = false
        var validationIsSuspended: Bool { validation != nil }
        private var validation: CheckedContinuation<Bool, Never>?
        func validate() async throws {
            if suspendNextValidation {
                suspendNextValidation = false
                let failing = await withCheckedContinuation { validation = $0 }
                if failing { throw DictationTargetError.changed }
            }
            if changed { throw DictationTargetError.changed }
        }
        func resumeValidation(failing: Bool) {
            let pending = validation; validation = nil
            pending?.resume(returning: failing)
        }
        func commitFinal(_ text: String) async throws {
            finalCalls += 1
            try await update(text)
        }
        func update(_ text: String) async throws {
            writeCalls += 1; activeWrites += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
            defer { activeWrites -= 1 }
            if delay > .zero { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            try await validate(); writes.append(text)
        }
    }
}
