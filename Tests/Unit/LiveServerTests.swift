import AVFoundation
import XCTest
@testable import HomeThread

/// Tests gegen einen echten HomeThread-Server mit einem Testkonto (nie ein echtes Konto).
/// Startumgebung (test.sh setzt sie aus der gitignorten Datei .test-tokens):
///   THREAD_SERVER, THREAD_TOKEN, THREAD_TOKEN2 (zweites Gerät desselben Testkontos), THREAD_PUBLIC_SERVER (optional)
final class LiveServerTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor func client(_ key: String = "THREAD_TOKEN", server: String? = nil) throws -> APIClient {
        guard let s = server ?? env["THREAD_SERVER"], let t = env[key], !s.isEmpty, !t.isEmpty else {
            throw XCTSkip("Kein Test-Server konfiguriert")
        }
        return APIClient(base: try APIClient.normalize(s), token: t)
    }

    @MainActor func testAuthRequired() async throws {
        let c = try client()
        let (me, _) = try await c.me()
        XCTAssertFalse(me.id.isEmpty)
        let anon = APIClient(base: c.base)
        do {
            _ = try await anon.sync(since: 0)
            XCTFail("ohne Token darf nichts kommen")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 401)
        }
        let wrong = APIClient(base: c.base, token: "ht_falsch")
        do {
            _ = try await wrong.me()
            XCTFail("falsches Token")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 401)
        }
    }

    @MainActor func testOpsAndSyncBetweenTwoDevices() async throws {
        let a = try client(), b = try client("THREAD_TOKEN2")
        let start = try await b.sync(since: 0, limit: 1).next
        var cursor = 0
        // Cursor von B ans Ende spulen
        var page = try await b.sync(since: start)
        cursor = page.next
        while page.more { page = try await b.sync(since: cursor); cursor = page.next }

        let room = newID(), m1 = newID(), poll = newID(), cl = newID(), item = newID()
        let results = try await a.ops([
            ["op_id": newID(), "type": "room.create", "room": ["id": room, "kind": "group", "title": "Unit-Test"]],
            ["op_id": newID(), "type": "msg.create", "msg": ["id": m1, "room_id": room, "body": "Hallo von A"]],
            ["op_id": newID(), "type": "msg.create", "msg": ["id": poll, "room_id": room, "kind": "poll",
                                                             "payload": ["question": "?", "options": [["id": "o1", "text": "Ja"], ["id": "o2", "text": "Nein"]]]]],
            ["op_id": newID(), "type": "msg.create", "msg": ["id": cl, "room_id": room, "kind": "checklist", "body": "Liste",
                                                             "items": [["id": item, "text": "Punkt", "position": 0]]]],
            ["op_id": newID(), "type": "reaction.set", "message_id": m1, "emoji": "👍", "on": true],
            ["op_id": newID(), "type": "vote.set", "message_id": poll, "choices": ["o1"]],
            ["op_id": newID(), "type": "item.update", "id": item, "done": true],
            ["op_id": newID(), "type": "msg.pin", "id": m1, "pinned": true],
        ])
        XCTAssertTrue(results.allSatisfy { $0["ok"] as? Bool == true }, "\(results)")

        let got = try await b.sync(since: cursor)
        let kinds = Set(got.changes.compactMap { $0["kind"] as? String })
        XCTAssertTrue(kinds.isSuperset(of: ["room", "member", "message", "reaction", "vote", "item"]), "\(kinds)")
        let msg = got.changes.first { ($0["data"] as? [String: Any])?["id"] as? String == m1 }?["data"] as? [String: Any]
        XCTAssertEqual(msg?["body"] as? String, "Hallo von A")
        XCTAssertEqual(msg?["pinned"] as? Int, 1)

        // Aufräumen: Raum löschen → B bekommt Grabstein
        _ = try await a.ops([["op_id": newID(), "type": "room.delete", "room_id": room]])
        let after = try await b.sync(since: got.next)
        let tomb = after.changes.first { $0["kind"] as? String == "room" && ($0["data"] as? [String: Any])?["id"] as? String == room }
        XCTAssertEqual((tomb?["data"] as? [String: Any])?["deleted"] as? Int, 1)
    }

    @MainActor func testBlobUploadAndDownload() async throws {
        let c = try client()
        let id = newID()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(id).bin")
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        try data.write(to: src)
        try await c.putBlob(id: id, file: src, mime: "application/octet-stream", filename: "test.bin")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(id)-back.bin")
        try await c.getBlob(id: id, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), data)
    }

    @MainActor func testPublicAddressOnlyServesAPI() async throws {
        guard let pub = env["THREAD_PUBLIC_SERVER"], !pub.isEmpty else { throw XCTSkip("keine öffentliche Adresse") }
        let c = try client(server: pub)
        let healthy = try await c.health()
        XCTAssertTrue(healthy)
        let (me, _) = try await c.me()
        XCTAssertFalse(me.id.isEmpty)
        _ = try await c.sync(since: 0, limit: 5)
        // Alles außer /api und /auth ist gesperrt
        let (_, resp) = try await URLSession.shared.data(from: URL(string: pub + "/")!)
        XCTAssertNotEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let (_, resp2) = try await URLSession.shared.data(from: URL(string: pub + "/api/sync")!)
        XCTAssertEqual((resp2 as? HTTPURLResponse)?.statusCode, 401)
    }

    /// Ganze App-Logik: Gerät A legt offline an (Warteschlange), gleicht ab; Gerät B sieht alles inkl. Foto und Sprachnotiz.
    @MainActor func testTwoAppModelsStayInSync() async throws {
        guard let s = env["THREAD_SERVER"], let t1 = env["THREAD_TOKEN"], let t2 = env["THREAD_TOKEN2"] else { throw XCTSkip("kein Server") }
        let a = AppModel(), b = AppModel()
        try await a.loginWithToken(server: s, token: t1, reset: true)
        try await b.loginWithToken(server: s, token: t2, reset: true)
        await a.syncNow()
        await b.syncNow()

        let title = "Sync-Test \(Int.random(in: 1000...9999))"
        let room = try XCTUnwrap(a.createRoom(kind: .chat, title: title))
        a.sendText(room: room, "Erster Eintrag", replyTo: nil)
        XCTAssertGreaterThan(a.pending, 0, "liegt zuerst nur lokal in der Warteschlange")
        XCTAssertEqual(a.store?.messages(room: room, limit: 10).first?.pending, true)

        // Foto (erfunden, erzeugt) und Sprachnotiz (Sinus) anhängen
        a.sendImage(room: room, data: try Self.makeJPEG())
        let voice = try Self.makeVoice()
        a.sendVoice(room: room, url: voice, duration: 1.0, wave: [0.2, 0.8, 0.4])
        a.sendChecklist(room: room, title: "Liste", items: ["Eins", "Zwei"])
        await a.syncNow()
        XCTAssertEqual(a.pending, 0)
        XCTAssertEqual(a.store?.messages(room: room, limit: 10).filter(\.pending).count, 0)

        await b.syncNow()
        await b.syncNow()  // zweiter Lauf lädt die Vorschauen
        let bRoom = try XCTUnwrap(b.store?.room(room))
        XCTAssertEqual(bRoom.title, title)
        let msgs = b.store?.messages(room: room, limit: 10) ?? []
        XCTAssertEqual(msgs.map(\.kind), [.text, .image, .voice, .checklist])
        let summary = b.store?.summaries(myDevice: b.myDevice, archived: false).first { $0.id == room }
        XCTAssertEqual(summary?.unread, 4, "Einträge von Gerät A zählen auf B als neu")
        let img = try XCTUnwrap(msgs.first { $0.kind == .image })
        XCTAssertNotNil(b.store?.fileURL(img.thumb!), "Vorschau wurde geladen")
        let v = try XCTUnwrap(msgs.first { $0.kind == .voice })
        XCTAssertNotNil(b.store?.fileURL(v.attachment!), "Sprachnotiz wurde geladen")

        // Fehlende Vorschau holt die Zelle selbst: einmal laden, auch bei zwei gleichzeitigen Anfragen, ohne Neuaufbau
        b.store?.removeFile(img.thumb!)
        XCTAssertNil(b.store?.fileURL(img.thumb!))
        let rev = b.revision
        let ref = FileRef(id: img.thumb!, name: "thumb.jpg", mime: "image/jpeg")
        async let u1 = b.file(ref)
        async let u2 = b.file(ref)
        let (f1, f2) = await (u1, u2)
        XCTAssertNotNil(f1)
        XCTAssertEqual(f1, f2)
        XCTAssertNotNil(b.store?.fileURL(img.thumb!), "Vorschau liegt wieder in der Ablage")
        XCTAssertEqual(b.revision, rev, "Laden einer Datei baut den Verlauf nicht neu auf")
        let items = b.store?.items(message: msgs.last!.id) ?? []
        XCTAssertEqual(items.map(\.text), ["Eins", "Zwei"])

        // B hakt ab und reagiert, A sieht es
        b.toggleItem(items[0])
        b.toggleReaction(msgs[0], emoji: "❤️")
        await b.syncNow()
        await a.syncNow()
        XCTAssertEqual(a.store?.items(message: msgs.last!.id).first?.done, true)
        XCTAssertEqual(a.store?.reactions(room: room, me: a.me)[msgs[0].id]?.first?.emoji, "❤️")

        // A löscht den Raum, B auch weg
        a.deleteRoom(room)
        await a.syncNow()
        await b.syncNow()
        XCTAssertNil(b.store?.room(room))
        await a.signOut(revoke: false)
        await b.signOut(revoke: false)
    }

    /// „Weiterleiten“: Kopie in einen anderen Raum, Anhänge als eigene Dateien (Löschen des Originals trifft die Kopie nicht).
    @MainActor func testForwardCopiesEntriesAndFiles() async throws {
        guard let s = env["THREAD_SERVER"], let t1 = env["THREAD_TOKEN"], let t2 = env["THREAD_TOKEN2"] else { throw XCTSkip("kein Server") }
        let a = AppModel(), b = AppModel()
        try await a.loginWithToken(server: s, token: t1, reset: true)
        try await b.loginWithToken(server: s, token: t2, reset: true)
        await a.syncNow()
        let n = Int.random(in: 1000...9999)
        let from = try XCTUnwrap(a.createRoom(kind: .chat, title: "Weiterleiten-Quelle \(n)"))
        let to = try XCTUnwrap(a.createRoom(kind: .chat, title: "Weiterleiten-Ziel \(n)"))
        a.sendText(room: from, "Bitte merken", replyTo: nil)
        a.sendImage(room: from, data: try Self.makeJPEG(), caption: "Bild")
        a.sendChecklist(room: from, title: "Liste", items: ["Eins", "Zwei"])
        a.sendPoll(room: from, question: "Wohin?", options: ["Nord", "Süd"], multi: false, showInterim: true)
        let originals = a.store?.messages(room: from, limit: 10) ?? []
        XCTAssertEqual(originals.map(\.kind), [.text, .image, .checklist, .poll])
        a.toggleItem(try XCTUnwrap(a.store?.items(message: originals[2].id).first))
        a.closePoll(originals[3])

        for m in a.store?.messages(room: from, limit: 10) ?? [] {
            let ok = await a.forward(m, to: to)
            XCTAssertTrue(ok, "\(m.kind)")
        }
        let copies = a.store?.messages(room: to, limit: 10) ?? []
        XCTAssertEqual(copies.map(\.kind), [.text, .image, .checklist, .poll])
        XCTAssertEqual(copies[0].body, "Bitte merken")
        XCTAssertEqual(copies[1].body, "Bild")
        XCTAssertNotEqual(copies[1].attachment, originals[1].attachment, "eigene Datei")
        XCTAssertNotEqual(copies[1].thumb, originals[1].thumb)
        XCTAssertEqual(a.store?.items(message: copies[2].id).map(\.text), ["Eins", "Zwei"])
        XCTAssertEqual(a.store?.items(message: copies[2].id).map(\.done), [false, false], "Kopie startet ohne Haken")
        XCTAssertNotEqual(copies[3].payload.closed, true, "Abstimmung startet neu")
        XCTAssertEqual(a.store?.messages(room: from, limit: 10).count, 4, "Originale bleiben")

        // Original-Bild löschen: die Kopie behält ihre Datei
        a.deleteMessage(originals[1])
        XCTAssertNotNil(a.store?.fileURL(try XCTUnwrap(copies[1].attachment)))
        await a.syncNow()
        XCTAssertEqual(a.pending, 0, "ein vor dem Abgleich gelöschter Eintrag mit Datei darf die Warteschlange nicht blockieren")
        await b.syncNow()
        await b.syncNow()
        let seen = b.store?.messages(room: to, limit: 10) ?? []
        XCTAssertEqual(seen.map(\.kind), [.text, .image, .checklist, .poll])
        XCTAssertNotNil(b.store?.fileURL(try XCTUnwrap(seen[1].thumb)), "Vorschau der Kopie kommt auf dem zweiten Gerät an")

        a.deleteRoom(from)
        a.deleteRoom(to)
        await a.syncNow()
        await a.signOut(revoke: false)
        await b.signOut(revoke: false)
    }

    @MainActor static func makeJPEG() throws -> Data {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(Media.jpeg(ctx.makeImage()!))
    }

    @MainActor static func makeVoice() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ton-\(newID()).m4a")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!
        buf.frameLength = 44100
        for i in 0..<44100 { buf.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.3) }
        try file.write(from: buf)
        return url
    }
}
