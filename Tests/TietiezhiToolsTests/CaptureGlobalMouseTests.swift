import Foundation
import CoreGraphics
import Testing
@testable import TietiezhiTools

struct CaptureGlobalMouseTests {
    private func defaults(_ work:(UserDefaults) throws -> Void) rethrows {
        let name="capture-mouse-bindings-\(UUID())",defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) };try work(defaults)
    }
    @Test func legacyBindingMigratesOnceWithoutChangingActionOrActivation() throws {
        try defaults { store in
            store.set(true,forKey:"capture.mouse.enabled");store.set("controlOption",forKey:"capture.mouse.modifier")
            store.set(2,forKey:"capture.mouse.button");store.set("text",forKey:"capture.mouse.action")
            let first=CaptureGlobalMousePreferences(defaults:store),next=CaptureGlobalMousePreferences(defaults:store)
            #expect(first.enabled);#expect(first.bindings==next.bindings)
            #expect(first.bindings.count==1);#expect(first.bindings[0].action == .text)
            #expect(first.bindings[0].button==2);#expect(first.bindings[0].flags == [.maskControl,.maskAlternate])
            try CaptureGlobalMousePreferences.save([],defaults:store)
            #expect(CaptureGlobalMousePreferences(defaults:store).bindings.isEmpty)
        }
    }
    @Test func conflictingActiveBindingsAreRejectedWithoutChangingSavedSettings() throws {
        try defaults { store in
            let first=CaptureGlobalMouseBinding(action:.pin)
            try CaptureGlobalMousePreferences.save([first],defaults:store)
            let duplicate=CaptureGlobalMouseBinding(action:.copy)
            #expect(throws:(any Error).self) { try CaptureGlobalMousePreferences.save([first,duplicate],defaults:store) }
            #expect(CaptureGlobalMousePreferences(defaults:store).bindings==[first])
            var inactive=duplicate;inactive.enabled=false
            try CaptureGlobalMousePreferences.save([first,inactive],defaults:store)
            #expect(CaptureGlobalMousePreferences(defaults:store).bindings.count==2)
        }
    }
    @Test func gesturesMatchExactModifiersAndPhysicalButtons() throws {
        try defaults { store in
            store.set(true,forKey:"capture.mouse.enabled")
            let one=CaptureGlobalMouseBinding(modifier:"controlOption",button:0,action:.edit)
            let two=CaptureGlobalMouseBinding(modifier:"option",button:4,action:.save)
            try CaptureGlobalMousePreferences.save([one,two],defaults:store)
            let prefs=CaptureGlobalMousePreferences(defaults:store)
            #expect(prefs.match(button:0,flags:[.maskControl,.maskAlternate],application:"app")?.action == .edit)
            #expect(prefs.match(button:4,flags:.maskAlternate,application:"app")?.action == .save)
            #expect(prefs.match(button:0,flags:.maskAlternate,application:"app")==nil)
            #expect(prefs.match(button:4,flags:[.maskAlternate,.maskShift],application:"app")==nil)
            #expect(prefs.match(button:3,flags:.maskAlternate,application:"app")==nil)
            #expect(prefs.match(button:0,flags:[],application:"app")==nil)
        }
    }
    @Test func disabledIgnoredAndCorruptConfigurationsPassInputThrough() throws {
        try defaults { store in
            let binding=CaptureGlobalMouseBinding()
            try CaptureGlobalMousePreferences.save([binding],defaults:store)
            #expect(CaptureGlobalMousePreferences(defaults:store).match(button:0,flags:.maskAlternate,application:"app")==nil)
            store.set(true,forKey:"capture.mouse.enabled");store.set("com.apple.*",forKey:"capture.mouse.ignored")
            #expect(CaptureGlobalMousePreferences(defaults:store).match(button:0,flags:.maskAlternate,application:"com.apple.Terminal")==nil)
            var duplicate=binding;duplicate.id=UUID();duplicate.action = .copy
            store.set(try JSONEncoder().encode([binding,duplicate]),forKey:CaptureGlobalMousePreferences.bindingsKey)
            #expect(CaptureGlobalMousePreferences(defaults:store).match(button:0,flags:.maskAlternate,application:"app")==nil)
            store.set(Data("bad data".utf8),forKey:CaptureGlobalMousePreferences.bindingsKey)
            #expect(CaptureGlobalMousePreferences(defaults:store).bindings.isEmpty)
        }
    }
    @Test func bindingsAlwaysRequireModifierAndSupportedMouseButton() {
        defaults { store in
            #expect(throws:(any Error).self) { try CaptureGlobalMousePreferences.save([CaptureGlobalMouseBinding(modifier:"")],defaults:store) }
            #expect(throws:(any Error).self) { try CaptureGlobalMousePreferences.save([CaptureGlobalMouseBinding(button:5)],defaults:store) }
        }
    }
}
