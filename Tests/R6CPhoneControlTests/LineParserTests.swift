import XCTest
@testable import R6CPhoneControl

final class LineParserTests: XCTestCase {
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

    func testMarksUnauthorizedDevicesAsNotReady() {
        let devices = R6CLineParser.devices(#"DEVICE serial="bad" state="unauthorized" model="" product="" device="""#)

        XCTAssertEqual(devices.count, 1)
        XCTAssertFalse(devices[0].isReady)
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
}
