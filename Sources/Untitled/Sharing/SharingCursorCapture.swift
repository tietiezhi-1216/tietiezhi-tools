import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation

struct SharingCursorCalls: Sendable {
    var associate: @Sendable (Bool) -> CGError = { CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) }
    var hide: @Sendable () -> CGError = { CGDisplayHideCursor(CGMainDisplayID()) }
    var show: @Sendable () -> CGError = { CGDisplayShowCursor(CGMainDisplayID()) }
    var warp: @Sendable (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) }
}

/// Metadata never holds a lock across CG calls or an arbitrary send callback. The
/// watchdog can revoke a lease even if such a call stalls. CG recovery is serialized
/// separately; recovery still requires a responsive WindowServer, not hard realtime.
final class SharingCursorResources: @unchecked Sendable {
    private let lock = NSLock()
    private let operations = NSRecursiveLock()
    private let calls: SharingCursorCalls
    private let now: @Sendable () -> UInt64
    private let watchdogEnabled: Bool
    private let queue = DispatchQueue(label: "com.untitled.app.cursor-safety", qos: .userInteractive)
    private let recoveryQueue = DispatchQueue(label: "com.untitled.app.cursor-recovery", qos: .userInteractive)
    private var watchdog: DispatchSourceTimer?
    private var hidden = false, detached = false, active = false, acquiring = false
    private var revoked = true, recoveryQueued = false, shuttingDown = false
    private var leaseID: UInt64 = 0, lastHeartbeat: UInt64 = 0
    private var hardDeadline: UInt64?
    private var timedOut = false
    private var results: [String: Int32] = [:]
    private var errors: [String: String] = [:]
    private var recovered: (@Sendable () -> Void)?

