import Foundation
import XCTest
@testable import R6CPhoneControl

final class LineParserTests: XCTestCase {
    @MainActor
    func testDJIProfileRoundTripOnConnectedHardware() async throws {
        guard ProcessInfo.processInfo.environment["R6C_DJI_INTEGRATION"] == "1" else {
            throw XCTSkip("Set R6C_DJI_INTEGRATION=1 with a DJI IG830 attached to run this test.")
        }

        let model = AppModel()
        await model.refreshDJIStatus()
        XCTAssertTrue(model.djiSnapshot.isConnected, model.djiLog)

        await model.refreshDJIProfiles()
        let original = try XCTUnwrap(model.djiProfiles.first(where: \.isEnabled))
        let alternate = try XCTUnwrap(model.djiProfiles.first {
            !$0.isEnabled && $0.provider.localizedCaseInsensitiveContains("Saily")
        })

        model.switchDJIProfile(alternate)
        let alternateFinished = await waitForDJIProfileOperation(model)
        XCTAssertTrue(alternateFinished, model.djiLog)
        XCTAssertTrue(
            model.djiProfiles.contains { $0.iccid == alternate.iccid && $0.isEnabled },
            model.djiLog
        )

        try? await Task.sleep(for: .seconds(10))
        if let originalNow = model.djiProfiles.first(where: { $0.iccid == original.iccid }),
           !originalNow.isEnabled {
            model.switchDJIProfile(originalNow)
            let originalFinished = await waitForDJIProfileOperation(model)
            XCTAssertTrue(originalFinished, model.djiLog)
        }

        XCTAssertTrue(
            model.djiProfiles.contains { $0.iccid == original.iccid && $0.isEnabled },
            model.djiLog
        )
        XCTAssertTrue(model.djiLog.contains("Active eSIM"), model.djiLog)
    }

    func testDJIATClientTerminatesHungHelper() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r6c-dji-at-timeout-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let helper = directory.appendingPathComponent("dji-at-helper")
        try "#!/bin/sh\nexec /bin/sleep 30\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let client = DJIATClient(helperPath: helper.path)
        let started = Date()
        let result = await client.run(["raw", "AT+QCCID"], timeout: 0.2)

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.output.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    @MainActor
    private func waitForDJIProfileOperation(
        _ model: AppModel,
        timeout: TimeInterval = 240
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while model.djiProfileInFlight, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !model.djiProfileInFlight
    }

