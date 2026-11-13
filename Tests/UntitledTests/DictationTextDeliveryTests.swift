import Foundation
import CoreGraphics
import AppKit
import Testing
@testable import Untitled

@Suite(.serialized) @MainActor struct DictationTextDeliveryTests {
    @Test func asynchronousKeyboardEventsAppendReviseAndRemoveOnlyOwnedText() async throws {
        let driver = Editor(value: "前😀选中后", selection: NSRange(location: 3, length: 2))
        driver.delay = .milliseconds(20)
        let target = try await DictationTextTarget(editor: driver)
        try await target.update("下午三点")
        #expect(driver.current.value == "前😀下午三点后")
        try await target.update("下午三点开会")
        #expect(driver.insertions == ["下午三点", "开会"])
        try await target.update("下午 3 点开会。")
        #expect(driver.current.value == "前😀下午 3 点开会。后")
        #expect(driver.current.selection == NSRange(location: 3 + "下午 3 点开会。".utf16.count, length: 0))
        #expect(driver.maximumConcurrentChanges == 1)
    }

    @Test func reportedSuccessWithoutSelectionAckFallsBackToVerifiedGraphemes() async throws {
        let driver = Editor(value: "前", selection: NSRange(location: 1, length: 0))
        driver.ignoredAXSelection = true
        let target = try await DictationTextTarget(editor: driver)
        let old = "😀👨‍👩‍👧‍👦你好"
        try await target.update(old)
        try await target.update("测试")
        #expect(driver.current.value == "前测试")
        #expect(driver.backwardSelections == old.count)
        #expect(driver.deletions == 0) // Replacement uses typed text over an acknowledged selection.
        try await target.update("")
        #expect(driver.current.value == "前")
        #expect(driver.deletions == 1)
    }