    init(calls: SharingCursorCalls = SharingCursorCalls(), watchdogEnabled: Bool = true,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.calls = calls; self.watchdogEnabled = watchdogEnabled; self.now = now
    }
    deinit { shuttingDown = true; _ = release(); watchdog?.cancel() }
    var isActive: Bool { eligible(token: locked { leaseID }) }
    var needsRecovery: Bool { locked { acquiring || recoveryQueued || (!active && (detached || hidden)) } }
    func onRecovery(_ callback: @escaping @Sendable () -> Void) { locked { recovered = callback } }
    func isActive(token: UInt64) -> Bool { eligible(token: token) }
    var snapshot: [String: Any] {
        locked { ["active": active && !revoked && !expiredLocked(), "ownsHiddenCursor": hidden,
                  "ownsDisassociation": detached, "watchdogExpired": timedOut, "leaseGeneration": leaseID,
                  "apiResults": results, "cleanupErrors": errors.values.sorted(), "recoveryPending": recoveryQueued || acquiring] }
    }
    @discardableResult func acquire(maximumDuration: TimeInterval? = nil) throws -> UInt64 {
        operations.lock()
        defer { operations.unlock(); finishWatchdogIfIdle(); notifyRecovery() }
        let token: UInt64 = try locked {
            guard !active, !acquiring, !recoveryQueued, !detached, !hidden else { throw PluginError.invalid("上次光标恢复尚未完成，已阻止再次接管。") }
            if let maximumDuration, !maximumDuration.isFinite || maximumDuration <= 0 || maximumDuration > 10 { throw PluginError.invalid("接管诊断必须在十秒内自动结束。") }
            leaseID &+= 1; revoked = false; acquiring = true
            lastHeartbeat = now(); hardDeadline = maximumDuration.map { lastHeartbeat + UInt64($0 * 1_000_000_000) }
            results = [:]; errors = [:]; timedOut = false
            return leaseID
        }
        ensureWatchdog()
        do {
            let associate = calls.associate(false)
            locked { results["detach"] = associate.rawValue; detached = associate == .success }
            guard associate == .success else { throw PluginError.invalid("无法独占本机鼠标（解除关联：\(associate.rawValue)），未转发输入。") }
            guard locked({ token == leaseID && !revoked && !expiredLocked() }) else { throw CancellationError() }
            let hide = calls.hide()
            locked { results["hide"] = hide.rawValue; hidden = hide == .success }
            guard hide == .success else { throw PluginError.invalid("无法隐藏本机光标（\(hide.rawValue)），已取消接管。") }
            let committed = locked {
                acquiring = false
                guard token == leaseID, !revoked, !expiredLocked() else { revokeLocked(); return false }
                active = true; lastHeartbeat = now(); return true
            }
            guard committed else { throw CancellationError() }
            if watchdogEnabled, let deadline = locked({ hardDeadline }) {
                queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in self?.expireDeadline(token: token) }
            }
            return token
        } catch {
            locked { acquiring = false; revokeLocked() }
            _ = cleanup(warp: nil)
            throw error
        }
    }
    func heartbeat(token: UInt64) {
        let recoveryGeneration: UInt64? = locked {
            guard token == leaseID, active, !revoked else { return nil }
            guard !expiredLocked() else { timedOut = true; revokeLocked(); return leaseID }
            lastHeartbeat = now(); return nil
        }
        if let recoveryGeneration { scheduleRecovery(forGeneration: recoveryGeneration) }
    }
    /// An issued frame can already be in flight when revocation occurs. Do not hold
    /// watchdog metadata hostage to encoding/network callbacks; the transport also
    /// rechecks the same lease immediately before enqueueing an input frame.
    @discardableResult func withActiveCapture(token: UInt64, _ action: () -> Void) -> Bool {
        guard eligible(token: token) else { return false }
        action(); return true
    }
    private func eligible(token: UInt64) -> Bool {
        let state = locked { () -> (Bool, UInt64?) in
            guard token == leaseID, active, !revoked, hidden, detached else { return (false, nil) }
            if expiredLocked() { timedOut = true; revokeLocked(); return (false, leaseID) }
            return (true, nil)
        }
        if let generation = state.1 { scheduleRecovery(forGeneration: generation) }
        return state.0
    }
    private func expiredLocked() -> Bool {
        let instant = now()
        return hardDeadline.map { instant >= $0 } == true || (instant >= lastHeartbeat && instant - lastHeartbeat > 1_000_000_000)
    }
    private func revokeLocked() {
        active = false
        if !revoked { leaseID &+= 1; revoked = true }
    }
    func expireIfStalled() {
        let recoveryGeneration: UInt64? = locked {
            if !revoked, (active || acquiring), expiredLocked() { timedOut = true; revokeLocked() }
            return revoked && (acquiring || detached || hidden) ? leaseID : nil
        }
        if let recoveryGeneration {
            if watchdogEnabled { scheduleRecovery(forGeneration: recoveryGeneration) }
            else { _ = release() } // Deterministic fake-clock tests never need dispatch timers.
        }
    }
    private func expireDeadline(token: UInt64) {
        let recoveryGeneration: UInt64? = locked {
            guard token == leaseID, !revoked, let hardDeadline, now() >= hardDeadline else { return nil }
            timedOut = true; revokeLocked(); return leaseID
        }
        if let recoveryGeneration { scheduleRecovery(forGeneration: recoveryGeneration) }
    }
    @discardableResult func release(warp: CGPoint? = nil) -> [String] {
        locked { revokeLocked() }
        operations.lock(); let result = cleanup(warp: warp); operations.unlock()
        finishWatchdogIfIdle(); notifyRecovery()
        return result
    }
    /// Called only with the CG operation lock, never with the metadata lock held.
    private func cleanup(warp: CGPoint?) -> [String] {
        let owned = locked { detached || hidden }
        if locked({ detached }) {
            let result = calls.associate(true)
            locked { results["reattach"] = result.rawValue; if result == .success { detached = false; errors.removeValue(forKey: "reattach") } else { errors["reattach"] = "恢复鼠标关联：\(result.rawValue)" } }
        }
        if let warp, owned {
            let result = calls.warp(warp)
            locked { results["restorePosition"] = result.rawValue; if result == .success { errors.removeValue(forKey: "warp") } else { errors["warp"] = "恢复光标位置：\(result.rawValue)" } }
        }
        if locked({ hidden }) {
            let result = calls.show()
            locked { results["show"] = result.rawValue; if result == .success { hidden = false; errors.removeValue(forKey: "show") } else { errors["show"] = "恢复光标显示：\(result.rawValue)" } }
        }
        ensureWatchdog()
        return locked { errors.values.sorted() }
    }
    func scheduleRecovery(forGeneration generation: UInt64) {
        guard watchdogEnabled else { return }
        let queued = locked {
            guard generation == leaseID, revoked, !active, acquiring || detached || hidden,
                  !shuttingDown, !recoveryQueued else { return false }
            recoveryQueued = true; return true
        }
        guard queued else { return }
        recoveryQueue.async { [weak self] in
            guard let self else { return }
            self.operations.lock()
            if self.locked({ generation == self.leaseID && self.revoked && !self.active }) { _ = self.cleanup(warp: nil) }
            self.operations.unlock()
            self.locked { self.recoveryQueued = false }
            self.finishWatchdogIfIdle(); self.notifyRecovery()
        }
    }
    private func ensureWatchdog() {
        guard watchdogEnabled else { return }
        locked {
            guard !shuttingDown, watchdog == nil, active || acquiring || detached || hidden else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.expireIfStalled() }
            watchdog = timer; timer.resume()
        }
    }
    private func finishWatchdogIfIdle() {
        locked {
            if !active, !acquiring, !detached, !hidden, !recoveryQueued { watchdog?.cancel(); watchdog = nil }
        }
    }
    private func notifyRecovery() {
        let callback = locked { !active && !acquiring && !detached && !hidden && !recoveryQueued ? recovered : nil }
        callback?()
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
}

