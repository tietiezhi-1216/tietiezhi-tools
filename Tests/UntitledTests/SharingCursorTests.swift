import AppKit
import Network
import Testing
@testable import Untitled

@Suite(.serialized) struct SharingCursorTests {
    @Test func failedDisassociationCannotAcquireOrHide() throws {
        let system = CursorSystem(); system.set("detach", .failure)
        let resources = system.resources()
        #expect(throws: PluginError.self) { try resources.acquire() }
        #expect(system.calls == ["detach"] && !resources.isActive && !resources.needsRecovery)
    }
    @Test func failedHideRollsBackOnlyTheResourceActuallyOwned() throws {
        let system = CursorSystem(); system.set("hide", .failure)
        let resources = system.resources()
        #expect(throws: PluginError.self) { try resources.acquire() }
        #expect(system.calls == ["detach", "hide", "reattach"])
        #expect(!resources.isActive && !resources.needsRecovery)
    }
    @Test func releaseIsBalancedAndIdempotent() throws {
        let system = CursorSystem(), point = CGPoint(x: 50, y: 40)
        let resources = system.resources(), token = try resources.acquire()
        var sent = 0
        #expect(resources.withActiveCapture(token: token) { sent += 1 })
        #expect(resources.release(warp: point).isEmpty)
        #expect(resources.release(warp: point).isEmpty)
        #expect(system.calls == ["detach", "hide", "reattach", "warp", "show"])
        #expect(!resources.withActiveCapture(token: token) { sent += 1 } && sent == 1)
    }
    @Test func failedRecoveryRetainsOwnershipAndBlocksAnotherCapture() throws {
        let system = CursorSystem(), resources = system.resources()
        try resources.acquire(); system.set("show", .failure)
        #expect(!resources.release().isEmpty && resources.needsRecovery && !resources.isActive)
        #expect(throws: PluginError.self) { try resources.acquire() }
        system.set("show", .success); resources.expireIfStalled()
        #expect(!resources.needsRecovery && system.calls.filter { $0 == "show" }.count == 2)
        #expect(system.calls.filter { $0 == "reattach" }.count == 1)
    }
    @Test func watchdogRevokesTheOldTokenBeforeRestoringMouse() throws {
        let system = CursorSystem(), resources = system.resources()
        let old = try resources.acquire()
        system.time = 1_100_000_000; resources.expireIfStalled()
        #expect(!resources.isActive(token: old) && !resources.needsRecovery)
        #expect(!resources.withActiveCapture(token: old) { Issue.record("Stale capture forwarded") })
        let fresh = try resources.acquire()
        #expect(fresh != old && resources.isActive(token: fresh))
        resources.heartbeat(token: old)
        #expect(!resources.withActiveCapture(token: old) { Issue.record("Old watchdog generation revived") })
        resources.release()
    }
    @Test func diagnosticHardDeadlineCannotBeExtendedByHeartbeats() throws {
        let system = CursorSystem(), resources = system.resources()
        let token = try resources.acquire(maximumDuration: 1)
        system.time = 900_000_000; resources.heartbeat(token: token)
        system.time = 1_010_000_000; resources.expireIfStalled()
        #expect(!resources.isActive(token: token) && !resources.needsRecovery)
        for duration in [-1.0, .nan, .infinity, 11] {
            #expect(throws: PluginError.self) { try resources.acquire(maximumDuration: duration) }
        }
    }
    @Test @MainActor func independentHardDeadlineRestoresEvenWithMainThreadBlocked() throws {
        let system = CursorSystem()
        let resources = SharingCursorResources(calls: SharingCursorCalls(
            associate: { system.call($0 ? "reattach" : "detach") }, hide: { system.call("hide") },
            show: { system.call("show") }, warp: { _ in system.call("warp") }), watchdogEnabled: true)
        let token = try resources.acquire(maximumDuration: 0.1)
        // The test blocks only its own main thread; all CG calls above are fakes.
        Thread.sleep(forTimeInterval: 0.35)
        #expect(!resources.isActive(token: token) && !resources.needsRecovery)
        #expect(system.calls == ["detach", "hide", "reattach", "show"])
        #expect(!resources.withActiveCapture(token: token) { Issue.record("Expired diagnostic forwarded") })
    }
    @Test @MainActor func tapTimeoutReleasesTheFakeCaptureWithoutForwarding() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true })
        var sent = 0, failures = 0
        input.send = { _ in sent += 1 }; input.failure = { _ in failures += 1 }
        try await input.capture()
        #expect(!input.handle(.tapDisabledByTimeout, try motion()))
        #expect(sent == 0 && failures == 1 && input.mode == .local && !resources.isActive && !resources.needsRecovery)
        input.stop()
    }
    @Test func overdueHeartbeatAndForwardingCannotReviveBeforeWatchdogDispatch() throws {
        let system = CursorSystem(), resources = system.resources()
        let token = try resources.acquire()
        system.time = 1_010_000_000
        resources.heartbeat(token: token) // Deliberately before the watchdog gets CPU time.
        #expect(!resources.withActiveCapture(token: token) { Issue.record("Overdue heartbeat revived a lease") })
        #expect(resources.snapshot["watchdogExpired"] as? Bool == true)
        resources.expireIfStalled()
        #expect(!resources.needsRecovery)
        let second = try resources.acquire(maximumDuration: 0.1)
        system.time = 1_120_000_000
        #expect(!resources.withActiveCapture(token: second) { Issue.record("Hard deadline waited for timer dispatch") })
        resources.release()
    }
    @Test @MainActor func watchdogIsNotBlockedByAnArbitraryMainThreadSendCallback() throws {
        let system = CursorSystem(), resources = system.resources(watchdogEnabled: true, realClock: true)
        let token = try resources.acquire(maximumDuration: 0.1)
        let accepted = resources.withActiveCapture(token: token) {
            // This pre-authorized callback may be in flight, but must not hold the watchdog lock.
            Thread.sleep(forTimeInterval: 0.35)
            #expect(!resources.isActive(token: token))
            #expect(system.calls.contains("reattach") && system.calls.contains("show"))
        }
        #expect(accepted)
        #expect(!resources.withActiveCapture(token: token) { Issue.record("A NEW frame passed after recovery") })
    }
    @Test @MainActor func watchdogCanRevokeWhileACGAcquisitionCallIsStalled() async throws {
        let system = CursorSystem(), unblock = DispatchSemaphore(value: 0)
        let resources = SharingCursorResources(calls: SharingCursorCalls(associate: { connected in
            if !connected { _ = system.call("detach"); unblock.wait(); return .success }
            return system.call("reattach")
        }, hide: { system.call("hide") }, show: { system.call("show") }, warp: { _ in system.call("warp") }))
        let attempt = Task.detached { try resources.acquire(maximumDuration: 0.1) }
        #expect(await wait { system.calls.contains("detach") })
        try? await Task.sleep(for: .milliseconds(350))
        #expect(resources.snapshot["watchdogExpired"] as? Bool == true)
        unblock.signal()
        switch await attempt.result { case .success: Issue.record("Overdue CG acquisition committed"); case .failure: break }
        #expect(await wait { !resources.needsRecovery })
        #expect(!system.calls.contains("hide") && system.calls.contains("reattach"))
    }
    @Test @MainActor func failedReassociationKeepsForegroundUntilRecoveryReallyCompletes() async throws {
        let system = CursorSystem(), resources = system.resources(), focus = CursorFocus()
        let capture = SharingCursorCapture(resources: resources, focus: focus)
        try await capture.acquire(tapReady: { true }, neutral: { true })
        system.set("reattach", .failure)
        #expect(!capture.release().isEmpty)
        #expect(focus.isForeground && focus.restorations == 0 && resources.needsRecovery)
        await #expect(throws: PluginError.self) { try await capture.acquire(tapReady: { true }, neutral: { true }) }
        system.set("reattach", .success); resources.expireIfStalled()
        #expect(await wait { focus.restorations == 1 })
        #expect(!resources.needsRecovery)
    }
    @Test @MainActor func oldRecoveryRequestCannotClearANewerCaptureGeneration() async throws {
        let system = CursorSystem(), resources = system.resources(watchdogEnabled: true)
        try resources.acquire(); resources.release()
        let oldGeneration = try #require(resources.snapshot["leaseGeneration"] as? UInt64)
        let fresh = try resources.acquire()
        resources.scheduleRecovery(forGeneration: oldGeneration)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(resources.isActive(token: fresh))
        #expect(system.calls.filter { $0 == "reattach" }.count == 1)
        #expect(system.calls.filter { $0 == "show" }.count == 1)
        resources.release()
    }
    @Test @MainActor func pendingRecoveryRefusesBothEnablingAndReceiving() async throws {
        let domain = "cursor-receive-recovery-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!, system = CursorSystem(), focus = CursorFocus()
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in system.call("receiveWarp") })
        let controller = PeripheralSharingController(defaults: settings, input: input)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { system.set("reattach", .success); controller.stop(); settings.removePersistentDomain(forName: domain) }
        try controller.start(key: SharingPairingKey.generate(), localOnly: true)
        try await input.capture(); system.set("reattach", .failure)
        #expect(!input.reset().isEmpty && input.needsRecovery)
        #expect(throws: PluginError.self) { try controller.setKeyboardMouse(true) }
        #expect(throws: PluginError.self) { try input.receive(edge: .right, fraction: 0.5) }
        #expect(input.mode == .local && !controller.keyboardMouseEnabled)
        #expect(!system.calls.contains("receiveWarp")) // The fake receiver backend is never reached.
    }
    @Test @MainActor func activationRequestWithoutActualForegroundNeverTouchesCursor() async throws {
        let system = CursorSystem(), focus = CursorFocus(); focus.activationAllowed = false
        let capture = SharingCursorCapture(resources: system.resources(), focus: focus)
        await #expect(throws: PluginError.self) { try await capture.acquire(tapReady: { true }, neutral: { true }) }
        #expect(system.calls.isEmpty && !capture.isCaptured)
    }
    @Test @MainActor func successfulForegroundCaptureDetectsDriftAndRestoresFocus() async throws {
        let system = CursorSystem(), focus = CursorFocus()
        let capture = SharingCursorCapture(resources: system.resources(), focus: focus)
        try await capture.acquire(tapReady: { true }, neutral: { true })
        #expect(capture.isCaptured && focus.isForeground)
        focus.position = CGPoint(x: 60, y: 40)
        #expect(throws: PluginError.self) { try capture.validate(tapReady: true) }
        #expect(capture.maximumDrift == 10)
        #expect(capture.release().isEmpty && focus.restorations == 1 && !capture.isCaptured)
    }
    @Test @MainActor func losingForegroundNeverStealsItBack() async throws {
        let system = CursorSystem(), focus = CursorFocus()
        let capture = SharingCursorCapture(resources: system.resources(), focus: focus)
        try await capture.acquire(tapReady: { true }, neutral: { true })
        focus.isForeground = false
        #expect(throws: PluginError.self) { try capture.validate(tapReady: true) }
        capture.release()
        #expect(focus.restorations == 0 && !system.calls.contains("warp"))
    }
    @Test @MainActor func foregroundAloneCannotPassTheFinalActivationBarrier() async {
        let barrier = SharingActivationBarrier(); var clock: UInt64 = 0, ticks = 0
        let ready = await barrier.wait(isForeground: { true }, keyWindowReady: { true }, now: { clock }, tick: {
            ticks += 1; clock += 15_000_000
            if ticks == 2 { barrier.complete(true) }
        })
        #expect(ready && ticks == 3) // Two early frontmost ticks, then a completed, settled tick.
        let changed = SharingActivationBarrier(); changed.complete(true); var front = true
        #expect(!(await changed.wait(isForeground: { front }, keyWindowReady: { true }, tick: { front = false })))
        let rejected = SharingActivationBarrier(); rejected.complete(false)
        #expect(!(await rejected.wait(isForeground: { true }, keyWindowReady: { true })))
        let missing = SharingActivationBarrier(); clock = 0
        #expect(!(await missing.wait(isForeground: { true }, keyWindowReady: { true }, now: { clock }, tick: { clock += 100_000_000 })))
    }
    @Test @MainActor func captureAnchorStartsAfterCGOwnershipNotBeforeDisassociation() async throws {
        let focus = CursorFocus()
        let resources = SharingCursorResources(calls: SharingCursorCalls(associate: { associate in
            if !associate { MainActor.assumeIsolated { focus.position = CGPoint(x: 125, y: 40) } }
            return .success
        }, hide: { .success }, show: { .success }, warp: { _ in .success }), watchdogEnabled: false)
        let capture = SharingCursorCapture(resources: resources, focus: focus)
        try await capture.acquire(tapReady: { true }, neutral: { true })
        #expect(capture.isCaptured && capture.maximumDrift == 0)
        focus.position = CGPoint(x: 126, y: 40)
        #expect(throws: PluginError.self) { try capture.validate(tapReady: true) }
        capture.release()
    }
    @Test @MainActor func stagedCaptureCoalescesMotionWithoutForwardingBeforeCommit() async throws {
        let system = CursorSystem(), focus = CursorFocus(); focus.delayActivation = true
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true })
        var packets: [SharingInputPacket] = []; input.send = { packets.append($0) }
        let task = Task { try await input.capture(deferForwarding: true) }
        #expect(await wait { focus.continuation != nil })
        #expect(input.handle(.mouseMoved, try motion()) && packets.isEmpty && system.calls.isEmpty)
        focus.completeActivation(); try await task.value
        #expect(input.isStaged && !input.isCapturing)
        #expect(input.handle(.mouseMoved, try motion()) && packets.isEmpty)
        try input.beginForwarding()
        #expect(input.isCapturing && packets == [.init(kind: .move, x: 10)])
        input.stop()
    }
    @Test @MainActor func stagedCaptureNeverFlushesAfterResetDriftOrForeignInjection() async throws {
        for reason in 0..<3 {
            let system = CursorSystem(), focus = CursorFocus()
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true })
            var packets = 0; input.send = { _ in packets += 1 }
            try await input.capture(deferForwarding: true); _ = input.handle(.mouseMoved, try motion())
            if reason == 0 { input.reset() }
            else if reason == 1 { focus.position = CGPoint(x: 60, y: 40); input.maintainCapture() }
            else { let foreign = try motion(); foreign.setIntegerValueField(.eventSourceUnixProcessID, value: 123); _ = input.handle(.mouseMoved, foreign) }
            #expect(throws: PluginError.self) { try input.beginForwarding() }
            #expect(input.mode == .local && packets == 0)
            input.stop()
        }
    }
    @Test @MainActor func typingDuringActivationCancelsEvenAfterACompleteDownUpAndWaitsForLateFocusRecovery() async throws {
        let system = CursorSystem(), focus = CursorFocus(); focus.delayActivation = true
        var posted: [CGEvent] = [], packets = 0, task: Task<Void, Error>?
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, eventPoster: { posted.append($0) })
        input.returnLocal = { [weak input] _ in task?.cancel(); input?.reset() }; input.send = { _ in packets += 1 }
        task = Task { try await input.capture(deferForwarding: true) }
        #expect(await wait { focus.continuation != nil })
        focus.delayRestoration = true; focus.waitForLateRestoration = true
        let key = try motion(); key.type = .keyDown; #expect(input.handle(.keyDown, key))
        key.type = .keyUp; #expect(input.handle(.keyUp, key) && input.isNeutral)
        #expect(await wait { focus.restoreContinuation != nil })
        #expect(posted.isEmpty && packets == 0)
        focus.completeActivation()
        switch await task!.result { case .success: Issue.record("Typing did not cancel pending capture"); case .failure: break }
        #expect(!focus.isForeground && system.calls.isEmpty && posted.isEmpty)
        focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
        #expect(await wait { posted.count == 2 })
        #expect(packets == 0 && input.mode == .local)
        input.returnLocal = { _ in }; input.stop()
    }
    @Test @MainActor func typingWhileStagedCancelsAndWaitsForOriginalFocusBeforeLocalReplay() async throws {
        let system = CursorSystem(), focus = CursorFocus(); var posted: [CGEvent] = [], packets = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, eventPoster: { posted.append($0) })
        input.returnLocal = { [weak input] _ in input?.reset() }; input.send = { _ in packets += 1 }
        try await input.capture(deferForwarding: true); focus.delayRestoration = true
        let key = try motion(); key.type = .keyDown
        #expect(input.handle(.keyDown, key) && !input.isNeutral)
        #expect(await wait { focus.restoreContinuation != nil })
        #expect(posted.isEmpty && packets == 0 && !input.isCapturing)
        focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
        #expect(await wait { posted.count == 1 })
        #expect(throws: PluginError.self) { try input.beginForwarding() }
        #expect(!input.handle(try #require(posted.first).type, try #require(posted.first)))
        input.stop()
    }
    @Test @MainActor func canceledDelayedActivationCannotHideOrDetachAfterReturn() async throws {
        let system = CursorSystem(), focus = CursorFocus(); focus.delayActivation = true
        let capture = SharingCursorCapture(resources: system.resources(), focus: focus)
        let task = Task { try await capture.acquire(tapReady: { true }, neutral: { true }) }
        while focus.continuation == nil { await Task.yield() }
        capture.release(); task.cancel(); focus.completeActivation()
        switch await task.result { case .success: Issue.record("Stale activation acquired capture"); case .failure: break }
        #expect(system.calls.isEmpty && !capture.isCaptured && focus.restorations == 1)
    }
    @Test @MainActor func senderNeverForwardsMotionAfterCursorDriftOrWatchdogRecovery() async throws {
        for watchdog in [false, true] {
            let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
            let capture = SharingCursorCapture(resources: resources, focus: focus)
            let input = SharingInput(cursor: capture, tapReadyOverride: { true })
            var sent = 0, failures = 0
            input.send = { _ in sent += 1 }; input.failure = { _ in failures += 1 }
            try await input.capture()
            if watchdog { system.time = 1_100_000_000; resources.expireIfStalled() }
            else { focus.position = CGPoint(x: 55, y: 40) }
            #expect(!input.handle(.mouseMoved, try motion()))
            #expect(sent == 0 && failures == 1 && input.mode == .local && !resources.needsRecovery)
            input.stop()
        }
    }
    @Test @MainActor func replayIsAllowedButUnknownInjectionRevokesSending() async throws {
        let system = CursorSystem(), focus = CursorFocus()
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true })
        var sent = 0, failures = 0
        input.send = { _ in sent += 1 }; input.failure = { _ in failures += 1 }
        try await input.capture()
        let own = try motion(); own.setIntegerValueField(.eventSourceUserData, value: SharingInput.replayMarker)
        own.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(!input.handle(.mouseMoved, own) && input.isCapturing && failures == 0)
        #expect(input.handle(.mouseMoved, try motion()) && sent == 1)
        let foreign = try motion(); foreign.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(!input.handle(.mouseMoved, foreign) && failures == 1 && sent == 1 && input.mode == .local)
        input.stop()
    }
    @Test @MainActor func normalReentryIsImmediateButRejectedHandoffsKeepBoundedBackoff() throws {
        let system = CursorSystem(), focus = CursorFocus(); var clock = 100.0, requests = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, handoffClock: { clock })
        input.edge = .right; input.requestControl = { _, _ in requests += 1 }; input.canSwitch = true
        let event = try motion(); event.location = CGPoint(x: SharingInput.bounds.maxX - 1, y: SharingInput.bounds.midY)
        _ = input.handle(.mouseMoved, event); #expect(requests == 1)
        _ = input.handle(.mouseMoved, event); #expect(requests == 1) // No per-packet request storm.
        input.reset(handoffDelay: 0); input.canSwitch = true
        _ = input.handle(.mouseMoved, event); #expect(requests == 2) // Same clock: no 650 ms wait after success.
        input.reset(handoffDelay: 0.65); input.canSwitch = true
        clock += 0.64; _ = input.handle(.mouseMoved, event); #expect(requests == 2)
        clock += 0.02; _ = input.handle(.mouseMoved, event); #expect(requests == 3)
        input.stop()
    }
    @Test @MainActor func newlyReceivingCursorCanReturnImmediatelyWhenDirectionReallyReverses() throws {
        let system = CursorSystem(), focus = CursorFocus(); var returns = 0, posts = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { _ in posts += 1 }, handoffClock: { 100 })
        input.returnAcrossEdge = { _ in returns += 1 }
        try input.receive(edge: .right, fraction: 0.5) // Enters left at x + 4.
        input.apply(.init(kind: .move, x: -20)) // A real reversal, not continuing entry motion.
        #expect(returns == 1 && posts == 0)
        input.stop()
    }
    @Test @MainActor func controllerCancellationDoesNotCommitALateAcceptedCapture() async throws {
        let domain = "cursor-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!, system = CursorSystem(), focus = CursorFocus()
        focus.delayActivation = true
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true })
        let controller = PeripheralSharingController(defaults: defaults, input: input), peer = SharingTransport()
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        peer.connected = { peer.send(.init(kind: .hello, version: 1, deviceID: UUID().uuidString, name: "No-injection peer")) }
        var packets = 0
        peer.received = { message in
            if message.kind == .begin { peer.send(.init(kind: .accepted)) }
            if message.kind == .input { packets += 1 }
        }
        defer { controller.stop(); peer.stop(); defaults.removePersistentDomain(forName: domain) }
        let key = try SharingPairingKey.generate()
        try controller.start(key: key, localOnly: true); try peer.start(key: SharingPairingKey.decode(key), name: "cursor-peer", localOnly: true)
        #expect(await wait { controller.transport.port != nil && peer.port != nil })
        try controller.connect(host: "127.0.0.1", port: String(try #require(peer.port).rawValue))
        #expect(await wait { controller.peerName != nil })
        try controller.setKeyboardMouse(true); controller.toggleControl()
        #expect(await wait { focus.continuation != nil })
        #expect(controller.control == .requesting && packets == 0)
        controller.returnToLocal(); focus.completeActivation()
        #expect(await wait { focus.restorations == 1 })
        #expect(controller.control == .local && system.calls.isEmpty && packets == 0)
    }
    @Test @MainActor func diagnosticProducesMotionEvidenceButNeverOpensNetworkOrEmitsInput() async throws {
        let domain = "cursor-diagnostic-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!, system = CursorSystem(), focus = CursorFocus()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true })
        let controller = PeripheralSharingController(defaults: settings, input: input)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { controller.stop(); settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        try controller.startCursorDiagnostic(confirmation: { true }, delay: .zero, maximumDuration: 0.4, reportDirectory: directory)
        #expect(await wait { input.isCapturing })
        #expect(input.handle(.mouseMoved, try motion()))
        #expect(!controller.isRunning && controller.transport.port == nil && controller.sentInputPackets == 0)
        #expect(await wait { !controller.isCursorDiagnostic })
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cursor-test.json"))) as? [String: Any])
        #expect(report["zeroNetworkInput"] as? Bool == true)
        #expect(report["wouldForwardPackets"] as? Int == 1)
        #expect(report["physicalMouseMovements"] as? Int == 1)
        #expect(report["visualConfirmation"] as? String == "not-collected")
        #expect(report["ownsHiddenCursor"] as? Bool == false && report["ownsDisassociation"] as? Bool == false)
        #expect(report["result"] as? String == "position-lock-verified-needs-visual-confirmation")
    }
    @Test @MainActor func diagnosticNeverPassesWhenPositionRestorationFails() async throws {
        let domain = "cursor-warp-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: domain)!
        let system = CursorSystem(), focus = CursorFocus()
        system.set("warp", .failure)
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true })
        let controller = PeripheralSharingController(defaults: settings, input: input)
        controller.isAllowed = { true }; controller.requirePermissions = { _ in }
        defer { controller.stop(); settings.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        try controller.startCursorDiagnostic(confirmation: { true }, delay: .zero, maximumDuration: 0.4, reportDirectory: directory)
        #expect(await wait { input.isCapturing }); _ = input.handle(.mouseMoved, try motion())
        #expect(await wait { !controller.isCursorDiagnostic })
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cursor-test.json"))) as? [String: Any])
        #expect(report["result"] as? String == "failed-or-cancelled")
        #expect(!(report["cleanupErrors"] as? [String] ?? []).isEmpty)
        #expect(report["zeroNetworkInput"] as? Bool == true)
    }
    @Test @MainActor func returnedReceiverOwnsHiddenCursorUntilRealLocalActivity() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        var posted = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in posted += 1 })
        try input.receive(edge: .left, fraction: 0.5)
        try await input.parkAfterReturn()
        #expect(input.mode == .parked && resources.isActive && resources.snapshot["ownsHiddenCursor"] as? Bool == true)
        focus.delayRestoration = true
        let event = try motion(); event.type = .scrollWheel
        #expect(input.handle(.scrollWheel, event))
        #expect(await wait { focus.restoreContinuation != nil })
        #expect(!resources.isActive && posted == 0 && input.mode == .local)
        focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
        #expect(await wait { posted == 1 })
        #expect(system.calls.filter { $0 == "hide" }.count == 1 && system.calls.filter { $0 == "show" }.count == 1)
        input.stop()
    }
    @Test @MainActor func parkingDrainsReceiverReplayBeforeAnchoringAndDropsLateDuplicates() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        var events: [CGEvent] = [], failures = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true },
            receiverWarp: { focus.position = $0; return .success }, eventPoster: { events.append($0) })
        input.failure = { _ in failures += 1 }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        let original = try #require(focus.position)
        input.apply(.init(kind: .move, x: -75))
        let motion = try #require(events.first)
        #expect(motion.location != original)
        let parking = Task { try await input.parkAfterReturn() }
        try await Task.sleep(for: .milliseconds(15))
        #expect(input.mode == .receiving && !resources.isActive && !system.calls.contains("detach"))
        // Fake WindowServer delivers the queued event only after the return began.
        #expect(!input.handle(motion.type, motion)); focus.position = motion.location
        try await parking.value
        input.maintainCapture()
        #expect(input.isParked && failures == 0)
        // A delayed duplicate may not move the parked cursor or a new receiver.
        #expect(input.handle(motion.type, motion))
        #expect(input.isParked && input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 0)
    }
    @Test @MainActor func receiverReplayCannotCrossAResetOrNewHandoff() throws {
        let system = CursorSystem(), focus = CursorFocus()
        var events: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        input.apply(.init(kind: .move, x: -75))
        let old = try #require(events.first)
        input.reset(); try input.receive(edge: .right, fraction: 0.5)
        #expect(input.handle(old.type, old))
        input.apply(.init(kind: .move, x: 75))
        let fresh = try #require(events.last)
        #expect(!input.handle(fresh.type, fresh))
        #expect(input.handle(old.type, old))
        #expect(input.safetyDiagnostics["droppedStaleReceiverEvents"] as? Int == 2)
    }
    @Test @MainActor func physicalDownAndUpDuringReplayDrainCancelParking() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        var events: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -75))
        let task = Task { try await input.parkAfterReturn() }
        try await Task.sleep(for: .milliseconds(15))
        let event = try motion(); event.type = .keyDown; _ = input.handle(.keyDown, event)
        event.type = .keyUp; _ = input.handle(.keyUp, event)
        #expect(input.isNeutral)
        for replay in events { _ = input.handle(replay.type, replay) }
        switch await task.result { case .success: Issue.record("A complete local key cycle did not cancel parking"); case .failure: break }
        #expect(!resources.isActive && !system.calls.contains("detach"))
    }
    @Test @MainActor func stalledReceiverReplayCannotAcquireAParkingLease() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { _ in })
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -75))
        await #expect(throws: PluginError.self) { try await input.parkAfterReturn() }
        #expect(!resources.isActive && !system.calls.contains("detach") && !system.calls.contains("hide"))
    }
    @Test @MainActor func stopDuringReplayDrainCannotReacquireOrPrepareAReceiver() async throws {
        for prepare in [false, true] {
            let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
            let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true },
                receiverWarp: { _ in .success }, eventPoster: { _ in })
            try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .move, x: -75)); input.reset()
            let task = Task {
                if prepare { try await input.prepareReceiving(edge: .right, fraction: 0.5, deferPointer: true) }
                else { try await input.capture() }
            }
            try await Task.sleep(for: .milliseconds(15)); input.stop()
            switch await task.result { case .success: Issue.record("Stop was ignored during replay drain"); case .failure: break }
            #expect(!resources.isActive && system.calls.isEmpty && input.mode == .local)
            #expect(throws: PluginError.self) { try input.commitReceiving() }
        }
    }
    @Test @MainActor func cleanupKeyUpIsNeverDiscardedWithStaleReceiverKeyDown() throws {
        let system = CursorSystem(), focus = CursorFocus()
        var events: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        try input.receive(edge: .left, fraction: 0.5); input.apply(.init(kind: .keyDown, code: 0))
        let down = try #require(events.first)
        #expect(!input.handle(down.type, down))
        input.reset(); let up = try #require(events.last)
        #expect(up.type == .keyUp)
        input.stop()
        #expect(!input.handle(up.type, up) && input.handle(down.type, down))
    }
    @Test @MainActor func cancelledQueuedUpStillReleasesADownThatAlreadyPassedTheTap() throws {
        for pair: (SharingInputPacket, SharingInputPacket) in [
            (.init(kind: .keyDown, code: 0), .init(kind: .keyUp, code: 0)),
            (.init(kind: .flags, code: 55, pressed: true), .init(kind: .flags, code: 55, pressed: false)),
            (.init(kind: .down, code: 0), .init(kind: .up, code: 0))
        ] {
            let system = CursorSystem(), focus = CursorFocus(); var events: [CGEvent] = []
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true },
                receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
            try input.receive(edge: .left, fraction: 0.5); input.apply(pair.0)
            let down = try #require(events.last); #expect(!input.handle(down.type, down))
            input.apply(pair.1); let up = try #require(events.last)
            input.reset()
            #expect(events.count == 3) // Desired state is neutral, but delivered down still needs cleanup.
            let cleanup = try #require(events.last)
            #expect(input.handle(up.type, up) && !input.handle(cleanup.type, cleanup))
            #expect(input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 0)
            input.stop()
        }
    }
    @Test @MainActor func receiverReplayQueueIsBoundedAndFailsClosed() throws {
        let system = CursorSystem(), focus = CursorFocus()
        var events: [CGEvent] = [], failures = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true },
            receiverWarp: { _ in .success }, eventPoster: { events.append($0) })
        input.failure = { _ in failures += 1 }
        defer { input.stop() }
        try input.receive(edge: .left, fraction: 0.5)
        for _ in 0..<513 { input.apply(.init(kind: .move, x: -1)) }
        #expect(events.count == 512 && input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 512)
        #expect(input.mode == .local && failures == 1)
        for event in events { #expect(input.handle(event.type, event)) }
        #expect(input.safetyDiagnostics["queuedReceiverEvents"] as? Int == 0)
    }
    @Test @MainActor func nextCaptureWaitsForGenuineLocalRepostsBeforeChangingFocus() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources(); var posted: [CGEvent] = []
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { posted.append($0) })
        try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn()
        #expect(input.handle(.mouseMoved, try motion()))
        #expect(await wait { posted.count == 1 })
        let task = Task { try await input.capture(deferForwarding: true) }
        try await Task.sleep(for: .milliseconds(15))
        #expect(input.mode == .local && !resources.isActive && system.calls.filter { $0 == "detach" }.count == 1)
        let event = try #require(posted.first); #expect(!input.handle(event.type, event))
        try await task.value; #expect(input.isStaged)
        input.stop()
    }
    @Test @MainActor func stoppedOrOverflowedLocalResumeNeverReplaysAnOldPrefix() async throws {
        for overflow in [false, true] {
            let system = CursorSystem(), focus = CursorFocus(); var posted = 0
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in posted += 1 })
            try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn(); focus.delayRestoration = true
            let event = try motion(); event.type = .scrollWheel
            #expect(input.handle(.scrollWheel, event)); #expect(await wait { focus.restoreContinuation != nil })
            if overflow { for _ in 0..<129 { _ = input.handle(.scrollWheel, event) } }
            else { input.stop() }
            focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
            try? await Task.sleep(for: .milliseconds(25))
            #expect(posted == 0 && input.safetyDiagnostics["queuedLocalEvents"] as? Int == 0)
            input.stop()
        }
    }
    @Test @MainActor func physicalActivityDuringReceivePreparationCancelsEvenAfterKeyUp() async throws {
        for keyboard in [false, true] {
            let system = CursorSystem(), focus = CursorFocus(); var warps = 0
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in warps += 1; return .success }, eventPoster: { _ in })
            try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn(); focus.delayRestoration = true
            let task = Task { try await input.prepareReceiving(edge: .right, fraction: 0.5) }
            #expect(await wait { focus.restoreContinuation != nil })
            let event = try motion()
            if keyboard {
                event.type = .keyDown; _ = input.handle(.keyDown, event)
                event.type = .keyUp; _ = input.handle(.keyUp, event)
                #expect(input.isNeutral)
            } else { _ = input.handle(.mouseMoved, event) }
            focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
            switch await task.result { case .success: Issue.record("Local activity did not cancel preparation"); case .failure: break }
            #expect(input.mode == .local && warps == 1)
            input.stop()
        }
    }
    @Test @MainActor func bufferedPhysicalDownRemainsHeldAndWrongFocusNeverReceivesReplay() async throws {
        for correctFocus in [true, false] {
            let system = CursorSystem(), focus = CursorFocus(); var posted = 0
            let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in posted += 1 })
            try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn(); focus.delayRestoration = true
            let event = try motion(); event.type = .keyDown
            #expect(input.handle(.keyDown, event) && !input.isNeutral)
            #expect(await wait { focus.restoreContinuation != nil })
            focus.localReplayAllowed = correctFocus
            focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
            try? await Task.sleep(for: .milliseconds(25))
            #expect(posted == (correctFocus ? 1 : 0) && !input.isNeutral)
            await #expect(throws: PluginError.self) { try await input.capture() }
            event.type = .keyUp; _ = input.handle(.keyUp, event); #expect(input.isNeutral)
            input.stop()
        }
    }
    @Test @MainActor func receivingAgainWaitsForParkedFocusRestoration() async throws {
        let system = CursorSystem(), focus = CursorFocus(); var warps = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in warps += 1; return .success })
        try input.receive(edge: .left, fraction: 0.5); try await input.parkAfterReturn()
        focus.delayRestoration = true
        let task = Task { try await input.prepareReceiving(edge: .right, fraction: 0.25) }
        #expect(await wait { focus.restoreContinuation != nil })
        #expect(input.mode == .local && warps == 1)
        focus.restoreContinuation?.resume(returning: true); focus.restoreContinuation = nil
        try await task.value
        #expect(input.mode == .receiving && warps == 2)
        input.stop()
    }
    @Test @MainActor func receiverPointerWaitsForCommitAndCancelledPreparationCannotWarp() async throws {
        let system = CursorSystem(), focus = CursorFocus(); var warps = 0
        let input = SharingInput(cursor: SharingCursorCapture(resources: system.resources(), focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in warps += 1; return .success }, eventPoster: { _ in })
        try await input.prepareReceiving(edge: .left, fraction: 0.5, deferPointer: true)
        #expect(warps == 0 && input.mode == .local)
        try input.commitReceiving(); #expect(warps == 1 && input.mode == .receiving)
        input.reset(); try await input.prepareReceiving(edge: .right, fraction: 0.5, deferPointer: true)
        _ = input.handle(.mouseMoved, try motion())
        #expect(throws: PluginError.self) { try input.commitReceiving() }
        #expect(warps == 1)
        input.stop()
    }
    @Test @MainActor func physicalActivityDuringParkingActivationCancelsTheReturn() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        try input.receive(edge: .left, fraction: 0.5); focus.delayActivation = true
        let task = Task { try await input.parkAfterReturn() }
        #expect(await wait { focus.continuation != nil })
        _ = input.handle(.mouseMoved, try motion()); focus.completeActivation()
        switch await task.result { case .success: Issue.record("Parking committed despite physical input"); case .failure: break }
        #expect(input.mode == .local && !resources.isActive && !resources.needsRecovery)
        input.stop()
    }
    @Test @MainActor func failedParkingRollsBackInsteadOfPretendingTheCursorIsHidden() async throws {
        let system = CursorSystem(), focus = CursorFocus(), resources = system.resources()
        system.set("hide", .failure)
        let input = SharingInput(cursor: SharingCursorCapture(resources: resources, focus: focus), tapReadyOverride: { true }, receiverWarp: { _ in .success })
        try input.receive(edge: .left, fraction: 0.5)
        await #expect(throws: PluginError.self) { try await input.parkAfterReturn() }
        #expect(input.mode == .local && !resources.isActive && !resources.needsRecovery)
        #expect(system.calls.contains("reattach") && !system.calls.contains("show"))
        input.stop()
    }
    @Test func allPhysicalActivityCanTakeBackAReceiverIncludingScrollDragAndRelease() {
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                 .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel] {
            #expect(SharingInput.isPhysicalActivity(type))
        }
        #expect(!SharingInput.isPhysicalActivity(.tapDisabledByTimeout) && !SharingInput.isPhysicalActivity(.null))
    }
    @Test func normalReturnMustHaveAValidHandoffIdentity() throws {
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, returned: true).validate() }
        #expect(throws: PluginError.self) { try SharingMessage(kind: .end, handoffID: "bad", returned: true).validate() }
        try SharingMessage(kind: .end, handoffID: UUID().uuidString, returned: true).validate()
        try SharingMessage(kind: .end).validate() // Explicit all-local emergency remains supported.
    }
    @Test @MainActor func sourceCaptureAndPeerRestorationPrepareConcurrentlyButCommitWaitsForBoth() async throws {
        let one = "overlap-a-\(UUID().uuidString)", two = "overlap-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorFocus(), fb = CursorFocus()
        let ia = SharingInput(cursor: SharingCursorCapture(resources: sa.resources(), focus: fa), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let ib = SharingInput(cursor: SharingCursorCapture(resources: sb.resources(), focus: fb), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let a = PeripheralSharingController(defaults: da, input: ia, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, inputAccessAvailable: { true })
        for controller in [a,b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true && b.peerKeyboardMouseEnabled == true })
        // UUID stamp tie-breaking may otherwise choose either mirrored direction.
        a.setLayoutEdge(.right)
        #expect(await wait { a.layoutReady && b.layoutReady && a.edge == .right && b.edge == .left })
        try ib.receive(edge: .left, fraction: 0.5); try await ib.parkAfterReturn()
        fa.delayActivation = true; fb.delayRestoration = true
        a.toggleControl()
        #expect(await wait { fa.continuation != nil && fb.restoreContinuation != nil })
        #expect(ia.handle(.mouseMoved, try motion()) && a.sentInputPackets == 0)
        fa.completeActivation()
        #expect(await wait { ia.isStaged })
        #expect(a.control == .requesting && a.sentInputPackets == 0 && b.receivedInputPackets == 0)
        #expect(ia.handle(.mouseMoved, try motion()))
        fb.restoreContinuation?.resume(returning: true); fb.restoreContinuation = nil
        #expect(await wait { a.control == .controlling && b.control == .receiving && b.receivedInputPackets == 1 })
        #expect(a.sentInputPackets == 1 && ia.isCapturing)
    }
    @Test @MainActor func peerSafetyPauseIsVisibleWithoutDisconnectOrAutomaticReenable() async throws {
        let one = "pause-a-\(UUID().uuidString)", two = "pause-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorFocus(), fb = CursorFocus()
        let ia = SharingInput(cursor: SharingCursorCapture(resources: sa.resources(), focus: fa), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let ib = SharingInput(cursor: SharingCursorCapture(resources: sb.resources(), focus: fb), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let a = PeripheralSharingController(defaults: da, input: ia, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, inputAccessAvailable: { true })
        for controller in [a,b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true && b.peerKeyboardMouseEnabled == true })
        // Reproduce a safety pause using fake focus/cursor calls only.
        try await ib.capture(); fb.position = CGPoint(x: 125, y: 40); ib.maintainCapture()
        #expect(await wait { a.peerKeyboardMouseEnabled == false })
        #expect(a.peerName != nil && b.peerName != nil && a.layoutReady && b.layoutReady)
        #expect(a.status.contains("对端键鼠共享已暂停") && !b.keyboardMouseEnabled)
        a.toggleControl(); #expect(a.control == .local && !sa.calls.contains("detach"))
        a.returnToLocal()
        try await Task.sleep(for: .milliseconds(25))
        #expect(b.status.contains("暂停") && b.inputStatus != nil && !b.keyboardMouseEnabled)
        try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true })
        a.toggleControl(); #expect(await wait { a.control == .controlling && b.control == .receiving })
    }
    @Test @MainActor func normalReturnParksReceiverButEmergencyAndFreshHandoffReleaseIt() async throws {
        let one = "park-a-\(UUID().uuidString)", two = "park-b-\(UUID().uuidString)"
        let da = UserDefaults(suiteName: one)!, db = UserDefaults(suiteName: two)!
        let sa = CursorSystem(), sb = CursorSystem(), fa = CursorFocus(), fb = CursorFocus()
        let ia = SharingInput(cursor: SharingCursorCapture(resources: sa.resources(), focus: fa), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let ib = SharingInput(cursor: SharingCursorCapture(resources: sb.resources(), focus: fb), tapReadyOverride: { true }, receiverWarp: { _ in .success }, eventPoster: { _ in })
        let a = PeripheralSharingController(defaults: da, input: ia, inputAccessAvailable: { true })
        let b = PeripheralSharingController(defaults: db, input: ib, inputAccessAvailable: { true })
        for controller in [a,b] { controller.isAllowed = { true }; controller.requirePermissions = { _ in } }
        defer { a.stop(); b.stop(); da.removePersistentDomain(forName: one); db.removePersistentDomain(forName: two) }
        let key = try SharingPairingKey.generate()
        try a.start(key: key, localOnly: true); try b.start(key: key, localOnly: true)
        #expect(await wait { a.transport.port != nil && b.transport.port != nil })
        try a.connect(host: "127.0.0.1", port: String(try #require(b.transport.port).rawValue))
        #expect(await wait { a.layoutReady && b.layoutReady })
        try a.setKeyboardMouse(true); try b.setKeyboardMouse(true)
        #expect(await wait { a.peerKeyboardMouseEnabled == true && b.peerKeyboardMouseEnabled == true })
        a.status = "old failure"; a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(a.status != "old failure")
        ib.returnAcrossEdge(.init(x: 0.5, y: 0.5))
        #expect(await wait { a.control == .local && ib.mode == .parked })
        #expect(sb.calls.contains("hide") && !sb.calls.contains("show"))
        a.returnToLocal() // Emergency even though A has already regained local control.
        #expect(await wait { ib.mode == .local && sb.calls.contains("show") })
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        a.transport.send(.init(kind: .end, handoffID: UUID().uuidString))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(b.control == .receiving) // A stale end cannot release the fresh handoff.
        ib.returnAcrossEdge(.init(x: 0.5, y: 0.5))
        #expect(await wait { a.control == .local && ib.mode == .parked })
        a.toggleControl()
        #expect(await wait { a.control == .controlling && b.control == .receiving })
        #expect(sb.calls.filter { $0 == "hide" }.count == sb.calls.filter { $0 == "show" }.count)
    }
    @MainActor private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
    private func motion() throws -> CGEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 50, y: 40), mouseButton: .left))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setDoubleValueField(.mouseEventDeltaX, value: 5)
        return event // In-memory fixture only: never posted to the OS.
    }
}