    @Test func literalUtf16OwnershipDoesNotTreatCanonicalSpellingsAsIdentical() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        try await target.update("e\u{301}")
        #expect(driver.current.selection.location == 2)
        try await target.update("é")
        #expect(driver.current.value.utf16.elementsEqual("é".utf16))
        #expect(driver.current.selection.location == 1)
        #expect(driver.insertions.count == 2)
    }

    @Test func fallbackWillNotSelectAcrossAnOriginalCombiningCluster() async throws {
        let driver = Editor(value: "e", selection: NSRange(location: 1, length: 0))
        driver.ignoredAXSelection = true
        let target = try await DictationTextTarget(editor: driver)
        try await target.update("\u{301}")
        await #expect(throws: DictationTargetError.self) { try await target.update("") }
        #expect(driver.current.value.utf16.elementsEqual("e\u{301}".utf16))
        #expect(driver.backwardSelections == 0 && driver.deletions == 0)
    }

    @Test func anExternalEditFailsBeforeAnyKeyboardMutation() async throws {
        let driver = Editor(value: "正文", selection: NSRange(location: 2, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.current = .init(value: "正文手改", selection: NSRange(location: 4, length: 0))
        await #expect(throws: DictationTargetError.self) { try await target.update("不能覆盖") }
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal("也不能定稿覆盖") }
        #expect(driver.insertions.isEmpty && driver.deletions == 0)
    }

    @Test func noAcknowledgementNeverRetriesOrClaimsSuccess() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        driver.ignoreKeyboard = true
        let target = try await DictationTextTarget(editor: driver)
        await #expect(throws: DictationTargetError.self) { try await target.update("没有真的写入") }
        #expect(driver.insertions == ["没有真的写入"])
        #expect(driver.deletions == 0)
        #expect(driver.current.value.isEmpty)
    }

    @Test func cancellingAnUnacknowledgedWritePreventsLaterBatches() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        driver.delay = .seconds(5)
        let target = try await DictationTextTarget(editor: driver)
        let task = Task { try await target.update(String(repeating: "中", count: 1500)) }
        while driver.insertions.isEmpty { await Task.yield() }
        target.cancel(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.insertions.count == 1)
        #expect(driver.insertions[0].utf16.count <= 16)
        #expect(driver.deletions == 0)
    }

    @Test func finalPunctuationRevisionChangesTheOwnedSuffixInOneEvent() async throws {
        let driver = Editor(value: "用户原文后文", selection: NSRange(location: 4, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        try await target.update(String(repeating: "明天下午三点开会然后讨论预算", count: 6))
        let before = driver.insertions.count
        let final = String(repeating: "明天下午 3 点开会，然后讨论预算。", count: 6)
        try await target.commitFinal(final)
        #expect(driver.insertions.count == before + 1)
        #expect(driver.insertions.last!.utf16.count > 16)
        #expect(driver.current.value == "用户原文" + final + "后文")
        #expect(driver.current.selection == NSRange(location: 4 + final.utf16.count, length: 0))
        #expect(driver.deletions == 0)
        try await target.commitFinal(final)
        #expect(driver.insertions.count == before + 1)
    }

    @Test func unconfirmedFinalIsNeverRetriedAsSmallerFragments() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.ignoreKeyboard = true
        await #expect(throws: DictationTargetError.self) { try await target.commitFinal(String(repeating: "定稿", count: 60)) }
        #expect(driver.insertions.count == 1 && driver.insertions[0].utf16.count == 120)
        #expect(driver.current.value.isEmpty && driver.deletions == 0)
    }

    @Test func checkedUnicodeEventRetainsWholeFinalWithoutPosting() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        for count in [16, 67, 512, 4096, DoubaoASRLimits.textLength] {
            let text = String(repeating: "中", count: count)
            let event = try DictationUnicodeInput.keyDown(text, source: source)
            var actual = 0, units = [UniChar](repeating: 0, count: count)
            units.withUnsafeMutableBufferPointer {
                event.keyboardGetUnicodeString(maxStringLength: count, actualStringLength: &actual, unicodeString: $0.baseAddress)
            }
            #expect(actual == count && units.elementsEqual(text.utf16))
            let appKitEvent = try #require(NSEvent(cgEvent: event))
            #expect(appKitEvent.characters?.utf16.elementsEqual(text.utf16) == true)
        }
        let emoji = "定稿😀👨‍👩‍👧‍👦，完成。"
        let event = try DictationUnicodeInput.keyDown(emoji, source: source)
        var actual = 0, units = [UniChar](repeating: 0, count: emoji.utf16.count)
        units.withUnsafeMutableBufferPointer { event.keyboardGetUnicodeString(maxStringLength: emoji.utf16.count, actualStringLength: &actual, unicodeString: $0.baseAddress) }
        #expect(actual == emoji.utf16.count && units.elementsEqual(emoji.utf16))
        #expect(throws: DictationTargetError.self) { try DictationUnicodeInput.keyDown(String(repeating: "中", count: DoubaoASRLimits.textLength + 1), source: source) }
    }

    @Test func transientAXReadFailuresWaitWithoutResendingTheTypedText() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.unavailableAfterInsert = 3
        try await target.update("已经写入")
        #expect(driver.current.value == "已经写入")
        #expect(driver.insertions == ["已经写入"])
        #expect(driver.deletions == 0)
    }

    @Test func persistentAXReadFailureNeverResendsOrBlindlyDeletes() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.unavailableAfterInsert = 1000
        await #expect(throws: DictationTargetError.self) { try await target.update("保留已输入") }
        #expect(driver.current.value == "保留已输入")
        #expect(driver.insertions == ["保留已输入"])
        #expect(driver.deletions == 0)
    }

    @Test func validationIgnoresSnapshotsMadeStaleByACompletedWrite() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.suspendNextSnapshot = true
        let validation = Task { try await target.validate() }
        while !driver.snapshotIsSuspended { await Task.yield() }
        try await target.update("新结果")
        driver.resumeSnapshot()
        try await validation.value
        #expect(driver.current.value == "新结果")
        #expect(driver.insertions == ["新结果"])
    }

    @Test func cancellationWhileReadingASnapshotPreventsKeyboardMutation() async throws {
        let driver = Editor(value: "原文", selection: NSRange(location: 2, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        driver.suspendNextSnapshot = true
        let writing = Task { try await target.update("不应写入") }
        while !driver.snapshotIsSuspended { await Task.yield() }
        target.cancel()
        driver.resumeSnapshot()
        await #expect(throws: CancellationError.self) { try await writing.value }
        #expect(driver.current.value == "原文")
        #expect(driver.insertions.isEmpty && driver.deletions == 0)
    }

    @Test func transcriptionControlCharactersNeverBecomeSendOrNavigationKeys() async throws {
        let driver = Editor(value: "", selection: NSRange(location: 0, length: 0))
        let target = try await DictationTextTarget(editor: driver)
        try await target.update("第一行\n第二行\t不要发送\u{1b}\r\n")
        #expect(driver.current.value == "第一行 第二行 不要发送   ")
        #expect(driver.insertions.allSatisfy { text in !text.unicodeScalars.contains { $0.properties.generalCategory == .control } })
    }

    @Test func unicodeEventChunksNeverSplitASurrogatePair() {
        let text = "👨‍👩‍👧‍👦你好😀" + String(repeating: "a", count: 70)
        let chunks = DictationTextTarget.chunks(text, limit: 16)
        #expect(chunks.joined().utf16.elementsEqual(text.utf16))
        #expect(chunks.allSatisfy { $0.utf16.count <= 16 && !$0.contains("�") })
    }

    private final class Editor: DictationEditor {
        var current: DictationEditorSnapshot
        var delay: Duration = .zero
        var ignoredAXSelection = false
        var ignoreKeyboard = false
        var focused = true
        var unavailableAfterInsert = 0
        private var unavailableSnapshots = 0
        var suspendNextSnapshot = false
        var snapshotIsSuspended: Bool { suspended != nil }
        private var suspended: (DictationEditorSnapshot, CheckedContinuation<DictationEditorSnapshot, Never>)?
        private(set) var insertions: [String] = []
        private(set) var deletions = 0
        private(set) var backwardSelections = 0
        private(set) var maximumConcurrentChanges = 0
        private var pending: (DictationEditorSnapshot, ContinuousClock.Instant)?
        init(value: String, selection: NSRange) { current = .init(value: value, selection: selection) }
        func validateFocus() throws { if !focused { throw DictationTargetError.changed } }
        func snapshot() async throws -> DictationEditorSnapshot {
            if unavailableSnapshots > 0 { unavailableSnapshots -= 1; throw DictationTargetError.unavailable }
            let value = try readSnapshot()
            guard suspendNextSnapshot else { return value }
            suspendNextSnapshot = false
            return await withCheckedContinuation { suspended = (value, $0) }
        }
        func resumeSnapshot() {
            guard let suspended else { return }
            self.suspended = nil
            suspended.1.resume(returning: suspended.0)
        }
        private func readSnapshot() throws -> DictationEditorSnapshot {
            try validateFocus()
            if let pending, ContinuousClock.now >= pending.1 { current = pending.0; self.pending = nil }
            return current
        }
        func select(_ range: NSRange) throws -> Bool {
            guard !ignoredAXSelection else { return true }
            try change(.init(value: current.value, selection: range))
            return true
        }
        func selectBackward(_ characters: Int) throws {
            _ = try readSnapshot()
            backwardSelections += characters
            let prefix = (current.value as NSString).substring(to: current.selection.location)
            let removed = String(prefix.suffix(characters))
            try change(.init(value: current.value, selection: .init(location: current.selection.location - removed.utf16.count,
                                                                  length: current.selection.length + removed.utf16.count)))
        }
        func insert(_ text: String, replacing expected: DictationEditorSnapshot) throws {
            try require(expected)
            insertions.append(text)
            guard !ignoreKeyboard else { return }
            try replace(text)
            unavailableSnapshots = unavailableAfterInsert
        }
        func deleteSelection(matching expected: DictationEditorSnapshot) throws {
            try require(expected)
            guard current.selection.length > 0 else { throw DictationTargetError.changed }
            deletions += 1; try replace("")
        }
        private func require(_ expected: DictationEditorSnapshot) throws {
            let actual = try readSnapshot()
            guard actual.value.utf16.elementsEqual(expected.value.utf16), actual.selection == expected.selection else { throw DictationTargetError.changed }
        }
        private func replace(_ text: String) throws {
            let value = (current.value as NSString).replacingCharacters(in: current.selection, with: text)
            try change(.init(value: value, selection: .init(location: current.selection.location + text.utf16.count, length: 0)))
        }
        private func change(_ value: DictationEditorSnapshot) throws {
            _ = try readSnapshot()
            maximumConcurrentChanges = max(maximumConcurrentChanges, pending == nil ? 1 : 2)
            guard pending == nil else { throw DictationTargetError.unconfirmed }
            if delay == .zero { current = value }
            else { pending = (value, ContinuousClock.now.advanced(by: delay)) }
        }
    }
}