@MainActor protocol SharingCursorFocus: AnyObject {
    var isForeground: Bool { get }
    var position: CGPoint? { get }
    var diagnostics: [String: Any] { get }
    func acquireForeground() async -> Bool
    func restoreForeground()
    func awaitRestoration() async -> Bool
    var localReplayAllowed: Bool { get }
}
extension SharingCursorFocus {
    var localReplayAllowed: Bool { true }
    var diagnostics: [String: Any] { [:] }
    func awaitRestoration() async -> Bool { true }
}

/// A frontmost PID alone is not activation completion. One settled main-loop
/// turn after the final LaunchServices reply/key window prevents hiding against
/// a foreground transition that is still being committed by AppKit.
@MainActor final class SharingActivationBarrier {
    private var completion: Bool?
    func complete(_ succeeded: Bool) { if completion == nil { completion = succeeded } }
    func wait(isForeground: () -> Bool, keyWindowReady: () -> Bool,
              now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
              tick: () async -> Void = { try? await Task.sleep(for: .milliseconds(15)) }) async -> Bool {
        let deadline = now() + 600_000_000
        while now() < deadline, !Task.isCancelled {
            if completion == false { return false }
            if completion == true, isForeground(), keyWindowReady() {
                await tick()
                return !Task.isCancelled && completion == true && isForeground() && keyWindowReady()
            }
            await tick()
        }
        return false
    }
}

