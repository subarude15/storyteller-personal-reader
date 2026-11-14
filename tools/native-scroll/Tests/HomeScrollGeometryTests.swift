import XCTest

/// Runtime assertions, NOT a source-text or policy-only substitute for layout proof.
/// Fixtures replace library data only; the host uses the production tab shell,
/// Home ScrollView/NavigationStack, Stats destination, inset modifier and bar chrome.
final class HomeScrollGeometryTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testHomeRestingBottomAndStatsTapMatrix() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            for type in ["normal", "accessibility"] {
                for player in ["playing", "paused", "hidden"] {
                    let name = "home-\(orientation.rawValue)-\(type)-\(player)"
                    try XCTContext.runActivity(named: name) { activity in
                        let app = launch(orientation: orientation, type: type, player: player)
                        defer { app.terminate() }
                        let scroll = app.scrollViews["geometry.scroll.home"]
                        XCTAssertTrue(scroll.waitForExistence(timeout: 15), name)
                        guard scroll.exists else { return }
                        try scrollToRestingBottom(scroll, app: app, probe: "home")
                        let stats = app.buttons["Open Stats"]
                        let upNext = element("geometry.upnext", in: app)
                        let metrics = try metrics("home", in: app)
                        attach(app, activity: activity, name: name, metrics: metrics)
                        XCTAssertTrue(stats.exists, "Stats must remain in the real Home hierarchy")
                        let ceiling = controlCeiling(app, player: player)
                        XCTAssertLessThanOrEqual(stats.frame.maxY, ceiling + 1,
                            "Stats require held overscroll: resting frame \(stats.frame), ceiling \(ceiling), metrics \(metrics)")
                        XCTAssertLessThanOrEqual(upNext.frame.maxY, ceiling + 1,
                            "Up Next metadata must be wholly above the controls at rest")
                        XCTAssertGreaterThanOrEqual(stats.frame.minY, scroll.frame.minY - 1)
                        XCTAssertTrue(stats.isHittable, "Visibility alone does not establish tappability")
                        // Coordinate tap prevents XCTest from silently auto-scrolling the target first.
                        // This happens AFTER measuring the released/settled state.
                        if stats.exists {
                            stats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                            XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 5),
                                "Tapping the resting stats button must open More -> Stats")
                        }
                    }
                }
            }
        }
    }

    func testMoreStatsRestingBottomMatrix() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            for type in ["normal", "accessibility"] {
                for player in ["playing", "paused", "hidden"] {
                    let name = "stats-\(orientation.rawValue)-\(type)-\(player)"
                    try XCTContext.runActivity(named: name) { activity in
                        let app = launch(orientation: orientation, type: type, player: player)
                        defer { app.terminate() }
                        app.tabBars.buttons["More"].tap()
                        let statsLink = app.buttons["Stats"].firstMatch
                        let hub = element("geometry.more.list", in: app)
                        // More is a lazy List: in landscape/accessibility sizes,
                        // the Stats row does not exist until scrolled into view.
                        // This navigates the HUB only; destination measurements
                        // and released-bottom assertions remain unchanged.
                        for _ in 0..<6 {
                            if statsLink.exists && statsLink.isHittable { break }
                            let start = hub.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                            let end = hub.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                            start.press(forDuration: 0.05, thenDragTo: end)
                        }
                        if !statsLink.exists || !statsLink.isHittable {
                            attach(app, activity: activity, name: "\(name)-hub-navigation",
                                metrics: ["stage": "More hub; geometry not measured yet"])
                        }
                        XCTAssertTrue(statsLink.waitForExistence(timeout: 5))
                        guard statsLink.exists else { return }
                        statsLink.tap()
                        let scroll = app.scrollViews["geometry.scroll.stats"]
                        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
                        guard scroll.exists else { return }
                        try scrollToRestingBottom(scroll, app: app, probe: "stats")
                        let metrics = try metrics("stats", in: app)
                        attach(app, activity: activity, name: name, metrics: metrics)
                        let last = element("geometry.stats.last", in: app)
                        XCTAssertTrue(last.exists, "The real Stats footer must be present")
                        XCTAssertLessThanOrEqual(last.frame.maxY, controlCeiling(app, player: player) + 1,
                            "Last Stats content must clear controls after releasing the gesture")
                    }
                }
            }
        }
    }

    func testStoppingPlayerCollapsesItsReservation() throws {
        let app = launch(orientation: .portrait, type: "normal", player: "paused")
        defer { app.terminate() }
        let scroll = app.scrollViews["geometry.scroll.home"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        let before = try metrics("home", in: app)
        app.buttons["Stop playback"].tap()
        XCTAssertTrue(element("geometry.player", in: app).waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let after = try metrics("home", in: app)
        let beforeInset = (before["adjustedInsetBottom"] as? Double) ?? -1
        let afterInset = (after["adjustedInsetBottom"] as? Double) ?? -1
        let beforeHeight = (before["viewportHeight"] as? Double) ?? 0
        let afterHeight = (after["viewportHeight"] as? Double) ?? 0
        XCTAssertTrue(afterInset < beforeInset - 1 || afterHeight > beforeHeight + 1,
            "Stopped bar must release its reservation, not leave a permanent empty gap: \(before) -> \(after)")
    }

    private func launch(orientation: UIDeviceOrientation, type: String, player: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["INKAMP_GEOMETRY_FIXTURE"] = "1"
        app.launchEnvironment["INKAMP_GEOMETRY_PLAYER"] = player
        app.launchEnvironment["INKAMP_GEOMETRY_DYNAMIC_TYPE"] = type
        app.launch()
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 0.6)
        if orientation == .portrait {
            XCTAssertGreaterThan(app.frame.height, app.frame.width, "Portrait must actually be active")
        } else {
            XCTAssertGreaterThan(app.frame.width, app.frame.height, "Landscape must actually be active")
        }
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func metrics(_ name: String, in app: XCUIApplication) throws -> [String: Any] {
        let probe = element("geometry.metrics.\(name)", in: app)
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "Native UIScrollView probe missing")
        let raw = probe.value as? String ?? "{}"
        let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        guard result["found"] as? Bool == true else {
            XCTFail("Probe failed to identify the actual vertical UIScrollView: \(raw)")
            throw NSError(domain: "HomeScrollGeometryProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: raw])
        }
        return result
    }

    private func scrollToRestingBottom(_ scroll: XCUIElement, app: XCUIApplication, probe: String) throws {
        // Each drag RELEASES. There is deliberately no press-and-hold assertion.
        for _ in 0..<16 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.6)
            let m = try metrics(probe, in: app)
            if let y = m["offsetY"] as? Double, let maxY = m["maxRestingOffsetY"] as? Double,
                abs(y - maxY) <= 1 { break }
        }
        Thread.sleep(forTimeInterval: 1)
        let m = try metrics(probe, in: app)
        XCTAssertEqual(m["isDragging"] as? Bool, false, "The measurement must not be taken while holding")
        XCTAssertEqual(m["isDecelerating"] as? Bool, false, "Wait for the scroll to settle")
        guard let y = m["offsetY"] as? Double, let maxY = m["maxRestingOffsetY"] as? Double else {
            XCTFail("No resting-offset measurements: \(m)"); return
        }
        XCTAssertEqual(y, maxY, accuracy: 1, "Must measure maximum RESTING scroll, not held rubber-banding")
    }

    private func controlCeiling(_ app: XCUIApplication, player: String) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        let bar = element("geometry.player", in: app)
        if player == "hidden" {
            XCTAssertFalse(bar.exists)
            return tabBar.frame.minY
        }
        XCTAssertTrue(bar.exists, "Fixture must show the actual mini-player chrome")
        XCTAssertTrue(app.buttons[player == "playing" ? "Pause" : "Play"].exists,
            "The requested transport state must actually be visible")
        return min(bar.frame.minY, tabBar.frame.minY)
    }

    private func attach(_ app: XCUIApplication, activity: XCTActivity, name: String, metrics: [String: Any]) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        activity.add(screenshot)
        let text = XCTAttachment(string: "\(metrics)\n\(app.debugDescription)")
        text.name = "\(name)-geometry-and-accessibility"
        text.lifetime = .keepAlways
        activity.add(text)
    }
}
