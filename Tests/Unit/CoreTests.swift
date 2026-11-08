import XCTest
@testable import HomeThread

/// Tests ohne Netz: Authenticator-Code, Adressprüfung, lokale Suche, Payload.
final class CoreTests: XCTestCase {
    @MainActor func testTOTPMatchesRFC6238Vector() {
        // RFC 6238, SHA1, Geheimnis "12345678901234567890", T = 59 s → 94287082 (6 Stellen: 287082)
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        XCTAssertEqual(TOTP.code(secret: secret, date: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(TOTP.code(secret: secret, date: Date(timeIntervalSince1970: 1111111109)), "081804")
    }

    @MainActor func testServerAddressRules() throws {
        XCTAssertEqual(try APIClient.normalize("thread.example.org").absoluteString, "https://thread.example.org")
        XCTAssertEqual(try APIClient.normalize("http://10.0.0.5:8080/").absoluteString, "http://10.0.0.5:8080")
        XCTAssertEqual(try APIClient.normalize("homeserver.local").scheme, "http")
        XCTAssertThrowsError(try APIClient.normalize("http://thread.example.org")) { e in
            XCTAssertEqual((e as? APIError)?.code, "not_https")
        }
        XCTAssertThrowsError(try APIClient.normalize("ftp://x"))
    }

    @MainActor func testPayloadRoundTrip() {
        var p = Payload()
        p.question = "Wann?"
        p.options = [PollOption(id: "o1", text: "Samstag")]
        p.showInterim = true
        let d = p.dict
        XCTAssertEqual(d["show_interim"] as? Bool, true)
        XCTAssertEqual(Payload.decode(p.json), p)
    }

    @MainActor func testLocalSearchIgnoresCaseAndAccentsAndFindsPrefixes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(root: dir)
        XCTAssertNil(store.apply(kind: "room", d: ["id": "room-0001", "kind": "chat", "title": "Test", "created_at": 1.0, "updated_at": 1.0, "deleted": 0], me: "me"))
        for (i, body) in ["Termin bei Frau Müller", "Äpfel und Birnen kaufen", "Nichts Besonderes"].enumerated() {
            _ = store.apply(kind: "message", d: ["id": "msg-000\(i)", "room_id": "room-0001", "author_id": "me", "kind": "text",
                                                "body": body, "payload": [String: Any](), "created_at": Double(i), "pinned": 0, "deleted": 0, "seq": i + 1], me: "me")
        }
        _ = store.apply(kind: "message", d: ["id": "msg-poll", "room_id": "room-0001", "author_id": "me", "kind": "poll", "body": "",
                                            "payload": ["question": "Grillen?", "options": [["id": "o1", "text": "Würstchen"]]],
                                            "created_at": 5.0, "pinned": 0, "deleted": 0, "seq": 9], me: "me")
        XCTAssertEqual(store.search("muller").map(\.id), ["msg-0000"])
        XCTAssertEqual(store.search("APFEL").map(\.id), ["msg-0001"])
        XCTAssertEqual(store.search("wurst").map(\.id), ["msg-poll"], "Antworten einer Abstimmung sind durchsuchbar")
        XCTAssertEqual(store.search("", scope: .polls).map(\.id), ["msg-poll"])
        // Löschen entfernt aus der Suche
        _ = store.apply(kind: "message", d: ["id": "msg-0000", "room_id": "room-0001", "author_id": "me", "kind": "text", "body": "",
                                            "payload": [String: Any](), "created_at": 0.0, "pinned": 0, "deleted": 1, "seq": 20], me: "me")
        XCTAssertTrue(store.search("muller").isEmpty)
    }

    @MainActor func testVoiceWaveDownsample() {
        let v = (0..<480).map { Double($0 % 10) / 10 }
        XCTAssertEqual(VoiceRecorder.downsample(v, to: 48).count, 48)
        XCTAssertEqual(VoiceRecorder.downsample([0.5, 0.25], to: 48), [0.5, 0.25])
    }
}