@MainActor final class SharingNativeCursorFocus: SharingCursorFocus {
    static private(set) var capturingForInput = false
    private var previous: NSRunningApplication?
    private var activationPending = false, undoLateActivation = false
    private var restoration = "not-requested"
    private var restoreTask: Task<Void, Never>?
    private var activeObserver: AnyCancellable?
    private var captureWindow: SharingCaptureFocusWindow?
    private var temporarilyHiddenWindows: [NSWindow] = []
    private var activationResult: OSStatus?
    private var focusEpoch: UInt64 = 0, restoreRevision: UInt64 = 0
    init() {
        activeObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.undoLateActivation == true { self?.restoreForeground() } } }
    }
    var isForeground: Bool { NSApplication.shared.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    var position: CGPoint? { CGEvent(source: nil)?.location }
    var localReplayAllowed: Bool { restoration == "verified" || restoration == "not-requested" }
    var diagnostics: [String: Any] {
        ["focusRestore": restoration, "lateActivationPending": undoLateActivation,
         "captureWindow": captureWindow?.isVisible == true, "activationResult": activationResult ?? 0]
    }
    func acquireForeground() async -> Bool {
        focusEpoch &+= 1; restoreRevision &+= 1
        restoreTask?.cancel(); undoLateActivation = false; activationPending = false
        restoration = "not-requested"
        if isForeground { previous = nil; return true }
        previous = NSWorkspace.shared.frontmostApplication; activationPending = true
        // The UI may remain behind another app. Give the input lease its own tiny
        // key window, not the main panel; restore the previous app on release.
        temporarilyHiddenWindows = NSApplication.shared.orderedWindows.filter {
            $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel) && $0.canBecomeKey
        }
        temporarilyHiddenWindows.forEach { $0.orderOut(nil) }
        let window = SharingCaptureFocusWindow(contentRect: NSRect(x: 8, y: 8, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.alphaValue = 0.001; window.hasShadow = false; window.ignoresMouseEvents = true; window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        captureWindow = window; Self.capturingForInput = true
        window.makeKeyAndOrderFront(nil)
        // Request LaunchServices activation of this existing signed application.
        // The delegate suppresses only the main-window reopen during this lease.
        // No deprecated force-activation flags or separate helper identity.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false; configuration.promptsUserIfNeeded = false
        let barrier = SharingActivationBarrier(), epoch = focusEpoch
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            let code: OSStatus = error == nil ? 0 : -1
            Task { @MainActor in
                guard let self, self.focusEpoch == epoch else { return }
                self.activationResult = code; barrier.complete(code == 0)
            }
        }
        let ready = await barrier.wait(isForeground: { self.isForeground }, keyWindowReady: {
            self.captureWindow?.isKeyWindow == true && NSApplication.shared.keyWindow === self.captureWindow
        })
        if ready { activationPending = false }
        return ready
    }
    func restoreForeground() {
        guard let previous else { return }
        guard isForeground else {
            if activationPending {
                undoLateActivation = true; restoration = "waiting-for-late-activation"
                restoreTask?.cancel(); restoreRevision &+= 1
                restoreTask = Task { @MainActor [weak self] in
                    let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
                    while DispatchTime.now().uptimeNanoseconds < deadline, !Task.isCancelled {
                        guard let self else { return }
                        if self.isForeground { self.restoreForeground(); return }
                        await self.waitForFocusTick()
                    }
                    guard !Task.isCancelled, let self else { return }
                    // Do not leave regular windows hidden after a rejected request.
                    self.restoreWindows(); self.restoration = "activation-not-completed"
                }
            }
            else { self.previous = nil; restoration = "user-selected-other"; restoreWindows() }
            return
        }
        undoLateActivation = false; activationPending = false; self.previous = nil
        guard !previous.isTerminated, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else { restoration = "previous-unavailable"; restoreWindows(); return }
        NSApplication.shared.yieldActivation(to: previous)
        guard previous.activate(options: []) else { restoration = "request-rejected"; restoreWindows(); return }
        restoration = "request-sent"; restoreRevision &+= 1
        restoreTask = Task { @MainActor [weak self] in
            let deadline = DispatchTime.now().uptimeNanoseconds + 600_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline, !Task.isCancelled {
                guard let self else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front == previous.processIdentifier { self.restoration = "verified"; self.restoreWindows(); return }
                if front != ProcessInfo.processInfo.processIdentifier { self.restoration = "user-selected-other"; self.restoreWindows(); return }
                await self.waitForFocusTick()
            }
            if !Task.isCancelled { self?.restoration = "not-verified"; self?.restoreWindows() }
        }
    }
    func awaitRestoration() async -> Bool {
        let epoch = focusEpoch
        while true {
            let revision = restoreRevision, task = restoreTask
            await task?.value
            guard epoch == focusEpoch, !Task.isCancelled else { return false }
            if revision != restoreRevision { continue } // Late activation installed a second verification task.
            return ["not-requested", "verified", "user-selected-other"].contains(restoration)
        }
    }
    private func restoreWindows() {
        Self.capturingForInput = false
        captureWindow?.orderOut(nil); captureWindow?.close(); captureWindow = nil
        temporarilyHiddenWindows.reversed().forEach { $0.orderBack(nil) }
        temporarilyHiddenWindows.removeAll()
    }
    private func waitForFocusTick() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { continuation.resume() } }
    }
}

@MainActor private final class SharingCaptureFocusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Only a valid foreground/CG/tap lease can authorize new frames. API success is
/// necessary but still needs real physical-motion and visual acceptance on each Mac.
@MainActor final class SharingCursorCapture {
    let resources: SharingCursorResources
    private let focus: any SharingCursorFocus
    private var generation = 0
    private var acquiring = false, recoveringFocus = false
    private var anchor: CGPoint?
    private var resourceToken: UInt64?
    private(set) var maximumDrift: Double = 0
    private(set) var originalForeground = false
    private(set) var lastFailure: String?
    private(set) var acquisitionMilliseconds: Double?
    private(set) var focusMilliseconds: Double?

