import CoreFoundation
import XCTest

/// The original 48-case suite remains unchanged. These tests add the production
/// root/presenter/live-bar lifecycle, rather than another fixture visibility toggle.
final class HomeLifecycleGeometryTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    func testFullscreenDismissThenReleasedHomeBottomMatrix() throws {
        try matrix(flow: "cover")
    }

    func testAsyncSessionAfterReleasedHomeBottomMatrix() throws {
        try matrix(flow: "async")
    }

    func testHeadlessStartupSessionThenReleasedHomeBottomMatrix() throws {
        try matrix(flow: "launch")
    }

    private func matrix(flow: String) throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            for type in ["normal", "accessibility"] {
                for player in ["playing", "paused"] {
                    let name = "lifecycle-\(flow)-\(orientation.rawValue)-\(type)-\(player)"
                    do {
                    try XCTContext.runActivity(named: name) { activity in
                        XCUIDevice.shared.orientation = orientation
                        let app = XCUIApplication()
                        app.launchEnvironment = [
                            "INKAMP_GEOMETRY_FIXTURE": "0",
                            "INKAMP_GEOMETRY_LIFECYCLE": flow,
                            "INKAMP_GEOMETRY_PLAYER": player,
                            "INKAMP_GEOMETRY_HOME_PROFILE": "bedtime",
                            "INKAMP_GEOMETRY_DYNAMIC_TYPE": type,
                            "INKAMP_GEOMETRY_RESTORE_AFTER_LAYOUT": "0",
                        ]
                        app.launch()
                        defer { app.terminate() }
                        XCUIDevice.shared.orientation = orientation
                        if orientation == .portrait {
                            XCTAssertGreaterThan(app.frame.height, app.frame.width)
                        } else {
                            XCTAssertGreaterThan(app.frame.width, app.frame.height)
                        }
                        // Retain a screenshot, state and any readable scroll metrics
                        // even if an early lifecycle/probe guard throws.
                        defer {
                            attach(app, activity: activity, name: "\(name)-completion",
                                payload: (try? state(app)) ?? ["stateUnavailable": true])
                        }
                        XCTAssertTrue(element("geometry.lifecycle.state", app).waitForExistence(timeout: 20))
                        XCTAssertFalse(app.buttons["Restore fixture player"].exists,
                            "Lifecycle mode must not inject or mutate a navigation-toolbar button")
                        var before: [String: Any]
                        if flow == "cover" {
                            let cover = element("geometry.lifecycle.cover", app)
                            XCTAssertTrue(cover.waitForExistence(timeout: 15),
                                "Actual production fullScreenCover must present through PlayerPresenter")
                            guard cover.exists else { throw failure("Full-screen presentation missing") }
                            before = try waitForState(app) { s in
                                s["rootRestored"] as? Bool == true
                                    && s["presenterHasCard"] as? Bool == true
                                    && s["monitorHasSnapshot"] as? Bool == true
                                    && s["policyDocked"] as? Bool == false
                                    && (s["coverAppearances"] as? Int ?? 0) >= 1
                            }
                            XCTAssertEqual(before["rootRestored"] as? Bool, true)
                            XCTAssertEqual(before["presenterHasCard"] as? Bool, true)
                            XCTAssertEqual(before["monitorHasSnapshot"] as? Bool, true)
                            XCTAssertEqual(before["policyDocked"] as? Bool, false)
                            XCTAssertGreaterThan(cover.frame.height, app.frame.height * 0.7)
                            attach(app, activity: activity, name: "\(name)-cover-present", payload: before)
                            let dismiss = app.buttons["Minimize local player"]
                            XCTAssertTrue(dismiss.exists)
                            guard dismiss.exists else { throw failure("Cover dismissal control missing") }
                            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                            XCTAssertTrue(cover.waitForNonExistence(timeout: 10))
                            XCTAssertTrue(element("geometry.player", app).waitForExistence(timeout: 10))
                        } else if flow == "async" {
                            let scroll = app.scrollViews["geometry.scroll.home"]
                            XCTAssertTrue(scroll.waitForExistence(timeout: 15))
                            XCTAssertFalse(element("geometry.player", app).exists)
                            try scrollToRestingBottom(scroll, app: app)
                            before = try state(app)
                            let beforeMetrics = try metrics(app)
                            XCTAssertEqual(before["publicationRequests"] as? Int, 0)
                            XCTAssertEqual(before["monitorHasSnapshot"] as? Bool, false)
                            XCTAssertEqual(before["presenterHasCard"] as? Bool, false)
                            attach(app, activity: activity, name: "\(name)-hidden-bottom",
                                payload: ["state": before, "metrics": beforeMetrics])
                            before["settledHome"] = beforeMetrics
                            // Cross-process notification: no touch, toolbar, keyboard,
                            // URL navigation or foreground/background transition.
                            CFNotificationCenterPostNotification(
                                CFNotificationCenterGetDarwinNotifyCenter(),
                                CFNotificationName(rawValue: "com.punkrally.geometry.publish-session" as CFString),
                                nil, nil, true)
                            XCTAssertTrue(element("geometry.player", app).waitForExistence(timeout: 10))
                        } else {
                            before = try waitForState(app) { s in
                                s["rootRestored"] as? Bool == true
                                    && s["monitorHasSnapshot"] as? Bool == true
                                    && s["presenterHasCard"] as? Bool == false
                                    && s["policyDocked"] as? Bool == true
                            }
                            XCTAssertFalse(element("geometry.lifecycle.cover", app).exists)
                            attach(app, activity: activity, name: "\(name)-headless-startup", payload: before)
                        }
                        let scroll = app.scrollViews["geometry.scroll.home"]
                        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
                        guard scroll.exists else { throw failure("Home scroll view missing") }
                        let revealed = try waitForState(app) { s in
                            s["rootRestored"] as? Bool == true
                                && s["presenterHasCard"] as? Bool == false
                                && s["monitorHasSnapshot"] as? Bool == true
                                && s["policyDocked"] as? Bool == true
                                && s["monitorIsPlaying"] as? Bool == (player == "playing")
                                && s["publicationRequests"] as? Int == 1
                                && (flow != "cover" || (s["coverDisappearances"] as? Int ?? 0) >= 1)
                        }
                        let revealedMetrics = try metrics(app)
                        attach(app, activity: activity, name: "\(name)-revealed",
                            payload: ["state": revealed, "metrics": revealedMetrics])
                        XCTAssertEqual(revealed["presenterHasCard"] as? Bool, false)
                        XCTAssertEqual(revealed["monitorHasSnapshot"] as? Bool, true)
                        XCTAssertEqual(revealed["policyDocked"] as? Bool, true)
                        XCTAssertEqual(revealed["publicationRequests"] as? Int, 1)
                        XCTAssertEqual(revealed["renderPath"] as? String, "liveContent")
                        XCTAssertEqual(revealed["fixtureSwapEnabled"] as? Bool, false)
                        XCTAssertEqual(revealed["rootRestored"] as? Bool, true)
                        XCTAssertEqual(revealed["monitorIsPlaying"] as? Bool, player == "playing")
                        if flow == "async" {
                            let atPublication = try XCTUnwrap(revealed["publicationHome"] as? [String: Any])
                            XCTAssertEqual(atPublication["found"] as? Bool, true,
                                "Actor publication must record the real Home scroll boundary")
                            XCTAssertEqual(atPublication["isDragging"] as? Bool, false)
                            XCTAssertEqual(atPublication["isDecelerating"] as? Bool, false)
                            let y = try XCTUnwrap(atPublication["offsetY"] as? Double)
                            let maxY = try XCTUnwrap(atPublication["maxRestingOffsetY"] as? Double)
                            XCTAssertEqual(y, maxY, accuracy: 1,
                                "Session must be published AFTER Home settled at its resting bottom")
                        }
                        if flow == "cover" {
                            XCTAssertGreaterThanOrEqual(revealed["coverAppearances"] as? Int ?? 0, 1)
                            XCTAssertGreaterThanOrEqual(revealed["coverDisappearances"] as? Int ?? 0, 1)
                        }
                        try scrollToRestingBottom(scroll, app: app)
                        let m = try metrics(app)
                        let stats = app.buttons["Open Stats"]
                        let upNext = element("geometry.upnext", app)
                        let bar = element("geometry.player", app)
                        let tabBar = app.tabBars.firstMatch
                        let ceiling = min(bar.frame.minY, tabBar.frame.minY)
                        attach(app, activity: activity, name: name, payload: [
                            "flow": flow, "before": before, "revealed": revealedMetrics,
                            "after": m, "state": try state(app),
                            "statsFrame": frame(stats), "playerFrame": frame(bar),
                            "upNextFrame": frame(upNext), "tabBarFrame": frame(tabBar),
                        ])
                        XCTAssertTrue(element("geometry.continue.production", app).exists)
                        XCTAssertTrue(stats.exists, "Stats must remain in the real Home hierarchy")
                        XCTAssertTrue(upNext.exists)
                        XCTAssertTrue(bar.exists)
                        XCTAssertTrue(tabBar.exists)
                        XCTAssertTrue(app.buttons[player == "playing" ? "Pause" : "Play"].exists)
                        // Same geometry/tap contract as the preserved baseline, no
                        // increased tolerance or automatic scrolling element.tap().
                        XCTAssertLessThanOrEqual(stats.frame.maxY, ceiling + 1,
                            "Stats require held overscroll: resting frame \(stats.frame), ceiling \(ceiling), metrics \(m)")
                        XCTAssertLessThanOrEqual(upNext.frame.maxY, ceiling + 1,
                            "Up Next metadata must be wholly above the controls at rest")
                        XCTAssertGreaterThanOrEqual(stats.frame.minY, scroll.frame.minY - 1)
                        XCTAssertTrue(stats.isHittable, "Visibility alone does not establish tappability")
                        if stats.exists {
                            stats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                            XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 5),
                                "Tapping the resting stats button must open More -> Stats")
                        }
                    }
                    } catch {
                        XCTFail("Lifecycle case \(name) failed; evidence retained: \(error)")
                    }
                }
            }
        }
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func read(_ id: String, _ app: XCUIApplication) throws -> [String: Any] {
        let probe = element(id, app)
        guard probe.waitForExistence(timeout: 5), let raw = probe.value as? String,
            let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw failure("Missing/unreadable native probe \(id)") }
        return result
    }

    private func state(_ app: XCUIApplication) throws -> [String: Any] {
        try read("geometry.lifecycle.state", app)
    }

    private func waitForState(_ app: XCUIApplication,
        matching predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        var last: [String: Any] = [:]
        repeat {
            last = try state(app)
            if predicate(last) { return last }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("Production lifecycle did not reach required state: \(last)")
        throw failure("Lifecycle state timeout: \(last)")
    }

    private func metrics(_ app: XCUIApplication) throws -> [String: Any] {
        let m = try read("geometry.metrics.home", app)
        guard m["found"] as? Bool == true else { throw failure("Home native scroll not found: \(m)") }
        return m
    }

    private func scrollToRestingBottom(_ scroll: XCUIElement, app: XCUIApplication) throws {
        for _ in 0..<16 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.6)
            let m = try metrics(app)
            if let y = m["offsetY"] as? Double, let maxY = m["maxRestingOffsetY"] as? Double,
                abs(y - maxY) <= 1 { break }
        }
        Thread.sleep(forTimeInterval: 1)
        let m = try metrics(app)
        XCTAssertEqual(m["isDragging"] as? Bool, false, "The measurement must not be taken while holding")
        XCTAssertEqual(m["isDecelerating"] as? Bool, false, "Wait for the scroll to settle")
        guard m["isDragging"] as? Bool == false, m["isDecelerating"] as? Bool == false else {
            throw failure("Home still moving; refusing to publish a session before settling: \(m)")
        }
        guard let y = m["offsetY"] as? Double, let maxY = m["maxRestingOffsetY"] as? Double
        else { throw failure("No resting-offset measurements: \(m)") }
        XCTAssertEqual(y, maxY, accuracy: 1, "Must measure maximum RESTING scroll, not held rubber-banding")
        guard abs(y - maxY) <= 1 else {
            throw failure("Home not at resting bottom; refusing to advance lifecycle: \(m)")
        }
    }

    private func frame(_ e: XCUIElement) -> [String: Double] {
        ["minX": Double(e.frame.minX), "minY": Double(e.frame.minY),
         "maxX": Double(e.frame.maxX), "maxY": Double(e.frame.maxY)]
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "HomeLifecycleGeometry", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func attach(_ app: XCUIApplication, activity: XCTActivity, name: String,
        payload: [String: Any]) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        activity.add(image)
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
            let text = XCTAttachment(string: String(decoding: data, as: UTF8.self) + "\n" + app.debugDescription)
            text.name = "\(name)-geometry-and-accessibility"
            text.lifetime = .keepAlways
            activity.add(text)
        } catch { XCTFail("Cannot retain lifecycle evidence: \(error)") }
    }
}
