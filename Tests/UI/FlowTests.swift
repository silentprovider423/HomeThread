import XCTest

/// Kernabläufe in der echten App gegen das Testkonto (Startumgebung aus test.sh: THREAD_SERVER, THREAD_TOKEN, THREAD_TOKEN2).
final class FlowTests: XCTestCase {
    var app: XCUIApplication!
    var env: [String: String] { ProcessInfo.processInfo.environment }
    /// Titel der Räume, die dieser Test anlegt – tearDown löscht sie wieder (auch nach einem Fehlschlag)
    private var created: [String] = []
    /// Kennung des Laufs, damit Titel eindeutig sind („UI Einkauf 4711“)
    private let run = String(Int.random(in: 1000...9999))

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let s = env["THREAD_SERVER"], let t = env["THREAD_TOKEN"], !s.isEmpty, !t.isEmpty else {
            throw XCTSkip("Kein Test-Server konfiguriert")
        }
        app = XCUIApplication()
        app.launchEnvironment = ["THREAD_SERVER": s, "THREAD_TOKEN": t, "THREAD_RESET": "1", "THREAD_UITEST": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 20))
    }

    override func tearDownWithError() throws {
        guard !created.isEmpty, let s = env["THREAD_SERVER"], let t = env["THREAD_TOKEN"] else { return }
        app?.terminate()
        let titles = created
        let n = try TestRooms.delete(server: s, token: t, in: self) { title in titles.contains { title.hasPrefix($0) } }
        print("aufgeräumt: \(n) Räume")
    }

    private func newRoom(group: Bool, name: String) {
        created.append(name)
        app.buttons["chats.new"].tap()
        app.buttons[group ? "Neue Gruppe" : "Neuer Chat"].firstMatch.tap()
        if group {
            app.buttons["newroom.next"].tap()
        }
        let field = app.textFields["newroom.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["newroom.create"].tap()
        XCTAssertTrue(app.textViews["input.text"].waitForExistence(timeout: 10) || app.textFields["input.text"].waitForExistence(timeout: 2))
    }

    private var input: XCUIElement {
        app.textViews["input.text"].exists ? app.textViews["input.text"] : app.textFields["input.text"]
    }

    private func send(_ text: String) {
        input.tap()
        input.typeText(text)
        app.buttons["input.send"].tap()
    }

    /// Feld in einem gerade erscheinenden Blatt füllen: warten, bis es antippbar ist (Animation des Blatts).
    private func fill(_ id: String, _ text: String) {
        let f = app.textFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 5))
        let ready = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: f)
        wait(for: [ready], timeout: 5)
        f.tap()
        if !(f.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { usleep(500_000); f.tap() }
        f.typeText(text)
    }

    private func attach(_ title: String) {
        app.buttons["input.attach"].tap()
        let b = app.buttons[title].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        b.tap()
    }

    func testCreateChatWriteTextAndSearch() throws {
        let word = "Zitronen\(Int.random(in: 1000...9999))"
        newRoom(group: false, name: "UI Einkauf \(run)")
        send("Bitte \(word) mitbringen")
        XCTAssertTrue(app.staticTexts["Bitte \(word) mitbringen"].waitForExistence(timeout: 5))
        // Antwort per Kontextmenü
        app.staticTexts["Bitte \(word) mitbringen"].press(forDuration: 1.0)
        app.buttons["Darauf antworten"].tap()
        send("Erledigt")
        XCTAssertTrue(app.staticTexts["Erledigt"].waitForExistence(timeout: 5))
        // Suche über alle Chats (Suchfeld der Chat-Liste) findet den Eintrag (Wortanfang reicht)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(String(word.prefix(11)).lowercased())
        XCTAssertTrue(app.buttons["search.hit"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["search.hit"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bitte \(word) mitbringen"].waitForExistence(timeout: 5))
    }

    func testGroupWithPollChecklistAndInfo() throws {
        let group = "UI Gruppe \(run)"
        newRoom(group: true, name: group)
        attach("Abstimmung anlegen")
        fill("poll.question", "Pizza oder Pasta?")
        fill("poll.option.0", "Pizza")
        fill("poll.option.1", "Pasta")
        app.buttons["poll.create"].tap()
        let option = app.buttons["poll.option.Pasta"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()

        attach("Checkliste anlegen")
        fill("checklist.title", "Einkauf")
        fill("checklist.item.0", "Mehl")
        app.buttons["checklist.create"].tap()
        let item = app.buttons["check.Mehl"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()

        // Gruppen-Info: umbenennen
        app.buttons["chat.header"].tap()
        XCTAssertTrue(app.buttons["info.rename"].waitForExistence(timeout: 5))
        app.buttons["info.rename"].tap()
        let name = app.textFields["info.name"]
        name.tap()
        name.typeText(" 2\n")
        XCTAssertTrue(app.staticTexts["\(group) 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["info.addPerson"].exists)
    }

    func testVoiceNote() throws {
        newRoom(group: false, name: "UI Sprachnotiz \(run)")
        app.buttons["input.mic"].tap()
        let send = app.buttons["input.voice.send"]
        guard send.waitForExistence(timeout: 5) else {
            throw XCTSkip("Simulator hat kein Mikrofon freigegeben")
        }
        sleep(2)
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bubble.voice"].waitForExistence(timeout: 5))
    }

    /// Zweites Gerät legt per API einen Chat an → die App zeigt ihn nach dem Abgleich als „neu von anderem Gerät“.
    func testSecondDeviceChangeAppears() throws {
        guard let s = env["THREAD_SERVER"], let t2 = env["THREAD_TOKEN2"] else { throw XCTSkip("kein zweites Gerät") }
        let title = "Von Gerät B \(run)"
        created.append(title)
        let room = UUID().uuidString.lowercased()
        let body: [String: Any] = ["ops": [
            ["op_id": UUID().uuidString, "type": "room.create", "room": ["id": room, "kind": "chat", "title": title]],
            ["op_id": UUID().uuidString, "type": "msg.create", "msg": ["id": UUID().uuidString.lowercased(), "room_id": room, "body": "Hallo vom Mac"]],
        ]]
        var r = URLRequest(url: URL(string: s + "/api/ops")!)
        r.httpMethod = "POST"
        r.setValue("Bearer " + t2, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let done = expectation(description: "ops")
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        // Abgleich kommt spätestens nach 15 s von selbst
        let row = app.buttons["chat.\(title)"]
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        XCTAssertTrue(row.staticTexts["1"].exists || row.label.contains("1"), "Ungelesen-Zähler sichtbar")
        row.tap()
        XCTAssertTrue(app.staticTexts["Hallo vom Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Neu von anderem Gerät")).firstMatch.exists)
        // aufräumen
        app.buttons["chat.header"].tap()
        let del = app.buttons["info.delete"]
        for _ in 0..<5 where !del.isHittable { app.swipeUp() }
        del.tap()
        app.buttons["Löschen"].firstMatch.tap()
    }
}

/// Räume des Testkontos über die API löschen (nur Titel, die der Test selbst angelegt hat).
enum TestRooms {
    static func call(_ server: String, _ token: String, _ path: String, _ body: Any? = nil, in tc: XCTestCase) throws -> [String: Any] {
        var r = URLRequest(url: URL(string: server + path)!)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        nonisolated(unsafe) var out: [String: Any] = [:]
        let done = tc.expectation(description: path)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            out = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            done.fulfill()
        }.resume()
        tc.wait(for: [done], timeout: 30)
        return out
    }

    @discardableResult
    static func delete(server: String, token: String, in tc: XCTestCase, where match: (String) -> Bool) throws -> Int {
        var rooms: [String: [String: Any]] = [:]
        var since = 0
        while true {
            let page = try call(server, token, "/api/sync?since=\(since)&limit=1000", in: tc)
            for c in page["changes"] as? [[String: Any]] ?? [] where c["kind"] as? String == "room" {
                if let d = c["data"] as? [String: Any], let id = d["id"] as? String { rooms[id] = d }
            }
            since = page["next"] as? Int ?? since
            if page["more"] as? Bool != true { break }
        }
        let ids = rooms.values.filter { ($0["deleted"] as? Int ?? 0) == 0 && match($0["title"] as? String ?? "") }.compactMap { $0["id"] as? String }
        if !ids.isEmpty {
            _ = try call(server, token, "/api/ops", ["ops": ids.map { ["op_id": UUID().uuidString, "type": "room.delete", "room_id": $0] }], in: tc)
        }
        return ids.count
    }
}