    init(resources: SharingCursorResources = SharingCursorResources(), focus: any SharingCursorFocus = SharingNativeCursorFocus()) {
        self.resources = resources; self.focus = focus
        resources.onRecovery { [weak self] in
            Task { @MainActor in
                guard let self, !self.acquiring, !self.resources.isActive, !self.resources.needsRecovery else { return }
                self.anchor = nil; self.resourceToken = nil; self.recoveringFocus = false
                self.focus.restoreForeground()
            }
        }
    }
    var needsRecovery: Bool { acquiring || recoveringFocus || resources.needsRecovery }
    var isCaptured: Bool {
        guard let resourceToken else { return false }
        return anchor != nil && resources.isActive(token: resourceToken) && focus.isForeground
    }
    func heartbeat() { if let resourceToken { resources.heartbeat(token: resourceToken) } }
    func awaitFocusRestoration() async -> Bool { await focus.awaitRestoration() }
    var localReplayAllowed: Bool { focus.localReplayAllowed }
    func withActiveCapture(_ action: () -> Void) -> Bool {
        guard let resourceToken, focus.isForeground else { return false }
        return resources.withActiveCapture(token: resourceToken, action)
    }
    var snapshot: [String: Any] {
        var value = resources.snapshot
        value["foreground"] = focus.isForeground; value["initiallyForeground"] = originalForeground
        value["acquiring"] = acquiring; value["maximumCursorDrift"] = maximumDrift
        value["failure"] = lastFailure ?? ""
        if let acquisitionMilliseconds { value["acquisitionMilliseconds"] = acquisitionMilliseconds }
        if let focusMilliseconds { value["focusMilliseconds"] = focusMilliseconds }
        value.merge(focus.diagnostics, uniquingKeysWith: { _, new in new })
        return value
    }
    func acquire(tapReady: () -> Bool, neutral: () -> Bool, maximumDuration: TimeInterval? = nil) async throws {
        try Task.checkCancellation()
        guard !acquiring, !recoveringFocus, !resources.needsRecovery else { throw PluginError.invalid("光标正在接管或等待恢复，请稍后重试。") }
        guard tapReady(), neutral() else { throw PluginError.invalid("键鼠监听未就绪或仍有按键按住，未接管。") }
        generation += 1; let attempt = generation
        let started = DispatchTime.now().uptimeNanoseconds
        acquiring = true; maximumDrift = 0; lastFailure = nil; originalForeground = focus.isForeground
        defer {
            acquisitionMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            acquiring = false
            if !resources.isActive, !resources.needsRecovery { recoveringFocus = false; focus.restoreForeground() }
        }
        do {
            let foreground = await focus.acquireForeground()
            focusMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            guard attempt == generation, !Task.isCancelled else { throw CancellationError() }
            guard foreground, focus.isForeground else { throw PluginError.invalid("未能取得前台，已取消鼠标接管。") }
            guard tapReady(), neutral(), focus.position != nil else { throw PluginError.invalid("接管准备状态已改变，未转发输入。") }
            resourceToken = try resources.acquire(maximumDuration: maximumDuration)
            // Physical motion before disassociation is not drift of an owned lease.
            // Sample the anchor only after CG acquisition, then keep the same strict gate.
            anchor = focus.position
            try validate(tapReady: tapReady())
        } catch { lastFailure = error.localizedDescription; _ = release(); throw error }
    }
    func validate(tapReady: Bool) throws {
        guard tapReady, isCaptured else { throw PluginError.invalid("光标独占已失效或应用失去前台，键鼠共享已暂停。") }
        guard let anchor, let point = focus.position else { throw PluginError.invalid("无法确认本机指针位置，键鼠共享已暂停。") }
        let drift = hypot(point.x - anchor.x, point.y - anchor.y)
        maximumDrift = max(maximumDrift, drift)
        guard drift <= 0.5 else { throw PluginError.invalid("本机指针位置发生变化，已安全归还控制；请重新开启共享后重试。") }
    }
    @discardableResult func release(restoring point: CGPoint? = nil) -> [String] {
        generation += 1
        let restore = resources.isActive && focus.isForeground ? (point ?? anchor) : nil
        anchor = nil; resourceToken = nil
        let errors = resources.release(warp: restore)
        recoveringFocus = resources.needsRecovery
        if !errors.isEmpty { lastFailure = errors.joined(separator: "；") }
        if !acquiring, !recoveringFocus { focus.restoreForeground() }
        return errors
    }
}
