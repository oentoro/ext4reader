import Testing
import Foundation
@testable import Ext4Kit

@Suite struct SelectionTests {
    @Test func checkingFolderSelectsDescendants() {
        var s = Selection()
        s.set("admin/2026/07", true)
        #expect(s.isSelected("admin/2026/07/01/IMG_0001.heic"))
        #expect(!s.isSelected("admin/2026/08"))
        #expect(s.state(of: "admin/2026") == .mixed)
        #expect(s.state(of: "admin/2026/07") == .on)
    }

    @Test func uncheckInsideCheckedFolderBecomesExclusion() {
        var s = Selection()
        s.set("admin", true)
        s.set("admin/2026/08", false)
        #expect(s.excluded == ["admin/2026/08"])
        #expect(s.state(of: "admin") == .mixed)
        #expect(s.isSelected("admin/2027")) // folder baru ikut
    }

    @Test func recheckingParentClearsChildRecords() {
        var s = Selection()
        s.set("admin/2026/08", true)
        s.set("admin/2026/07", true)
        s.set("admin", true)
        #expect(s.included == ["admin"] && s.excluded.isEmpty)
    }

    @Test func uncheckingEverythingIsEmpty() {
        var s = Selection()
        s.set("admin", true)
        s.set("admin", false)
        #expect(s.isEmpty && s.excluded.isEmpty)
    }

    @Test func prefixIsNotAncestor() {
        var s = Selection()
        s.set("admin/2026/0", true)
        #expect(!s.isSelected("admin/2026/07"))
    }

    @Test func roundTripsJSON() throws {
        var s = Selection()
        s.set("a", true)
        s.set("a/b", false)
        #expect(try JSONDecoder().decode(Selection.self, from: JSONEncoder().encode(s)) == s)
    }
}