    func testHelperUsesLocalADBWhenSSHHostIsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r6c-local-adb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeADB = directory.appendingPathComponent("adb")
        try """
        #!/bin/sh
        printf 'List of devices attached\\nlocal123 device product:grus model:MI_9_SE device:grus\\n'
        """.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeADB.path)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repository.appendingPathComponent("Scripts/r6c-phone-control.sh").path, "devices"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "R6C_ADB": fakeADB.path,
            "R6C_SSH_HOST": ""
        ]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains(#"DEVICE serial="local123" state="device" model="MI_9_SE""#), text)
    }

    func testRedactsActivationCodesFromLogs() {
        let redacted = SensitiveLogRedactor.redact(#"{"activationCode":"LPA:1$server.example$SECRET123456789012345","matchingId":"SECRET123456789012345"} LPA:1$server.example$SECRET123456789012345"#)

        XCTAssertFalse(redacted.contains("SECRET123456789012345"))
        XCTAssertTrue(redacted.contains(#""activationCode":"[REDACTED]""#))
        XCTAssertTrue(redacted.contains(#""matchingId":"[REDACTED]""#))
    }

    func testRedactsFormattedJSONAndFullICCIDFromLogs() {
        let redacted = SensitiveLogRedactor.redact("""
        {
          "activationCode" : "ACTIVATION-SECRET",
          "matchingId" : "MATCHING-SECRET",
          "iccid" : "8985207220082439520"
        }
        +QCCID: 8985207220082439520F
        """)

        XCTAssertFalse(redacted.contains("ACTIVATION-SECRET"))
        XCTAssertFalse(redacted.contains("MATCHING-SECRET"))
        XCTAssertFalse(redacted.contains("8985207220082439520"))
        XCTAssertTrue(redacted.contains(#""activationCode":"[REDACTED]""#))
        XCTAssertTrue(redacted.contains(#""matchingId":"[REDACTED]""#))
        XCTAssertTrue(redacted.contains("+QCCID: [REDACTED]"))
    }

    func testParsesDeviceLines() {
        let devices = R6CLineParser.devices(#"DEVICE serial="demo123" state="device" model="Mi_10" product="umi" device="umi""#)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "demo123")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[0].model, "Mi_10")
        XCTAssertEqual(devices[0].product, "umi")
        XCTAssertEqual(devices[0].device, "umi")
        XCTAssertTrue(devices[0].isReady)
    }

    func testStatusFieldsParsePhoneState() {
        let fields = R6CLineParser.statusFields("""
        adb=connected
        battery=100% full
        mobile_data=on
        wifi=off
        bluetooth=on
        carrier=中国移动
        network=LTE disconnected; default=none
        """)

        XCTAssertEqual(fields["battery"], "100% full")
        XCTAssertEqual(fields["mobile_data"], "on")
        XCTAssertEqual(fields["wifi"], "off")
        XCTAssertEqual(fields["bluetooth"], "on")
        XCTAssertEqual(fields["carrier"], "中国移动")
        XCTAssertEqual(fields["network"], "LTE disconnected; default=none")
    }

    func testMarksUnauthorizedDevicesAsNotReady() {
        let devices = R6CLineParser.devices(#"DEVICE serial="bad" state="unauthorized" model="" product="" device="""#)

        XCTAssertEqual(devices.count, 1)
        XCTAssertFalse(devices[0].isReady)
    }

    func testParsesPhoneMessages() {
        let messages = R6CLineParser.messages("""
        SMS\t1719662400000\t+85212345678\t1\thello from inbox
        SMS\t1719662500000\t10086\t2\tsent body
        """)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].address, "+85212345678")
        XCTAssertEqual(messages[0].typeLabel, "Inbox")
        XCTAssertEqual(messages[0].body, "hello from inbox")
        XCTAssertEqual(messages[1].typeLabel, "Sent")
    }

    func testParsesProfileLines() {
        let profiles = R6CLineParser.profiles("""
        PROFILE name="Personal EU" state="已禁用" provider="Club" iccid="8985201111111111111"
        PROFILE name="Travel US" state="已启用" provider="Saily" iccid="8985202222222222222"
        """)

        XCTAssertEqual(profiles.map(\.provider), ["Club", "Saily"])
        XCTAssertEqual(profiles.map(\.iccid), ["8985201111111111111", "8985202222222222222"])
        XCTAssertFalse(profiles[0].isEnabled)
        XCTAssertTrue(profiles[1].isEnabled)
    }

    func testParsesRealProfileLinesWithCRLFAndClassField() {
        let profiles = R6CLineParser.profiles("PROFILE name=\"mother\" state=\"已禁用\" provider=\"Club\" iccid=\"8985200014631312207\" class=\"Operational\"\r\nPROFILE name=\"WEBBING\" state=\"已启用\" provider=\"Saily\" iccid=\"89852351225047364845\" class=\"Operational\"\r\n")

        XCTAssertEqual(profiles.map(\.name), ["mother", "WEBBING"])
        XCTAssertEqual(profiles.map(\.provider), ["Club", "Saily"])
        XCTAssertEqual(profiles.map(\.iccid), ["8985200014631312207", "89852351225047364845"])
        XCTAssertFalse(profiles[0].isEnabled)
        XCTAssertTrue(profiles[1].isEnabled)
    }

    func testParsesProfileJSONUsingDisplayNameAndLocalizedState() {
        let profiles = R6CLineParser.profilesJSON("""
        [{"iccid":"8985200014631312207","state":"Disabled","name":"Club","nickName":"mother","displayName":"mother","provider":"Club","class":"Operational"},{"iccid":"89852351225047364845","state":"Enabled","name":"WEBBING","nickName":"","displayName":"WEBBING","provider":"Saily","class":"Operational"}]
        """)

        XCTAssertEqual(profiles.map(\.name), ["mother", "WEBBING"])
        XCTAssertEqual(profiles.map(\.state), ["已禁用", "已启用"])
        XCTAssertEqual(profiles.map(\.provider), ["Club", "Saily"])
        XCTAssertEqual(profiles.map(\.iccid), ["8985200014631312207", "89852351225047364845"])
    }

    func testProfileSwitchArgumentsPreferIccid() {
        let profile = Profile(name: "Travel Japan", state: "已禁用", provider: "Saily", iccid: "8985201234567890123")

        XCTAssertEqual(profile.switchArguments, ["switch-iccid", "8985201234567890123"])
    }

    func testProfileSwitchArgumentsUseExactIdentityWhenIccidIsMissing() {
        let profile = Profile(name: "Travel Japan", state: "已禁用", provider: "Saily")

        XCTAssertEqual(profile.switchArguments, ["switch-exact", "Travel Japan", "Saily"])
    }

    func testProfilesUseIccidAsIdentityWhenAvailable() {
        let first = Profile(name: "Travel Japan", state: "已禁用", provider: "Saily", iccid: "8985201111111111111")
        let duplicateName = Profile(name: "Travel Japan", state: "已启用", provider: "Saily", iccid: "8985202222222222222")

        XCTAssertEqual(Profile.ambiguousIdentityKeys(in: [first, duplicateName]), [])
    }

    func testProfilesReportAmbiguousSwitchIdentity() {
        let first = Profile(name: "Travel Japan", state: "已禁用", provider: "Saily")
        let duplicate = Profile(name: "Travel Japan", state: "已启用", provider: "Saily")
        let other = Profile(name: "Travel Japan", state: "已禁用", provider: "Club")

        XCTAssertEqual(Profile.ambiguousIdentityKeys(in: [first, duplicate, other]), [first.identityKey])
    }

    func testProfileFilterSearchesVisibleIdentityFields() {
        let saily = Profile(name: "Travel Japan", state: "已禁用", provider: "Saily", iccid: "8985201234567890123")
        let club = Profile(name: "Work US", state: "已启用", provider: "Club")

        XCTAssertEqual(ProfileFilter.apply([saily, club], query: "sail"), [saily])
        XCTAssertEqual(ProfileFilter.apply([saily, club], query: "90123"), [saily])
        XCTAssertEqual(ProfileFilter.apply([saily, club], query: "启用"), [club])
        XCTAssertEqual(ProfileFilter.apply([saily, club], query: " "), [saily, club])
    }

    func testDeviceSelectionKeyIsRemoteScoped() {
        let remoteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")

        XCTAssertEqual(DeviceSelectionStore.key(for: remoteID), "r6c.selectedDeviceSerial.11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(DeviceSelectionStore.key(for: nil), "r6c.selectedDeviceSerial")
    }

    func testStreamFrameLoaderDecodesOnlyNewFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="))
        try png.write(to: url)

        let loadedFrame = await StreamFrameLoader.load(from: url, after: nil)
        let frame = try XCTUnwrap(loadedFrame)
        XCTAssertEqual(frame.pixelSize, CGSize(width: 1, height: 1))
        let unchangedFrame = await StreamFrameLoader.load(from: url, after: frame.modified)
        XCTAssertNil(unchangedFrame)
    }

    func testStreamStalenessRestartGate() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let staleFrame = Date(timeIntervalSinceReferenceDate: 90)
        let recentRestart = Date(timeIntervalSinceReferenceDate: 95)
        let oldRestart = Date(timeIntervalSinceReferenceDate: 80)

        XCTAssertTrue(StreamStaleness.shouldRestart(
            lastFrameDate: staleFrame,
            now: now,
            lastRestart: oldRestart,
            staleAfter: 6,
            minRestartGap: 10,
            hasImage: true
        ))
        XCTAssertFalse(StreamStaleness.shouldRestart(
            lastFrameDate: staleFrame,
            now: now,
            lastRestart: recentRestart,
            staleAfter: 6,
            minRestartGap: 10,
            hasImage: true
        ))
        XCTAssertFalse(StreamStaleness.shouldRestart(
            lastFrameDate: nil,
            now: now,
            lastRestart: oldRestart,
            staleAfter: 6,
            minRestartGap: 10,
            hasImage: true
        ))
    }

    func testStreamFramePathIsScopedAndFileSafe() {
        let first = StreamFramePath.url(for: "root@example.com:22:demo123")
        let second = StreamFramePath.url(for: "root@example.com:22:other-device")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("r6c-phone-control-stream-"))
        XCTAssertFalse(first.lastPathComponent.contains(":"))
        XCTAssertFalse(first.lastPathComponent.contains("@"))
    }

    func testAnnexBStartCodeParsing() {
        let data = Data([0, 0, 1, 0x67, 0, 0, 0, 1, 0x68])

        XCTAssertEqual(AnnexBH264Parser.startCode(in: data, from: 0), 0..<3)
        XCTAssertEqual(AnnexBH264Parser.startCode(in: data, from: 3), 4..<8)
        XCTAssertNil(AnnexBH264Parser.startCode(in: data, from: 8))
    }

    func testScreenFitKeepsPortraitAndLandscapeAspect() {
        let portrait = ScreenFit.size(for: CGSize(width: 1080, height: 2340), in: CGSize(width: 600, height: 600))
        let landscape = ScreenFit.size(for: CGSize(width: 2340, height: 1080), in: CGSize(width: 600, height: 600))

        XCTAssertEqual(portrait.width, 276.92, accuracy: 0.01)
        XCTAssertEqual(portrait.height, 600, accuracy: 0.01)
        XCTAssertEqual(landscape.width, 600, accuracy: 0.01)
        XCTAssertEqual(landscape.height, 276.92, accuracy: 0.01)
    }

    func testDisplayStatusParsesPhysicalSize() {
        let size = R6CLineParser.physicalDisplaySize("""
        Physical size: 1080x2340
        Physical density: 480
        """)

        XCTAssertEqual(size, CGSize(width: 1080, height: 2340))
    }

    func testCompressedVideoCoordinatesMapToDeviceTouchCoordinates() {
        let point = ScreenCoordinateMapper.mapPoint(
            CGPoint(x: 270, y: 585),
            from: CGSize(width: 540, height: 1170),
            to: CGSize(width: 1080, height: 2340)
        )
        let landscapeSize = ScreenCoordinateMapper.touchSize(
            for: CGSize(width: 1170, height: 540),
            deviceSize: CGSize(width: 1080, height: 2340)
        )

        XCTAssertEqual(point.x, 540, accuracy: 0.01)
        XCTAssertEqual(point.y, 1170, accuracy: 0.01)
        XCTAssertEqual(landscapeSize, CGSize(width: 2340, height: 1080))
    }

    func testTrackpadHorizontalSwipeFiresOncePerGesture() {
        var accumulator = TrackpadSwipeAccumulator()

        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: 32,
                verticalDelta: 2,
                isGestureEnding: false,
                isMomentum: false,
                isDirectionInverted: false
            ),
            TrackpadSwipeDecision(direction: nil, shouldConsumeEvent: true)
        )
        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: 34,
                verticalDelta: 2,
                isGestureEnding: false,
                isMomentum: false,
                isDirectionInverted: false
            ),
            TrackpadSwipeDecision(direction: .left, shouldConsumeEvent: true)
        )
        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: 90,
                verticalDelta: 1,
                isGestureEnding: false,
                isMomentum: false,
                isDirectionInverted: false
            ),
            TrackpadSwipeDecision(direction: nil, shouldConsumeEvent: true)
        )

        _ = accumulator.observe(
            horizontalDelta: 0,
            verticalDelta: 0,
            isGestureEnding: true,
            isMomentum: false,
            isDirectionInverted: false
        )
        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: -64,
                verticalDelta: 0,
                isGestureEnding: false,
                isMomentum: false,
                isDirectionInverted: false
            ),
            TrackpadSwipeDecision(direction: .right, shouldConsumeEvent: true)
        )
    }

    func testTrackpadHorizontalSwipeIgnoresVerticalAndMomentum() {
        var accumulator = TrackpadSwipeAccumulator()

        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: 20,
                verticalDelta: 90,
                isGestureEnding: false,
                isMomentum: false,
                isDirectionInverted: false
            ),
            TrackpadSwipeDecision(direction: nil, shouldConsumeEvent: false)
        )
        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: 100,
                verticalDelta: 0,
                isGestureEnding: false,
                isMomentum: true,
                isDirectionInverted: false
            ),
            TrackpadSwipeDecision(direction: nil, shouldConsumeEvent: true)
        )
    }

    func testTrackpadHorizontalSwipeUsesObservedNaturalTrackpadDirection() {
        var accumulator = TrackpadSwipeAccumulator()

        XCTAssertEqual(
            accumulator.observe(
                horizontalDelta: 64,
                verticalDelta: 0,
                isGestureEnding: false,
                isMomentum: false,
                isDirectionInverted: true
            ),
            TrackpadSwipeDecision(direction: .right, shouldConsumeEvent: true)
        )
    }

    func testScrcpyTouchMessageMatchesControlProtocolShape() {
        let data = ScrcpyControlMessage.touch(action: .move, x: 12, y: 34, screenSize: CGSize(width: 1080, height: 2340))

        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(Array(data.prefix(2)), [2, 2])
        XCTAssertEqual(Array(data[2..<10]), [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe])
        XCTAssertEqual(Array(data[10..<22]), [0, 0, 0, 12, 0, 0, 0, 34, 4, 56, 9, 36])
        XCTAssertEqual(Array(data[22..<24]), [0xff, 0xff])
        XCTAssertEqual(Array(data[24..<32]), Array(repeating: 0, count: 8))
    }

    func testEmbeddedControlBridgeRoutesMatchingIdentityOnly() {
        let bridge = ScrcpyEmbeddedControlBridge()
        let pipe = Pipe()
        let token = UUID()

        bridge.register(input: pipe.fileHandleForWriting, identity: "remote:device", token: token)

        XCTAssertFalse(bridge.send(Data([0xaa]), identity: "other:device"))
        XCTAssertTrue(bridge.send(Data([0x02, 0x03]), identity: "remote:device"))

        bridge.unregister(token: token)
        let received = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(Array(received), [0x02, 0x03])
    }

    func testParsesStatusFields() {
        let fields = R6CLineParser.statusFields("""
        adb=connected
        adb_detail=demo123 device
        scrcpy=stopped
        ignored line
        """)

        XCTAssertEqual(fields["adb"], "connected")
        XCTAssertEqual(fields["adb_detail"], "demo123 device")
        XCTAssertEqual(fields["scrcpy"], "stopped")
        XCTAssertNil(fields["ignored line"])
    }

    func testRemoteDraftValidation() {
        XCTAssertNil(RemoteDraftValidator.error(host: "203.0.113.10", port: "22"))
        XCTAssertNil(RemoteDraftValidator.error(host: "root@example.com", port: "22"))
        XCTAssertEqual(RemoteDraftValidator.error(host: "", port: "68"), "Enter a host.")
        XCTAssertEqual(RemoteDraftValidator.error(host: "203.0.113.10", port: "0"), "Port must be 1-65535.")
        XCTAssertEqual(RemoteDraftValidator.error(host: "203.0.113.10", port: "abc"), "Port must be 1-65535.")
    }

    func testParsesDJIIG830LiveStatus() {
        let snapshot = DJIATResponseParser.snapshot(from: """
        @@BEGIN IDENTITY
        ATI
        Baiwang
        QDC507
        Revision: QDC507GLEFM21
        OK
        @@END IDENTITY
        @@BEGIN SIM_PIN
        +CME ERROR: 10
        @@END SIM_PIN
        @@BEGIN SIM_STATE
        +QSIMSTAT: 0,0
        OK
        @@END SIM_STATE
        @@BEGIN OPERATOR
        +COPS: 0
        OK
        @@END OPERATOR
        @@BEGIN EPS_REGISTRATION
        +CEREG: 0,2
        OK
        @@END EPS_REGISTRATION
        @@BEGIN SIGNAL
        +CSQ: 27,99
        OK
        @@END SIGNAL
        @@BEGIN NETWORK_INFO
        +QNWINFO: "FDD LTE","46000","LTE BAND 3",1300
        OK
        @@END NETWORK_INFO
        @@BEGIN SERVING_CELL
        +QENG: "servingcell","LIMSRV","LTE","FDD",460,00,C558C84,251,1300,3,5,5,2835,-96,-18,-58,-5,23
        OK
        @@END SERVING_CELL
        @@BEGIN USB_MODE
        +QCFG: "usbnet",0
        OK
        @@END USB_MODE
        """)

        XCTAssertTrue(snapshot.isConnected)
        XCTAssertEqual(snapshot.manufacturer, "Baiwang")
        XCTAssertEqual(snapshot.model, "QDC507")
        XCTAssertEqual(snapshot.firmware, "QDC507GLEFM21")
        XCTAssertEqual(snapshot.simState, .missing)
        XCTAssertEqual(snapshot.registration, .searching)
        XCTAssertEqual(snapshot.radioAccessTechnology, "LTE")
        XCTAssertEqual(snapshot.duplexMode, "FDD")
        XCTAssertEqual(snapshot.mccMnc, "460-00")
        XCTAssertEqual(snapshot.cellID, "C558C84")
        XCTAssertEqual(snapshot.pci, 251)
        XCTAssertEqual(snapshot.earfcn, 1300)
        XCTAssertEqual(snapshot.band, "B3")
        XCTAssertEqual(snapshot.tac, "2835")
        XCTAssertEqual(snapshot.rsrp, -96)
        XCTAssertEqual(snapshot.rsrq, -18)
        XCTAssertEqual(snapshot.rssi, -58)
        XCTAssertEqual(snapshot.sinr, -5)
        XCTAssertEqual(snapshot.csq, 27)
        XCTAssertEqual(snapshot.usbMode, "RmNet")
        XCTAssertEqual(snapshot.usbModeCode, 0)
    }

    func testDJIStatusMasksICCIDAndParsesOperator() {
        let output = """
        @@BEGIN ICCID
        +QCCID: 89852342022508685731
        OK
        @@END ICCID
        @@BEGIN SIM_PIN
        +CPIN: READY
        OK
        @@END SIM_PIN
        @@BEGIN SIM_STATE
        +QSIMSTAT: 0,1
        OK
        @@END SIM_STATE
        @@BEGIN OPERATOR
        +COPS: 0,0,"CMCC",7
        OK
        @@END OPERATOR
        @@BEGIN EPS_REGISTRATION
        +CEREG: 0,5
        OK
        @@END EPS_REGISTRATION
        """
        let snapshot = DJIATResponseParser.snapshot(from: output)

        XCTAssertEqual(snapshot.simState, .ready)
        XCTAssertEqual(snapshot.maskedICCID, "898523...685731")
        XCTAssertEqual(DJIATResponseParser.iccid(from: output), "89852342022508685731")
        XCTAssertEqual(snapshot.operatorName, "CMCC")
        XCTAssertEqual(snapshot.registration, .roaming)
    }

    func testDJIICCIDParserRejectsMalformedResponses() {
        XCTAssertNil(DJIATResponseParser.iccid(from: """
        @@BEGIN ICCID
        +QCCID: unavailable
        OK
        @@END ICCID
        """))
    }

    func testDJIICCIDParserStripsBCDPaddingNibble() {
        let output = """
        @@BEGIN ICCID
        +QCCID: 8985207220082439520F
        OK
        @@END ICCID
        """

        XCTAssertEqual(DJIATResponseParser.iccid(from: output), "8985207220082439520")
        XCTAssertEqual(DJIATResponseParser.snapshot(from: output).maskedICCID, "898520...439520")
    }

    func testDJIStatusIndicatorMatchesDocumentedStates() {
        var snapshot = DJI4GSnapshot()
        snapshot.isConnected = true

        snapshot.simState = .missing
        XCTAssertEqual(snapshot.statusIndicator, DJIStatusIndicator(color: .red, behavior: .steady))

        snapshot.simState = .ready
        snapshot.registration = .searching
        XCTAssertEqual(snapshot.statusIndicator, DJIStatusIndicator(color: .red, behavior: .flashing))

        snapshot.registration = .home
        snapshot.radioAccessTechnology = "LTE"
        snapshot.rsrp = -82
        XCTAssertEqual(snapshot.statusIndicator, DJIStatusIndicator(color: .green, behavior: .steady))

        snapshot.rsrp = -98
        XCTAssertEqual(snapshot.statusIndicator, DJIStatusIndicator(color: .green, behavior: .flashing))

        snapshot.radioAccessTechnology = "UMTS"
        snapshot.rsrp = -82
        XCTAssertEqual(snapshot.statusIndicator, DJIStatusIndicator(color: .blue, behavior: .steady))

        snapshot.isConnected = false
        XCTAssertEqual(snapshot.statusIndicator, .off)
    }

    func testDJILPACParserMapsProfilesWithoutExposingDriverEnvelope() {
        let profiles = DJILPACResponseParser.profiles(from: """
        {"type":"lpa","payload":{"code":0,"message":"success","data":[
          {"iccid":"8985200014631312207","profileState":"disabled","profileNickname":null,"serviceProviderName":"Club","profileName":"Club"},
          {"iccid":"89852351225047364845","isdpAid":"a0000005591010ffffffff8900001200","profileState":"enabled","profileNickname":"Travel","serviceProviderName":"Saily","profileName":"WEBBING"}
        ]}}
        """)

        XCTAssertEqual(profiles.map(\.name), ["Club", "WEBBING"])
        XCTAssertEqual(profiles.map(\.displayName), ["Club", "Travel"])
        XCTAssertEqual(profiles[1].nickname, "Travel")
        XCTAssertEqual(profiles.map(\.provider), ["Club", "Saily"])
        XCTAssertEqual(profiles[1].isdpAid, "a0000005591010ffffffff8900001200")
        XCTAssertFalse(profiles[0].isEnabled)
        XCTAssertTrue(profiles[1].isEnabled)
    }

    func testDJILPACParserReadsCommandResult() {
        let result = DJILPACResponseParser.result(from: """
        {"type":"lpa","payload":{"code":0,"message":"success","data":{}}}
        """)

        XCTAssertEqual(result?.code, 0)
        XCTAssertEqual(result?.message, "success")
    }

    func testDJILPACParserFallsBackWhenNicknameIsEmpty() {
        let profiles = DJILPACResponseParser.profiles(from: """
        {"type":"lpa","payload":{"code":0,"message":"success","data":[
          {"iccid":"1","profileState":"enabled","profileNickname":"  ","serviceProviderName":"Demo","profileName":"Original"}
        ]}}
        """)

        XCTAssertEqual(profiles.first?.name, "Original")
        XCTAssertEqual(profiles.first?.displayName, "Original")
        XCTAssertNil(profiles.first?.nickname)
    }

    func testParsesDJIDataVoiceAndLEDState() {
        let snapshot = DJIATResponseParser.snapshot(from: """
        @@BEGIN PDP_ADDRESS
        +CGPADDR: 1,"10.49.17.199"
        OK
        @@END PDP_ADDRESS
        @@BEGIN WWAN_STATUS
        +QLWWANSTATUS: 1,"10.49.17.199","0000:0000:0000:0000:0000:0000:0000:0000"
        OK
        @@END WWAN_STATUS
        @@BEGIN NETDEV_STATUS
        +QNETDEVSTATUS: 0,2,4,1
        OK
        @@END NETDEV_STATUS
        @@BEGIN IMS_CONFIG
        +QCFG: "ims",0,0
        OK
        @@END IMS_CONFIG
        @@BEGIN VOLTE_CONFIG
        +QCFG: "volte/disable",0
        OK
        @@END VOLTE_CONFIG
        @@BEGIN CALL_CONTROL
        +QCFG: "call_control",0,0
        OK
        @@END CALL_CONTROL
        @@BEGIN PHONE_NUMBER
        AT+CNUM
        OK
        @@END PHONE_NUMBER
        @@BEGIN LED_MODE
        +QCFG: "ledmode",0
        OK
        @@END LED_MODE
        @@BEGIN USB_MODE
        +QCFG: "usbnet",1
        OK
        @@END USB_MODE
        """)

        XCTAssertEqual(snapshot.pdpAddress, "10.49.17.199")
        XCTAssertTrue(snapshot.hasDataSession)
        XCTAssertEqual(snapshot.usbNetworkState, "Connected")
        XCTAssertEqual(snapshot.imsState, "Disabled")
        XCTAssertEqual(snapshot.volteState, "Enabled")
        XCTAssertEqual(snapshot.callControlState, "0 · 0")
        XCTAssertNil(snapshot.phoneNumber)
        XCTAssertEqual(snapshot.ledMode, "Firmware mode 0")
        XCTAssertEqual(snapshot.usbMode, "ECM")
        XCTAssertEqual(snapshot.usbModeCode, 1)
        XCTAssertFalse(snapshot.voiceReady)
    }

    func testDJIDataSessionRequiresANonzeroPDPAddress() {
        let snapshot = DJIATResponseParser.snapshot(from: """
        @@BEGIN PDP_ADDRESS
        +CGPADDR: 1,"10.196.137.114"
        OK
        @@END PDP_ADDRESS
        @@BEGIN WWAN_STATUS
        +QLWWANSTATUS: 1,"0.0.0.0","0000:0000:0000:0000:0000:0000:0000:0000"
        OK
        @@END WWAN_STATUS
        @@BEGIN NETDEV_STATUS
        +QNETDEVSTATUS: 0,2,4,1
        OK
        @@END NETDEV_STATUS
        """)

        XCTAssertEqual(snapshot.usbNetworkState, "Connected")
        XCTAssertFalse(snapshot.hasDataSession)
    }

    func testServingCellDoesNotEraseRoamingRegistration() {
        let snapshot = DJIATResponseParser.snapshot(from: """
        @@BEGIN EPS_REGISTRATION
        +CEREG: 0,5
        OK
        @@END EPS_REGISTRATION
        @@BEGIN SERVING_CELL
        +QENG: "servingcell","NOCONN","LTE","FDD",460,01,7A51F30,213,1850,3,5,5,7A44,-82,-4,-51,3,39
        OK
        @@END SERVING_CELL
        """)

        XCTAssertEqual(snapshot.registration, .roaming)
    }

    func testDJIRawCommandRequiresModemOK() {
        XCTAssertTrue(DJIATResponseParser.commandSucceeded("""
        @@BEGIN RAW
        AT+QCFG="usbnet",1
        OK
        @@END RAW
        """))
        XCTAssertFalse(DJIATResponseParser.commandSucceeded("""
        @@BEGIN RAW
        AT+QCFG="usbnet",1
        ERROR
        @@END RAW
        """))
    }

    func testParsesDJIHostNetworkState() {
        let snapshot = DJIHostNetworkParser.snapshot(
            hardwarePorts: """
            Hardware Port: Wi-Fi
            Device: en0
            Hardware Port: Baiwang
            Device: en12
            """,
            networkInfo: """
            DHCP Configuration
            IP address: 192.168.225.23
            Router: 192.168.225.1
            """,
            dnsInfo: "1.1.1.1\n8.8.8.8\n"
        )

        XCTAssertEqual(snapshot.interfaceName, "en12")
        XCTAssertEqual(snapshot.ipv4Address, "192.168.225.23")
        XCTAssertEqual(snapshot.router, "192.168.225.1")
        XCTAssertEqual(snapshot.dnsServers, ["1.1.1.1", "8.8.8.8"])
        XCTAssertTrue(snapshot.isReady)
    }

    func testParsesDJINeighborCells() {
        let neighbors = DJIATResponseParser.neighborCells(from: """
        @@BEGIN NEIGHBOR_CELLS
        +QENG: "neighbourcell intra","LTE",1300,153,-12,-103,-72,4,0,21,8
        +QENG: "neighbourcell inter","LTE",1650,42,-15,-111,-80,-3,0,14,4
        OK
        @@END NEIGHBOR_CELLS
        """)

        XCTAssertEqual(neighbors.count, 2)
        XCTAssertEqual(neighbors[0].kind, "intra")
        XCTAssertEqual(neighbors[0].earfcn, 1300)
        XCTAssertEqual(neighbors[0].pci, 153)
        XCTAssertEqual(neighbors[0].rsrp, -103)
        XCTAssertEqual(neighbors[1].kind, "inter")
    }
}