private final class CursorSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [String] = []
    private var errors: [String: CGError] = [:]
    private var clock: UInt64 = 0
    var calls: [String] { lock.withLock { history } }
    var time: UInt64 { get { lock.withLock { clock } } set { lock.withLock { clock = newValue } } }
    func set(_ action: String, _ result: CGError) { lock.withLock { errors[action] = result } }
    func call(_ action: String) -> CGError { lock.withLock { history.append(action); return errors[action] ?? .success } }
    func resources(watchdogEnabled: Bool = false, realClock: Bool = false) -> SharingCursorResources {
        SharingCursorResources(calls: SharingCursorCalls(associate: { [self] in call($0 ? "reattach" : "detach") },
            hide: { [self] in call("hide") }, show: { [self] in call("show") }, warp: { [self] _ in call("warp") }),
            watchdogEnabled: watchdogEnabled, now: { [self] in realClock ? DispatchTime.now().uptimeNanoseconds : time })
    }
}
@MainActor private final class CursorFocus: SharingCursorFocus {
    var isForeground = false
    var position: CGPoint? = CGPoint(x: 50, y: 40)
    var activationAllowed = true
    var delayActivation = false
    var continuation: CheckedContinuation<Bool, Never>?
    private var previousWasOurs = false
    var restorations = 0
    var delayRestoration = false
    var waitForLateRestoration = false
    var localReplayAllowed = true
    var restoreContinuation: CheckedContinuation<Bool, Never>?
    func awaitRestoration() async -> Bool {
        if delayRestoration, restorations > 0 || waitForLateRestoration { return await withCheckedContinuation { restoreContinuation = $0 } }
        return true
    }
    func acquireForeground() async -> Bool {
        previousWasOurs = isForeground
        if delayActivation { return await withCheckedContinuation { continuation = $0 } }
        isForeground = activationAllowed
        return isForeground
    }
    func completeActivation() { isForeground = true; continuation?.resume(returning: true); continuation = nil }
    func restoreForeground() {
        if !previousWasOurs && isForeground { restorations += 1; isForeground = false }
    }
}
