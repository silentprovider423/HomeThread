import XCTest

/// Leistungsmessung mit synthetischen Daten (THREAD_PERF_SEED, nur lokal im Simulator des Testkontos):
/// Raum „Perf 2000“ (2.000 gemischte Einträge) und 518 Räume in der Chat-Liste.
///   ./test.sh -only-testing:HomeThreadUITests/PerfTests
final class PerfTests: XCTestCase {
    var app: XCUIApplication!
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let s = Self.env["THREAD_SERVER"], let t = Self.env["THREAD_TOKEN"], !s.isEmpty, !t.isEmpty else {
            throw XCTSkip("Kein Test-Server konfiguriert")
        }
        app = XCUIApplication()
        app.launchEnvironment = ["THREAD_SERVER": s, "THREAD_TOKEN": t, "THREAD_UITEST": "1", "THREAD_PERF_SEED": "1",
                                 "THREAD_PERF_AUTOSCROLL": name.contains("testScrollToBeginning") ? "4000" : "",
                                 "THREAD_PERF_TAG": name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "-"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.Perf 2000"].waitForExistence(timeout: 120), "Leistungsdaten fehlen")
    }

    /// Synthetische Daten wieder löschen: App einmal mit THREAD_RESET=1 starten (lokale Daten des Testkontos weg).
    override class func tearDown() {
        MainActor.assumeIsolated {
            guard let s = env["THREAD_SERVER"], let t = env["THREAD_TOKEN"] else { return }
            let app = XCUIApplication()
            app.launchEnvironment = ["THREAD_SERVER": s, "THREAD_TOKEN": t, "THREAD_UITEST": "1", "THREAD_RESET": "1"]
            app.launch()
            _ = app.buttons["chats.new"].waitForExistence(timeout: 30)
            app.terminate()
        }
        super.tearDown()
    }

    private var bubbles: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "bubble."))
    }

    /// Raum öffnen und warten, bis Einträge sichtbar sind. Rückgabe false = Verlauf blieb leer (ohne Berührung).
    @discardableResult
    private func openPerfRoom(nudge: Bool = true) -> Bool {
        app.buttons["chat.Perf 2000"].tap()
        let shown = bubbles.firstMatch.waitForExistence(timeout: 8)
        if !shown {
            print("PERF Verlauf leer nach dem Öffnen")
            if nudge { app.swipeUp(velocity: .slow); app.swipeDown(velocity: .slow) }
        }
        if nudge { XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 10)) }
        return shown
    }

    private var newLine: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Neu von anderem Gerät")).firstMatch
    }

    private var scrollOptions: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.invocationOptions = [.manuallyStop]
        o.iterationCount = 6
        return o
    }

    /// Chat-Liste (518 Räume): schnell nach unten wischen.
    func testChatListScrollHitches() {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: scrollOptions) {
            list.swipeUp(velocity: .fast)
            stopMeasuring()
            list.swipeUp(velocity: .fast)
        }
    }

    /// Zeit vom Antippen bis der Verlauf sichtbar ist (unten, mit „Neu von anderem Gerät“).
    func testOpenChatTime() {
        let o = XCTMeasureOptions()
        o.invocationOptions = [.manuallyStart, .manuallyStop]
        o.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: o) {
            startMeasuring()
            let ok = openPerfRoom(nudge: false)
            stopMeasuring()
            print("PERF geöffnet sichtbar=\(ok)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["chat.Perf 2000"].waitForExistence(timeout: 10))
        }
    }

    /// Im großen Raum von unten nach oben in die Vergangenheit wischen (Hitch-Rate beim Hochscrollen).
    func testScrollUpHitches() {
        openPerfRoom()
        let o = scrollOptions
        o.iterationCount = 10
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: o) {
            app.swipeDown(velocity: .fast)
            stopMeasuring()
        }
    }

    /// Ganzen Verlauf bis zum ersten Eintrag hochscrollen (Nachladen älterer Seiten läuft beim Scrollen mit): Hitches.
    /// Die App scrollt selbst gleichmäßig (THREAD_PERF_AUTOSCROLL, 4.000 pt/s); der Test fragt währenddessen nichts ab,
    /// weil jede XCTest-Abfrage im großen Verlauf alle geladenen Zeilen aufbaut (bis 2 s Main-Thread) und das Ergebnis verfälscht.
    func testScrollToBeginningWithLoading() {
        openPerfRoom()
        Thread.sleep(forTimeInterval: 150)
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Eintrag 0001")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 60), "erster Eintrag nicht erreicht")
    }
}
