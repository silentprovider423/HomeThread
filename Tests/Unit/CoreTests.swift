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

    @MainActor func testImportedHistoryFlagsAndMarkAllSeen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(root: dir)
        _ = store.apply(kind: "room", d: ["id": "room-0002", "kind": "group", "title": "Import", "created_at": 1.0, "updated_at": 1.0, "deleted": 0], me: "me")
        _ = store.apply(kind: "message", d: ["id": "msg-file", "room_id": "room-0002", "author_id": "me", "kind": "file", "body": "",
                                            "payload": ["filename": "alt.pdf", "size": 10, "missing": true], "created_at": 2.0,
                                            "pinned": 0, "deleted": 0, "seq": 3], me: "me")
        _ = store.apply(kind: "message", d: ["id": "msg-img", "room_id": "room-0002", "author_id": "me", "kind": "image", "body": "",
                                            "payload": ["w": 40, "h": 30, "preview_only": true], "created_at": 3.0,
                                            "pinned": 0, "deleted": 0, "seq": 4], me: "me")
        XCTAssertEqual(store.message("msg-file")?.payload.missing, true)
        XCTAssertEqual(store.message("msg-img")?.payload.previewOnly, true)
        // Verlauf von einem anderen Gerät zählt als neu – bis zum ersten vollständigen Abgleich
        XCTAssertEqual(store.summaries(myDevice: "dev-1", archived: false).first?.unread, 2)
        store.markAllSeen()
        XCTAssertEqual(store.summaries(myDevice: "dev-1", archived: false).first?.unread, 0)
    }

    @MainActor func testVoiceWaveDownsample() {
        let v = (0..<480).map { Double($0 % 10) / 10 }
        XCTAssertEqual(VoiceRecorder.downsample(v, to: 48).count, 48)
        XCTAssertEqual(VoiceRecorder.downsample([0.5, 0.25], to: 48), [0.5, 0.25])
    }

    /// Chat-Liste mit vielen Räumen (wie ein großer Import: 518 Räume, 62.000 Einträge) muss schnell bleiben.
    @MainActor func testSummariesStayFastWithManyRooms() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ht-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(root: dir)
        try store.db.exec("BEGIN")
        var seq = 0
        for r in 0..<518 {
            let rid = String(format: "room-%04d", r)
            try store.db.run("INSERT INTO rooms(id, kind, title, about, created_by, created_at, updated_at) VALUES(?,?,?,?,?,?,?)",
                             rid, "group", "Raum \(r)", "", "me", 1.0, 1.0)
            for m in 0..<120 {
                seq += 1
                try store.db.run("INSERT INTO messages(id, room_id, author_id, device_id, kind, body, payload, created_at, seq) VALUES(?,?,?,?,?,?,?,?,?)",
                                 "\(rid)-\(m)", rid, "me", "dev-other", "text", "Eintrag \(m)", "{}", Double(seq), seq)
            }
            store.set("read:\(rid)", String(seq - 3))
        }
        try store.db.exec("COMMIT")
        _ = store.summaries(myDevice: "dev-1", archived: false)
        let t0 = Date()
        let list = store.summaries(myDevice: "dev-1", archived: false)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("summaries: \(list.count) Räume in \(Int(ms)) ms")
        XCTAssertEqual(list.count, 518)
        XCTAssertEqual(list.first?.unread, 3)
        XCTAssertEqual(list.first?.room.title, "Raum 517", "neuester oben")
        XCTAssertLessThan(ms, 400)
    }

    @MainActor func testDesktopStampFormat() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 8; c.hour = 12
        let now = Calendar.current.date(from: c)!
        let today = now.addingTimeInterval(-3600)
        XCTAssertEqual(Fmt.stamp(today, now: now), Fmt.time(today))
        let yesterday = now.addingTimeInterval(-86400)
        XCTAssertTrue(Fmt.stamp(yesterday, now: now).hasSuffix(", " + Fmt.time(yesterday)))
        XCTAssertNotEqual(Fmt.stamp(yesterday, now: now), Fmt.stamp(now.addingTimeInterval(-3 * 86400), now: now))
        let old = now.addingTimeInterval(-400 * 86400)
        XCTAssertTrue(Fmt.stamp(old, now: now).contains("2025"))
    }

    @MainActor func testAvatarInitials() {
        XCTAssertEqual(Avatar.initials("kaufen liste", person: false), "KA")
        XCTAssertEqual(Avatar.initials("Notizen", person: false), "NO")
        XCTAssertEqual(Avatar.initials("Alex Morgan", person: true), "AM")
        XCTAssertEqual(Avatar.initials("🎉", person: false), "")
    }

    @MainActor func testEntryLinkRoundTripAndRejectsOthers() throws {
        let m = Message(id: "0a1b2c3d-aaaa-bbbb-cccc-000000000001", roomId: "room-42", authorId: "u", deviceId: nil, kind: .text, body: "x",
                        payload: Payload(), replyTo: nil, attachment: nil, thumb: nil, createdAt: .now, editedAt: nil, pinned: false,
                        deleted: false, seq: 1, pending: false, failed: nil)
        let url = EntryLink.make(m)
        XCTAssertEqual(url.absoluteString, "homethread://entry/room-42/0a1b2c3d-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(EntryLink.parse(url), ChatRoute(room: "room-42", jump: m.id))
        for bad in ["https://example.org/entry/a/b", "homethread://room/a/b", "homethread://entry/a", "homethread://entry/a/b/c",
                    "homethread://entry/a%20b/c", "homethread://entry/../x"] {
            XCTAssertNil(EntryLink.parse(try XCTUnwrap(URL(string: bad))), bad)
        }
        // im Text gefunden und anklickbar gemacht
        let text = "Siehe \(url.absoluteString) und https://example.org"
        XCTAssertEqual(EntryLink.ranges(in: text).map(\.url), [url])
        let rich = RichText.make(text).value
        XCTAssertTrue(rich.runs.contains { $0.link == url })
    }

    @MainActor func testEmojiCatalogAndSearch() {
        let all = EmojiCatalog.sections.flatMap(\.emojis)
        XCTAssertGreaterThan(all.count, 900)
        XCTAssertEqual(Set(all.map(\.value)).count, all.count, "kein Emoji doppelt")
        XCTAssertFalse(all.contains { $0.value.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } }, "keine nackten Hautfarben")
        XCTAssertEqual(EmojiCatalog.sections.first?.id, "smileys")
        XCTAssertTrue(EmojiCatalog.search("thumbs up").contains { $0.value == "👍" })
        XCTAssertTrue(EmojiCatalog.search("herz").contains { $0.value == "❤️" }, "deutsches Suchwort")
        XCTAssertTrue(EmojiCatalog.search("Feuer").contains { $0.value == "🔥" })
        XCTAssertTrue(EmojiCatalog.search("xyzxyz").isEmpty)
        XCTAssertEqual(EmojiCatalog.search("  ").count, all.count)
    }
}
