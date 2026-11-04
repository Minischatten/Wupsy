import AppKit
import XCTest

@testable import Wupsy

@MainActor
final class WSSNumericInputUXTests: XCTestCase {
    func testFocusAndFirstDeletionPreserveDraftAndPrecision() {
        let original: Float = 0.8335735
        var stored = original
        var commits = 0
        let input = WSSParameterTextField(
            value: stored, range: 0...2, title: "Test", maximumFractionDigits: 2,
            locale: Locale(identifier: "de_DE")
        ) {
            stored = $0
            commits += 1
        }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "")
        coordinator.show(original, in: field)
        XCTAssertEqual(field.stringValue, "0,83")
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "0,83")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(stored.bitPattern, original.bitPattern)
        XCTAssertEqual(commits, 0)
        field.stringValue = "0,8"
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "0,8")
        for draft in ["", "-", "0,", "0,81234567"] {
            field.stringValue = draft
            coordinator.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            coordinator.synchronize(input, in: field)
            XCTAssertEqual(field.stringValue, draft)
            XCTAssertEqual(commits, 0)
        }
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
        XCTAssertEqual(stored.bitPattern, Float("0.81234567")!.bitPattern)
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(commits, 1)
    }

    func testInvalidDraftsAndEscape() {
        var commits = 0
        let input = WSSParameterTextField(
            value: 1.234567, range: 0...2, title: "Test", maximumFractionDigits: 2
        ) { _ in commits += 1 }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "")
        let hint = NSTextField(labelWithString: "")
        coordinator.hint = hint
        coordinator.show(input.value, in: field)
        let baseline = field.stringValue
        for draft in ["", "-", "nan", "inf", "3", "abc"] {
            field.stringValue = draft
            XCTAssertFalse(coordinator.control(field, textShouldEndEditing: NSTextView()))
            XCTAssertEqual(field.stringValue, draft)
            XCTAssertFalse(hint.isHidden)
            XCTAssertEqual(commits, 0)
        }
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(),
                doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(field.stringValue, baseline)
        XCTAssertTrue(hint.isHidden)
    }

    func testSliderSynchronizesUntouchedFieldAndPreservesEditedDraft() {
        var stored: Float = 0.8335735
        var commits = 0
        func input() -> WSSParameterTextField {
            WSSParameterTextField(
                value: stored, range: 0...2, title: "Test", maximumFractionDigits: 2,
                locale: Locale(identifier: "de_DE")
            ) {
                stored = $0
                commits += 1
            }
        }
        let coordinator = input().makeCoordinator()
        let field = NSTextField(string: "")
        coordinator.show(stored, in: field)
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        stored = 1.234567
        coordinator.synchronize(input(), in: field)
        XCTAssertEqual(field.stringValue, "1,23")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(stored.bitPattern, Float(1.234567).bitPattern)
        XCTAssertEqual(commits, 0)
        field.stringValue = ""
        stored = 1.7654321
        coordinator.synchronize(input(), in: field)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(),
                doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(field.stringValue, "1,77")
        XCTAssertEqual(commits, 0)
        field.stringValue = "0,12345678"
        stored = 1.5
        coordinator.synchronize(input(), in: field)
        XCTAssertEqual(field.stringValue, "0,12345678")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(stored.bitPattern, Float("0.12345678")!.bitPattern)
        XCTAssertEqual(commits, 1)
    }

    func testExactDoubleAndUndoOnlyRecordConfirmedChanges() {
        let original = 1.23456789012345
        var stored = original
        let undo = UndoManager()
        let target = NSObject()
        var commits = 0
        let input = WSSParameterTextField(
            value: Float(original), range: 0...10, title: "Test", maximumFractionDigits: 2,
            locale: Locale(identifier: "de_DE"), exactValue: original, exactRange: 0...10,
            commitExact: { value in
                let previous = stored
                undo.registerUndo(withTarget: target) { _ in stored = previous }
                stored = value
                commits += 1
            }, commit: { _ in XCTFail("Exact input must not pass through Float") })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "")
        coordinator.show(input.value, in: field)
        XCTAssertEqual(field.stringValue, "1,23")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(stored.bitPattern, original.bitPattern)
        XCTAssertFalse(undo.canUndo)
        field.stringValue = "2,123456789012345"
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(stored.bitPattern, Double("2.123456789012345")!.bitPattern)
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(commits, 1)
        undo.undo()
        XCTAssertEqual(stored.bitPattern, original.bitPattern)
    }
    func testConfirmedDraftUsesDocumentUndoRedoAfterSliderChange() async throws {
        let fixture = WSSEditorEditingTests()
        let (helper, project) = try await fixture.fixture(clouds: true)
        defer { try? helper.tearDownWithError() }
        let doc = fixture.editor(project)
        defer { doc.close() }
        let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
        let parameter = WSSEditorParameter.cloudsIntensity
        let original: Float = 0.8335735
        try doc.setParameter(parameter, at: address, value: original)
        doc.undoManager.removeAllActions()
        func input() -> WSSParameterTextField {
            WSSParameterTextField(
                value: parameter.value(in: doc.state.workingModel, at: address)!,
                range: parameter.validRange, title: "Test", maximumFractionDigits: 2,
                locale: Locale(identifier: "de_DE")
            ) { try doc.setParameter(parameter, at: address, value: $0) }
        }
        let coordinator = input().makeCoordinator()
        let field = NSTextField(string: "")
        coordinator.show(original, in: field)
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        let revision = doc.state.workingRevision
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertFalse(doc.undoManager.canUndo)
        field.stringValue = "0,71234567"
        try doc.updateSlider(parameter, at: address, value: 0.5)
        coordinator.synchronize(input(), in: field)
        XCTAssertEqual(field.stringValue, "0,71234567")
        XCTAssertTrue(coordinator.accept(field))
        let edited = Float("0.71234567")!
        XCTAssertEqual(
            parameter.value(in: doc.state.workingModel, at: address)!.bitPattern, edited.bitPattern)
        doc.undoManager.undo()
        XCTAssertEqual(parameter.value(in: doc.state.workingModel, at: address), 0.5)
        doc.undoManager.redo()
        XCTAssertEqual(
            parameter.value(in: doc.state.workingModel, at: address)!.bitPattern, edited.bitPattern)
    }

}
