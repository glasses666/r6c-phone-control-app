import AppKit
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ImageIO
import SwiftUI

struct Profile: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let state: String
    let provider: String
    let iccid: String

    init(name: String, state: String, provider: String, iccid: String = "") {
        self.name = name
        self.state = state
        self.provider = provider
        self.iccid = iccid
    }

    var isEnabled: Bool {
        state.localizedCaseInsensitiveContains("enabled") || state.contains("已启用")
    }

    var title: String {
        provider.isEmpty ? name : "\(name) / \(provider)"
    }

    var switchArguments: [String] {
        if !iccid.isEmpty {
            return ["switch-iccid", iccid]
        }
        return ["switch-exact", name, provider]
    }

    var identityKey: String {
        if !iccid.isEmpty {
            return "iccid:\(iccid)"
        }
        return "\(name)\t\(provider)"
    }

    var detail: String {
        let base = provider.isEmpty ? state : "\(provider) - \(state)"
        guard !iccid.isEmpty else { return base }
        return "\(base) - ICCID \(maskedICCID)"
    }

    private var maskedICCID: String {
        guard iccid.count > 6 else { return iccid }
        return "..." + iccid.suffix(6)
    }

    static func ambiguousIdentityKeys(in profiles: [Profile]) -> Set<String> {
        var counts: [String: Int] = [:]
        for profile in profiles {
            counts[profile.identityKey, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }
}

struct CommandResult {
    let exitCode: Int32
    let output: String
}

struct RemoteConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var sshHost: String
    var sshPort: String

    static let defaultR6C = RemoteConfig(name: "Add remote", sshHost: "", sshPort: "22")
}

enum RemoteDraftValidator {
    static func error(host: String, port: String) -> String? {
        let hostText = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostText.isEmpty else { return "Enter a host." }
        guard let portNumber = Int(portText), (1...65_535).contains(portNumber) else {
            return "Port must be 1-65535."
        }
        return nil
    }
}

struct AndroidDevice: Identifiable, Equatable {
    let serial: String
    let state: String
    let model: String
    let product: String
    let device: String

    var id: String { serial }
    var title: String { model.isEmpty ? serial : "\(model) (\(serial))" }
    var isReady: Bool { state == "device" }
}

enum ProfileFilter {
    static func apply(_ profiles: [Profile], query: String) -> [Profile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.provider.localizedCaseInsensitiveContains(query) ||
                $0.state.localizedCaseInsensitiveContains(query) ||
                $0.iccid.localizedCaseInsensitiveContains(query)
        }
    }
}

enum DeviceSelectionStore {
    static let legacyKey = "r6c.selectedDeviceSerial"

    static func key(for remoteID: UUID?) -> String {
        guard let remoteID else { return legacyKey }
        return "\(legacyKey).\(remoteID.uuidString)"
    }
}

struct DockFrame: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var arguments: [String] {
        [String(x), String(y), String(width), String(height)]
    }
}

struct StreamFrame {
    let modified: Date
    let cgImage: CGImage
    let pixelSize: CGSize
}

enum StreamFrameLoader {
    static func load(from url: URL, after lastFrameDate: Date?) async -> StreamFrame? {
        await Task.detached(priority: .userInitiated) {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                modified != lastFrameDate,
                let data = try? Data(contentsOf: url),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: true
                ] as CFDictionary)
            else { return nil }

            return StreamFrame(
                modified: modified,
                cgImage: image,
                pixelSize: CGSize(width: image.width, height: image.height)
            )
        }.value
    }
}

enum StreamStaleness {
    static func shouldRestart(
        lastFrameDate: Date?,
        now: Date,
        lastRestart: Date,
        staleAfter: TimeInterval,
        minRestartGap: TimeInterval,
        hasImage: Bool
    ) -> Bool {
        guard hasImage, let lastFrameDate else { return false }
        return now.timeIntervalSince(lastFrameDate) >= staleAfter &&
            now.timeIntervalSince(lastRestart) >= minRestartGap
    }
}

enum StreamFramePath {
    static func url(for identity: String) -> URL {
        let key = Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r6c-phone-control-stream-\(key.isEmpty ? "default" : key).jpg")
    }
}

enum ScreenFit {
    static func size(for pixels: CGSize, in bounds: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let aspect = pixels.width / pixels.height
        var width = bounds.width
        var height = width / aspect
        if height > bounds.height {
            height = bounds.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }
}

enum TrackpadSwipeDirection: Equatable {
    case left
    case right
}

struct TrackpadSwipeDecision: Equatable {
    let direction: TrackpadSwipeDirection?
    let shouldConsumeEvent: Bool
}

struct TrackpadSwipeAccumulator {
    var threshold: CGFloat = 60
    var axisRatio: CGFloat = 1.15
    var minHorizontalDelta: CGFloat = 0.5

    private var accumulatedX: CGFloat = 0
    private var hasFired = false
    private var isTrackingHorizontal = false

    mutating func observe(
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        isGestureEnding: Bool,
        isMomentum: Bool,
        isDirectionInverted: Bool
    ) -> TrackpadSwipeDecision {
        let absX = abs(horizontalDelta)
        let absY = abs(verticalDelta)
        let isHorizontal = absX >= minHorizontalDelta && absX > absY * axisRatio

        defer {
            if isGestureEnding {
                reset()
            }
        }

        if isMomentum {
            return TrackpadSwipeDecision(
                direction: nil,
                shouldConsumeEvent: isTrackingHorizontal || isHorizontal
            )
        }

        guard isHorizontal || isTrackingHorizontal else {
            return TrackpadSwipeDecision(direction: nil, shouldConsumeEvent: false)
        }

        if isHorizontal {
            isTrackingHorizontal = true
            let physicalDelta = isDirectionInverted ? horizontalDelta : -horizontalDelta
            accumulatedX += physicalDelta
        }

        guard !hasFired, abs(accumulatedX) >= threshold else {
            return TrackpadSwipeDecision(direction: nil, shouldConsumeEvent: true)
        }

        hasFired = true
        return TrackpadSwipeDecision(
            direction: accumulatedX < 0 ? .left : .right,
            shouldConsumeEvent: true
        )
    }

    mutating func reset() {
        accumulatedX = 0
        hasFired = false
        isTrackingHorizontal = false
    }
}

struct H264StreamConfiguration: Equatable {
    let identity: String
    let helperPath: String
    let environment: [String: String]
}

final class ScrcpyEmbeddedControlBridge: @unchecked Sendable {
    static let shared = ScrcpyEmbeddedControlBridge()

    private let lock = NSLock()
    private var input: FileHandle?
    private var identity = ""
    private var token: UUID?

    func register(input: FileHandle, identity: String, token: UUID) {
        lock.lock()
        self.input = input
        self.identity = identity
        self.token = token
        lock.unlock()
    }

    func unregister(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.token == token else { return }
        try? input?.close()
        input = nil
        identity = ""
        self.token = nil
    }

    func send(_ data: Data, identity: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.identity == identity, let input else { return false }
        do {
            try input.write(contentsOf: data)
            return true
        } catch {
            self.input = nil
            self.identity = ""
            token = nil
            return false
        }
    }
}

struct NativeH264StreamView: NSViewRepresentable {
    let configuration: H264StreamConfiguration
    let onStatus: (String) -> Void
    let onSize: (CGSize) -> Void

    func makeNSView(context: Context) -> H264StreamPlayerView {
        let view = H264StreamPlayerView()
        view.onStatus = onStatus
        view.onSize = onSize
        view.configure(configuration)
        return view
    }

    func updateNSView(_ nsView: H264StreamPlayerView, context: Context) {
        nsView.onStatus = onStatus
        nsView.onSize = onSize
        nsView.configure(configuration)
    }

    static func dismantleNSView(_ nsView: H264StreamPlayerView, coordinator: ()) {
        nsView.stop()
    }
}

final class H264StreamPlayerView: NSView {
    var onStatus: (String) -> Void = { _ in }
    var onSize: (CGSize) -> Void = { _ in }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let controlToken = UUID()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var configuration: H264StreamConfiguration?
    private var stoppingProcess: Process?
    private lazy var parser = AnnexBH264Parser(
        onSample: { [weak self] sampleBuffer in self?.enqueue(sampleBuffer) },
        onVideoSize: { [weak self] size in
            DispatchQueue.main.async {
                self?.onSize(size)
                self?.onStatus("scrcpy h264")
            }
        }
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func configure(_ configuration: H264StreamConfiguration) {
        guard configuration != self.configuration else { return }
        stop()
        self.configuration = configuration
        start()
    }

    func stop() {
        ScrcpyEmbeddedControlBridge.shared.unregister(token: controlToken)
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        if let activeProcess = process, activeProcess.isRunning {
            stoppingProcess = activeProcess
            activeProcess.terminate()
        }
        process = nil
        displayLayer.flushAndRemoveImage()
        parser.reset()
    }

    private func start() {
        guard let configuration else { return }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [configuration.helperPath, "scrcpy-embedded-stream"]
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.parser.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { _ in _ = stderr.fileHandleForReading.availableData }

        process.terminationHandler = { [weak self] finishedProcess in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stoppingProcess === finishedProcess {
                    self.stoppingProcess = nil
                    return
                }
                guard self.process === finishedProcess else { return }
                self.process = nil
                self.onStatus("scrcpy stopped")
            }
        }

        do {
            try process.run()
            self.process = process
            stdinPipe = stdin
            stdoutPipe = stdout
            stderrPipe = stderr
            ScrcpyEmbeddedControlBridge.shared.register(
                input: stdin.fileHandleForWriting,
                identity: configuration.identity,
                token: controlToken
            )
            onStatus("scrcpy starting")
        } catch {
            onStatus("scrcpy failed")
        }
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
                onStatus("scrcpy h264")
            }
        }
    }
}

final class AnnexBH264Parser {
    private var buffer = Data()
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private let onSample: (CMSampleBuffer) -> Void
    private let onVideoSize: (CGSize) -> Void

    init(onSample: @escaping (CMSampleBuffer) -> Void, onVideoSize: @escaping (CGSize) -> Void) {
        self.onSample = onSample
        self.onVideoSize = onVideoSize
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        sps = nil
        pps = nil
        formatDescription = nil
    }

    func append(_ data: Data) {
        buffer.append(data)
        consumeNALUnits()
    }

    private func consumeNALUnits() {
        while true {
            guard let first = Self.startCode(in: buffer, from: 0) else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            if first.lowerBound > 0 {
                buffer.removeSubrange(0..<first.lowerBound)
            }
            guard let next = Self.startCode(in: buffer, from: first.count) else {
                return
            }

            let nalStart = first.count
            let nalEnd = next.lowerBound
            if nalEnd > nalStart {
                handleNAL(Data(buffer[nalStart..<nalEnd]))
            }
            buffer.removeSubrange(0..<next.lowerBound)
        }
    }

    private func handleNAL(_ nal: Data) {
        guard let firstByte = nal.first else { return }
        switch firstByte & 0x1f {
        case 7:
            sps = nal
            updateFormatDescription()
        case 8:
            pps = nal
            updateFormatDescription()
        case 1, 5:
            if let sample = makeSampleBuffer(from: nal) {
                onSample(sample)
            }
        default:
            break
        }
    }

    private func updateFormatDescription() {
        guard let sps, let pps else { return }
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard
                    let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                    let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress
                else { return OSStatus(-1) }

                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return }
        formatDescription = description
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        onVideoSize(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }

    private func makeSampleBuffer(from nal: Data) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var length = UInt32(nal.count).bigEndian
        var sampleData = Data(bytes: &length, count: 4)
        sampleData.append(nal)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = sampleData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    static func startCode(in data: Data, from start: Int) -> Range<Int>? {
        guard data.count >= 4, start < data.count - 3 else { return nil }
        var i = start
        while i < data.count - 3 {
            if data[i] == 0, data[i + 1] == 0 {
                if data[i + 2] == 1 {
                    return i..<(i + 3)
                }
                if data[i + 2] == 0, data[i + 3] == 1 {
                    return i..<(i + 4)
                }
            }
            i += 1
        }
        return nil
    }
}

enum R6CLineParser {
    static func statusFields(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }
        return fields
    }

    static func profiles(_ output: String) -> [Profile] {
        output.split(separator: "\n").compactMap { rawLine -> Profile? in
            let line = String(rawLine)
            guard line.hasPrefix("PROFILE ") else { return nil }
            return Profile(
                name: extract("name", from: line),
                state: extract("state", from: line),
                provider: extract("provider", from: line),
                iccid: extract("iccid", from: line)
            )
        }
    }

    static func devices(_ output: String) -> [AndroidDevice] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.hasPrefix("DEVICE ") else { return nil }
            return AndroidDevice(
                serial: extract("serial", from: line),
                state: extract("state", from: line),
                model: extract("model", from: line),
                product: extract("product", from: line),
                device: extract("device", from: line)
            )
        }
    }

    private static func extract(_ key: String, from line: String) -> String {
        let marker = "\(key)=\""
        guard let start = line.range(of: marker) else { return "" }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return String(rest) }
        return String(rest[..<end])
    }
}

enum CommandRunner {
    @discardableResult
    static func runSync(helper: String, arguments: [String], environment: [String: String], timeout: TimeInterval = 8) -> CommandResult {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: 127, output: "ERROR failed to run helper: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(300_000)
            if process.isRunning {
                process.interrupt()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: Date() >= deadline && process.terminationStatus != 0 ? 124 : process.terminationStatus,
            output: (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func run(helper: String, arguments: [String], environment: [String: String]) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return CommandResult(exitCode: 127, output: "ERROR failed to run helper: \(error.localizedDescription)")
            }

            let deadline = Date().addingTimeInterval(260)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                usleep(400_000)
                if process.isRunning {
                    process.interrupt()
                }
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if Date() >= deadline && process.terminationStatus != 0 {
                return CommandResult(
                    exitCode: 124,
                    output: "ERROR helper timed out after 260 seconds\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            return CommandResult(exitCode: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}

@MainActor
final class ScrcpyControlStream {
    private var process: Process?
    private var input: FileHandle?
    private var identity = ""

    func send(action: ScrcpyTouchAction, x: Int, y: Int, screenSize: CGSize, helper: String, environment: [String: String], identity: String) {
        let data = ScrcpyControlMessage.touch(action: action, x: x, y: y, screenSize: screenSize)
        if ScrcpyEmbeddedControlBridge.shared.send(data, identity: identity) {
            stop()
            return
        }

        if process?.isRunning != true || self.identity != identity {
            stop()
            start(helper: helper, environment: environment, identity: identity)
        }
        guard let input else { return }
        try? input.write(contentsOf: data)
    }

    func stop() {
        if let input {
            try? input.close()
        }
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        input = nil
        identity = ""
    }

    private func start(helper: String, environment: [String: String], identity: String) {
        let process = Process()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper, "scrcpy-control-stream"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = inputPipe
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
        } catch {
            return
        }

        self.process = process
        input = inputPipe.fileHandleForWriting
        self.identity = identity
    }
}

enum ScrcpyTouchAction {
    case down
    case up
    case move
    case cancel

    var motionEventCode: UInt8 {
        switch self {
        case .down: 0
        case .up: 1
        case .move: 2
        case .cancel: 3
        }
    }

    var pressure: UInt16 {
        switch self {
        case .up, .cancel: 0
        case .down, .move: 0xffff
        }
    }
}

enum ScrcpyControlMessage {
    private static let injectTouchEvent: UInt8 = 2
    private static let genericFingerPointerID = UInt64(bitPattern: Int64(-2))

    static func touch(action: ScrcpyTouchAction, x: Int, y: Int, screenSize: CGSize) -> Data {
        var data = Data()
        data.appendUInt8(injectTouchEvent)
        data.appendUInt8(action.motionEventCode)
        data.appendUInt64BE(genericFingerPointerID)
        data.appendInt32BE(Int32(clamping: x))
        data.appendInt32BE(Int32(clamping: y))
        data.appendUInt16BE(UInt16(clamping: Int(screenSize.width.rounded())))
        data.appendUInt16BE(UInt16(clamping: Int(screenSize.height.rounded())))
        data.appendUInt16BE(action.pressure)
        data.appendUInt32BE(0)
        data.appendUInt32BE(0)
        return data
    }
}

extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32((value >> 32) & 0xffff_ffff))
        appendUInt32BE(UInt32(value & 0xffff_ffff))
    }

    mutating func appendInt32BE(_ value: Int32) {
        appendUInt32BE(UInt32(bitPattern: value))
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var adbState = "checking"
    @Published var adbDetail = ""
    @Published var scrcpyState = "checking"
    @Published var screenState = "checking"
    @Published var webState = "checking"
    @Published var profiles: [Profile] = []
    @Published var remotes: [RemoteConfig] = []
    @Published var selectedRemoteID: UUID?
    @Published var devices: [AndroidDevice] = []
    @Published var selectedDeviceSerial = ""
    @Published var newRemoteName = ""
    @Published var newRemoteHost = ""
    @Published var newRemotePort = "22"
    @Published var profileSearch = ""
    @Published var log = "Ready."
    @Published var isBusy = false
    @Published var lastUpdated = Date()

    private let helperPath: String
    private var statusInFlight = false
    private var profilesInFlight = false
    private var devicesInFlight = false
    private let scrcpyControlStream = ScrcpyControlStream()
    private let defaults = UserDefaults.standard

    init() {
        if let bundled = Bundle.main.path(forResource: "r6c-phone-control", ofType: "sh") {
            helperPath = bundled
        } else {
            helperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Scripts/r6c-phone-control.sh")
                .path
        }

        if
            let data = defaults.data(forKey: "r6c.remotes"),
            let decoded = try? JSONDecoder().decode([RemoteConfig].self, from: data),
            !decoded.isEmpty
        {
            remotes = decoded
        } else {
            remotes = [.defaultR6C]
        }

        if
            let saved = defaults.string(forKey: "r6c.selectedRemoteID"),
            let id = UUID(uuidString: saved),
            remotes.contains(where: { $0.id == id })
        {
            selectedRemoteID = id
        } else {
            selectedRemoteID = remotes.first?.id
        }
        selectedDeviceSerial = savedSelectedDeviceSerial(allowLegacy: true)
    }

    var adbIsConnected: Bool { adbState == "connected" }
    var scrcpyIsRunning: Bool { scrcpyState == "running" }
    var selectedRemote: RemoteConfig {
        remotes.first(where: { $0.id == selectedRemoteID }) ?? remotes[0]
    }
    var remoteDraftError: String? {
        RemoteDraftValidator.error(host: newRemoteHost, port: newRemotePort)
    }
    var ambiguousProfileKeys: Set<String> {
        Profile.ambiguousIdentityKeys(in: profiles)
    }
    var filteredProfiles: [Profile] {
        ProfileFilter.apply(profiles, query: profileSearch)
    }
    var screenStreamID: String {
        "\(selectedRemote.sshHost):\(selectedRemote.sshPort):\(selectedDeviceSerial)"
    }
    var h264StreamConfiguration: H264StreamConfiguration {
        H264StreamConfiguration(identity: screenStreamID, helperPath: helperPath, environment: commandEnvironment)
    }

    func refreshAll() {
        Task {
            await refreshDevices()
            await refreshStatus()
            await refreshProfiles()
        }
    }

    func selectRemote(_ remote: RemoteConfig) {
        scrcpyControlStream.stop()
        selectedRemoteID = remote.id
        selectedDeviceSerial = savedSelectedDeviceSerial(allowLegacy: false)
        defaults.set(remote.id.uuidString, forKey: "r6c.selectedRemoteID")
        devices = []
        profiles = []
        refreshAll()
    }

    func selectDevice(_ device: AndroidDevice) {
        guard device.serial != selectedDeviceSerial else { return }
        scrcpyControlStream.stop()
        selectedDeviceSerial = device.serial
        defaults.set(device.serial, forKey: selectedDeviceKey)
        profiles = []
        Task {
            await stopAllInputRelays()
            await refreshStatus()
            await refreshProfiles()
        }
    }

    func addRemote() {
        let hostText = newRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = newRemotePort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteDraftValidator.error(host: hostText, port: portText) == nil else { return }
        let host = hostText.contains("@") ? hostText : "root@\(hostText)"
        let remote = RemoteConfig(
            name: newRemoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? hostText : newRemoteName,
            sshHost: host,
            sshPort: portText
        )
        remotes.append(remote)
        persistRemotes()
        newRemoteName = ""
        newRemoteHost = ""
        newRemotePort = "22"
        selectRemote(remote)
    }

    func removeSelectedRemote() {
        guard remotes.count > 1, let selectedRemoteID else { return }
        remotes.removeAll { $0.id == selectedRemoteID }
        defaults.removeObject(forKey: DeviceSelectionStore.key(for: selectedRemoteID))
        persistRemotes()
        self.selectedRemoteID = remotes.first?.id
        selectedDeviceSerial = savedSelectedDeviceSerial(allowLegacy: false)
        devices = []
        profiles = []
        defaults.set(self.selectedRemoteID?.uuidString, forKey: "r6c.selectedRemoteID")
        refreshAll()
    }

    func refreshDevices() async {
        guard !devicesInFlight else { return }
        devicesInFlight = true
        defer { devicesInFlight = false }

        let result = await run(["devices"], busy: false)
        if result.exitCode == 0 {
            devices = parseDevices(result.output)
            let readyDevices = devices.filter(\.isReady)
            if selectedDeviceSerial.isEmpty || !readyDevices.contains(where: { $0.serial == selectedDeviceSerial }) {
                selectedDeviceSerial = readyDevices.first?.serial ?? ""
                if selectedDeviceSerial.isEmpty {
                    defaults.removeObject(forKey: selectedDeviceKey)
                } else {
                    defaults.set(selectedDeviceSerial, forKey: selectedDeviceKey)
                }
            }
        }
    }

    func refreshStatus() async {
        guard !statusInFlight else { return }
        statusInFlight = true
        defer { statusInFlight = false }

        let result = await run(["status"], busy: false)
        parseStatus(result.output)
        lastUpdated = Date()
    }

    func refreshProfiles() async {
        guard !profilesInFlight else { return }
        profilesInFlight = true
        defer { profilesInFlight = false }

        let result = await run(["profiles"], busyMessage: "Reading EasyEUICC profiles...")
        if result.exitCode == 0 {
            profiles = parseProfiles(result.output)
        }
        appendLog(result.output)
        lastUpdated = Date()
    }

    func startScrcpy() {
        Task {
            let result = await run(["start-scrcpy"], busyMessage: "Starting scrcpy...")
            appendLog(result.output)
            await refreshStatus()
        }
    }

    func startScrcpy(dockedTo frame: DockFrame) {
        Task {
            let result = await run(["start-scrcpy"] + frame.arguments, busyMessage: "Starting scrcpy in the app stage...")
            appendLog(result.output)
            await refreshStatus()
        }
    }

    func stopScrcpy() {
        Task {
            let result = await run(["stop-scrcpy"], busyMessage: "Stopping scrcpy...")
            appendLog(result.output)
            await refreshStatus()
        }
    }

    func authorizeADB() {
        Task {
            let result = await run(["authorize"], busyMessage: "Authorizing ADB over AOA-HID...")
            appendLog(result.output)
            await refreshStatus()
        }
    }

    func switchProfile(_ profile: Profile) {
        guard !ambiguousProfileKeys.contains(profile.identityKey) else {
            appendLog("ERROR ambiguous eSIM profile: \(profile.title). Rename one duplicate in EasyEUICC, then refresh.")
            return
        }
        Task {
            let result = await run(profile.switchArguments, busyMessage: "Switching to \(profile.title)...")
            appendLog(result.output)
            await refreshStatus()
            await refreshProfiles()
        }
    }

    func openWebControl() {
        Task {
            let result = await run(["open-web"], busyMessage: "Opening web console...")
            appendLog(result.output)
        }
    }

    func startWebControl() {
        Task {
            let result = await run(["start-web"], busyMessage: "Starting web console...")
            appendLog(result.output)
            await refreshStatus()
        }
    }

    func setFastDisplay() {
        Task {
            let result = await run(["display", "fast"], busyMessage: "Setting fast display mode...")
            appendLog(result.output)
        }
    }

    func resetDisplay() {
        Task {
            let result = await run(["display", "reset"], busyMessage: "Restoring display mode...")
            appendLog(result.output)
        }
    }

    func captureScreen(to url: URL) async -> Bool {
        let result = await run(["screen-capture", url.path], busy: false)
        return result.exitCode == 0
    }

    func startScreenStream(to url: URL) async -> Bool {
        let result = await run(["start-stream", url.path], busy: false)
        if result.exitCode != 0 {
            appendLog(result.output)
        }
        return result.exitCode == 0
    }

    func stopScreenStream() {
        Task {
            _ = await run(["stop-stream"], busy: false)
        }
    }

    func stopScreenStreamNow() {
        CommandRunner.runSync(helper: helperPath, arguments: ["stop-stream"], environment: commandEnvironment)
    }

    func stopNativeStreamNow() {
        CommandRunner.runSync(helper: helperPath, arguments: ["stop-scrcpy-embedded-stream"], environment: commandEnvironment)
        CommandRunner.runSync(helper: helperPath, arguments: ["stop-h264-stream"], environment: commandEnvironment)
    }

    func stopInputRelayNow() {
        scrcpyControlStream.stop()
        CommandRunner.runSync(helper: helperPath, arguments: ["stop-input"], environment: commandEnvironment)
    }

    func stopAllInputRelays() async {
        scrcpyControlStream.stop()
        _ = await run(["stop-input-all"], busy: false)
    }

    func tapScreen(x: Int, y: Int, screenSize: CGSize = CGSize(width: 1080, height: 2340)) {
        touchScreen(.down, x: x, y: y, screenSize: screenSize)
        touchScreen(.up, x: x, y: y, screenSize: screenSize)
    }

    func swipeScreen(from start: CGPoint, to end: CGPoint, screenSize: CGSize = CGSize(width: 1080, height: 2340)) {
        let steps = 8
        touchScreen(.down, x: Int(start.x.rounded()), y: Int(start.y.rounded()), screenSize: screenSize)
        for step in 1..<steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * progress
            let y = start.y + (end.y - start.y) * progress
            touchScreen(.move, x: Int(x.rounded()), y: Int(y.rounded()), screenSize: screenSize)
        }
        touchScreen(.up, x: Int(end.x.rounded()), y: Int(end.y.rounded()), screenSize: screenSize)
    }

    func longPressScreen(x: Int, y: Int, screenSize: CGSize = CGSize(width: 1080, height: 2340)) {
        Task {
            touchScreen(.down, x: x, y: y, screenSize: screenSize)
            try? await Task.sleep(nanoseconds: 650_000_000)
            touchScreen(.up, x: x, y: y, screenSize: screenSize)
        }
    }

    func touchScreen(_ action: ScrcpyTouchAction, x: Int, y: Int, screenSize: CGSize = CGSize(width: 1080, height: 2340)) {
        guard adbIsConnected else { return }
        scrcpyControlStream.send(
            action: action,
            x: x,
            y: y,
            screenSize: screenSize,
            helper: helperPath,
            environment: commandEnvironment,
            identity: screenStreamID
        )
    }

    func keyEvent(_ name: String) {
        Task {
            _ = await run(["keyevent", name], busy: false)
        }
    }

    func keepAwake() {
        Task {
            _ = await run(["stayon", "true"], busy: false)
        }
    }

    func allowSleep() {
        Task {
            _ = await run(["stayon", "false"], busy: false)
        }
    }

    func inputText(_ text: String) {
        guard !text.isEmpty else { return }
        Task {
            _ = await run(["text", text], busy: false)
        }
    }

    private func run(_ arguments: [String], busy: Bool = true, busyMessage: String? = nil) async -> CommandResult {
        if busy {
            isBusy = true
            if let busyMessage {
                log = busyMessage
            }
        }
        let result = await CommandRunner.run(helper: helperPath, arguments: arguments, environment: commandEnvironment)
        if busy {
            isBusy = false
        }
        if result.exitCode != 0 {
            appendLog("Command failed (\(result.exitCode))\n\(result.output)")
        }
        return result
    }

    private var commandEnvironment: [String: String] {
        var env = [
            "R6C_SSH_HOST": selectedRemote.sshHost,
            "R6C_SSH_PORT": selectedRemote.sshPort,
            "R6C_STREAM_SEGMENT_SECONDS": "1",
            "R6C_H264_STREAM_SEGMENT_SECONDS": "120",
            "R6C_H264_STREAM_BITRATE": "8M"
        ]
        if !selectedDeviceSerial.isEmpty {
            env["R6C_ANDROID_SERIAL"] = selectedDeviceSerial
        }
        return env
    }

    private var selectedDeviceKey: String {
        DeviceSelectionStore.key(for: selectedRemoteID)
    }

    private func savedSelectedDeviceSerial(allowLegacy: Bool) -> String {
        if let serial = defaults.string(forKey: selectedDeviceKey) {
            return serial
        }
        guard allowLegacy else { return "" }
        return defaults.string(forKey: DeviceSelectionStore.legacyKey) ?? ""
    }

    private func persistRemotes() {
        if let data = try? JSONEncoder().encode(remotes) {
            defaults.set(data, forKey: "r6c.remotes")
        }
    }

    private func parseStatus(_ output: String) {
        for (key, value) in R6CLineParser.statusFields(output) {
            switch key {
            case "adb": adbState = value
            case "adb_detail": adbDetail = value
            case "scrcpy": scrcpyState = value
            case "screen": screenState = value
            case "web": webState = value
            default: break
            }
        }
    }

    private func parseProfiles(_ output: String) -> [Profile] {
        R6CLineParser.profiles(output)
    }

    private func parseDevices(_ output: String) -> [AndroidDevice] {
        R6CLineParser.devices(output)
    }

    private func appendLog(_ text: String) {
        let clean = text.isEmpty ? "(no output)" : text
        let stamp = DateFormatter.logTime.string(from: Date())
        log = "[\(stamp)] \(clean)"
    }
}

extension DateFormatter {
    static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@main
struct R6CPhoneControlApp: App {
    @StateObject private var model = AppModel()
    @State private var didRequestInitialRefresh = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 680)
                .task {
                    if !didRequestInitialRefresh {
                        didRequestInitialRefresh = true
                        await model.stopAllInputRelays()
                        model.refreshAll()
                    }
                    var ticks = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await model.refreshStatus()
                        ticks += 1
                        if ticks % 3 == 0 {
                            await model.refreshDevices()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopInputRelayNow()
                    model.stopNativeStreamNow()
                    model.stopScreenStreamNow()
                }
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                controlColumn
                Divider()
                detailColumn
            }
            .padding(.top, 36)
            .padding(.leading, 28)
            .padding(.trailing, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: 16) {
                    remoteSection
                    deviceSection
                    connectionSection
                    displaySection
                    profileSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }

            footerView
        }
        .frame(width: 440)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Remotes")
                Spacer()
                Menu(model.selectedRemote.name) {
                    ForEach(model.remotes) { remote in
                        Button(remote.name) {
                            model.selectRemote(remote)
                        }
                    }
                }
                .frame(width: 170)
            }

            HStack(spacing: 8) {
                TextField("Name", text: $model.newRemoteName)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $model.newRemotePort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
            }
            HStack(spacing: 8) {
                TextField("IP or user@host", text: $model.newRemoteHost)
                    .textFieldStyle(.roundedBorder)
                Button(action: { model.addRemote() }) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(model.remoteDraftError != nil)
            }

            if let error = model.remoteDraftError, !model.newRemoteHost.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            HStack {
                Text("\(model.selectedRemote.sshHost):\(model.selectedRemote.sshPort)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(role: .destructive, action: { model.removeSelectedRemote() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.remotes.count <= 1)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Android Devices")
                if !model.devices.isEmpty {
                    Text(deviceCountText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { Task { await model.refreshDevices() } }) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if model.devices.isEmpty {
                Text("No devices detected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.devices) { device in
                        Button {
                            model.selectDevice(device)
                        } label: {
                            HStack {
                                Image(systemName: device.serial == model.selectedDeviceSerial ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(device.serial == model.selectedDeviceSerial ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.title)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("\(device.state)  \(device.product)/\(device.device)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(device.isReady ? "Ready" : device.state)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((device.isReady ? Color.green : Color.orange).opacity(0.18))
                                    .foregroundColor(device.isReady ? .green : .orange)
                                    .cornerRadius(4)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!device.isReady)
                        .opacity(device.isReady ? 1 : 0.45)
                        .background(device.serial == model.selectedDeviceSerial ? Color.accentColor.opacity(0.08) : Color.clear)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var deviceCountText: String {
        let ready = model.devices.filter(\.isReady).count
        return "\(ready)/\(model.devices.count) ready"
    }

    private var detailColumn: some View {
        GeometryReader { proxy in
            let logHeight = min(max(proxy.size.height * 0.18, 108), 152)
            let phoneMaxHeight = min(max(proxy.size.height - logHeight - 112, 360), 694)
            let phoneMaxWidth = max(proxy.size.width - 232, 280)

            VStack(spacing: 12) {
                PhoneScreenPanel(phoneMaxSize: CGSize(width: phoneMaxWidth, height: phoneMaxHeight))
                    .environmentObject(model)

                logPanel
                    .frame(height: logHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("R6C Phone Control")
                    .font(.system(size: 20, weight: .bold))
                Text("Remote Android Management")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { model.refreshAll() }) {
                Label("Refresh All", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(height: 68)
        .background(Color(NSColor.controlBackgroundColor))
        .border(Color(NSColor.separatorColor), edges: [.bottom])
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Connectivity")
            
            StatusRow(label: "ADB Status", value: model.adbState, detail: model.adbDetail, icon: "cpu")
            StatusRow(label: "External scrcpy", value: model.screenState, icon: "display")
            
            HStack(spacing: 10) {
                Button(action: { model.authorizeADB() }) {
                    Label("Authorize ADB", systemImage: "lock.open")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Display Control")
            
            HStack {
                Button(action: {
                    if model.scrcpyIsRunning {
                        model.stopScrcpy()
                    } else {
                        model.startScrcpy()
                    }
                }) {
                    Label(model.scrcpyIsRunning ? "Stop External scrcpy" : "External scrcpy", 
                          systemImage: model.scrcpyIsRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.scrcpyIsRunning ? .red : .accentColor)
            }
            
            HStack(spacing: 12) {
                Button(action: { model.setFastDisplay() }) {
                    Label("Fast Mode", systemImage: "bolt.fill")
                }
                .buttonStyle(.bordered)
                
                Button(action: { model.resetDisplay() }) {
                    Label("Reset Display", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("eSIM Profiles")
                Spacer()
                if !model.profiles.isEmpty {
                    Text("\(model.filteredProfiles.count)/\(model.profiles.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button(action: { Task { await model.refreshProfiles() } }) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            TextField("Search name, provider, or state", text: $model.profileSearch)
                .textFieldStyle(.roundedBorder)
            
            if model.profiles.isEmpty {
                Text("No profiles available.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else if model.filteredProfiles.isEmpty {
                Text("No matching profiles.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.filteredProfiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isAmbiguous: model.ambiguousProfileKeys.contains(profile.identityKey)
                        ) {
                            model.switchProfile(profile)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var footerView: some View {
        HStack {
            HStack(spacing: 6) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Last updated: \(model.lastUpdated, formatter: DateFormatter.logTime)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("R6C Utility v1.0")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .border(Color(NSColor.separatorColor), edges: [.top])
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("System Log")
                Spacer()
                Text(DateFormatter.logTime.string(from: model.lastUpdated))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ScrollView {
                Text(model.log)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 80, maxHeight: 120)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}

struct PhoneScreenPanel: View {
    let phoneMaxSize: CGSize

    @EnvironmentObject private var model: AppModel
    @State private var screenImage: NSImage?
    @State private var screenPixels = CGSize(width: 1080, height: 2340)
    @State private var screenLabel = "waiting"
    @State private var captureInFlight = false
    @State private var activeStreamID = ""
    @State private var lastFrameDate: Date?
    @State private var lastStreamRestart = Date.distantPast
    @State private var frameCount = 0
    @State private var fpsWindowStart = Date()
    @State private var phoneText = ""
    @State private var touchIsDown = false
    @State private var lastTouchPoint: CGPoint?
    @State private var lastTouchMoveDate = Date.distantPast
    @State private var h264StreamReady = false
    @State private var nativeStreamRestartID = UUID()

    private let liveScreenURL = URL(fileURLWithPath: "/tmp/r6c-phone-control-live.png")
    private var streamFrameURL: URL { StreamFramePath.url(for: model.screenStreamID) }
    private let framePollNanoseconds: UInt64 = 33_000_000
    private let staleStreamSeconds: TimeInterval = 6
    private let minStreamRestartGap: TimeInterval = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Embedded Phone Control")
                        .font(.system(size: 15, weight: .semibold))
                    Text("scrcpy H.264 screen, \(Int(screenPixels.width))x\(Int(screenPixels.height)); \(screenLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        restartNativeStream()
                    } label: {
                        Label("Restart Stream", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.scrcpyIsRunning ? model.stopScrcpy() : model.startScrcpy()
                    } label: {
                        Label(model.scrcpyIsRunning ? "Stop External scrcpy" : "External scrcpy", systemImage: model.scrcpyIsRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }

            HStack(alignment: .center, spacing: 18) {
                embeddedScreen(maxSize: phoneMaxSize)

                VStack(alignment: .leading, spacing: 10) {
                    StatusChip(title: "ADB", value: model.adbState, isGood: model.adbState == "connected")
                    StatusChip(title: "stream", value: h264StreamReady ? "scrcpy" : "starting", isGood: h264StreamReady)
                    StatusChip(title: "device", value: model.selectedDeviceSerial.isEmpty ? "auto" : model.selectedDeviceSerial, isGood: model.adbState == "connected")

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 8) {
                        Button {
                            model.keyEvent("BACK")
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Back")

                        Button {
                            model.keyEvent("HOME")
                        } label: {
                            Image(systemName: "circle")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Home")

                        Button {
                            model.keyEvent("APP_SWITCH")
                        } label: {
                            Image(systemName: "square.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Recents")
                    }
                    .buttonStyle(.bordered)

                    HStack(spacing: 8) {
                        TextField("Text", text: $phoneText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendText)

                        Button(action: sendText) {
                            Image(systemName: "paperplane.fill")
                                .frame(width: 24)
                        }
                        .buttonStyle(.bordered)
                        .disabled(phoneText.isEmpty)
                        .help("Send text")
                    }

                    HStack(spacing: 8) {
                        Button {
                            scrollPage(up: true)
                        } label: {
                            Image(systemName: "arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Swipe up")

                        Button {
                            scrollPage(up: false)
                        } label: {
                            Image(systemName: "arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Swipe down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        restartNativeStream()
                    } label: {
                        Label("Restart Stream", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(captureInFlight)

                    Button {
                        model.scrcpyIsRunning ? model.stopScrcpy() : model.startScrcpy()
                    } label: {
                        Label(model.scrcpyIsRunning ? "Stop scrcpy" : "External scrcpy", systemImage: model.scrcpyIsRunning ? "stop.fill" : "macwindow")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.scrcpyIsRunning ? .red : .accentColor)

                    Button {
                        model.keyEvent("KEYCODE_WAKEUP")
                    } label: {
                        Label("Wake", systemImage: "sun.max.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.keepAwake()
                    } label: {
                        Label("Keep Awake", systemImage: "lightbulb.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.allowSleep()
                    } label: {
                        Label("Allow Sleep", systemImage: "moon.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.setFastDisplay()
                    } label: {
                        Label("Fast Display", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(width: 150)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            model.stopScreenStream()
        }
    }

    private func embeddedScreen(maxSize: CGSize) -> some View {
        let fittedSize = ScreenFit.size(for: screenPixels, in: maxSize)

        return ZStack {
            RoundedRectangle(cornerRadius: 34)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            RoundedRectangle(cornerRadius: 28)
                .fill(Color(NSColor.textBackgroundColor))
                .padding(10)

            GeometryReader { proxy in
                ZStack {
                    NativeH264StreamView(
                        configuration: model.h264StreamConfiguration,
                        onStatus: { status in
                            screenLabel = status
                            h264StreamReady = status == "scrcpy h264"
                        },
                        onSize: { size in
                            screenPixels = size
                        }
                    )
                    .id("\(model.screenStreamID)-\(nativeStreamRestartID.uuidString)")

                    if !h264StreamReady {
                        VStack(spacing: 12) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 42, weight: .light))
                                .foregroundColor(.secondary)
                            Text("Starting scrcpy stream")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Tap or drag here to control the phone.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(screenGesture(in: proxy.size))
                        .background(
                            TrackpadHorizontalSwipeReader { direction in
                                sendTrackpadSwipe(direction)
                            }
                        )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(12)
            .clipShape(RoundedRectangle(cornerRadius: 28))

        }
        .frame(width: fittedSize.width, height: fittedSize.height)
        .overlay(
            RoundedRectangle(cornerRadius: 34)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func sendTrackpadSwipe(_ direction: TrackpadSwipeDirection) {
        let y = screenPixels.height / 2
        let startX = direction == .left ? screenPixels.width * 0.75 : screenPixels.width * 0.25
        let endX = direction == .left ? screenPixels.width * 0.25 : screenPixels.width * 0.75
        model.swipeScreen(
            from: CGPoint(x: startX, y: y),
            to: CGPoint(x: endX, y: y),
            screenSize: screenPixels
        )
    }

    private func screenGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let point = mapToPhone(value.location, in: size) else { return }
                let x = Int(point.x.rounded())
                let y = Int(point.y.rounded())
                lastTouchPoint = point
                if !touchIsDown {
                    touchIsDown = true
                    lastTouchMoveDate = .distantPast
                    model.touchScreen(.down, x: x, y: y, screenSize: screenPixels)
                    return
                }
                let now = Date()
                guard now.timeIntervalSince(lastTouchMoveDate) >= 0.012 else { return }
                lastTouchMoveDate = now
                model.touchScreen(.move, x: x, y: y, screenSize: screenPixels)
            }
            .onEnded { value in
                let point = mapToPhone(value.location, in: size) ?? lastTouchPoint
                if let point {
                    let x = Int(point.x.rounded())
                    let y = Int(point.y.rounded())
                    if !touchIsDown {
                        model.touchScreen(.down, x: x, y: y, screenSize: screenPixels)
                    }
                    model.touchScreen(.up, x: x, y: y, screenSize: screenPixels)
                }
                touchIsDown = false
                lastTouchPoint = nil
            }
    }

    private func sendText() {
        guard !phoneText.isEmpty else { return }
        model.inputText(phoneText)
        phoneText = ""
    }

    private func scrollPage(up: Bool) {
        let x = screenPixels.width / 2
        let top = screenPixels.height * 0.25
        let bottom = screenPixels.height * 0.75
        model.swipeScreen(
            from: CGPoint(x: x, y: up ? bottom : top),
            to: CGPoint(x: x, y: up ? top : bottom),
            screenSize: screenPixels
        )
    }

    private func restartNativeStream() {
        h264StreamReady = false
        screenLabel = "scrcpy restarting"
        nativeStreamRestartID = UUID()
    }

    private func mapToPhone(_ point: CGPoint, in container: CGSize) -> CGPoint? {
        guard screenPixels.width > 0, screenPixels.height > 0 else { return nil }
        let scale = min(container.width / screenPixels.width, container.height / screenPixels.height)
        let drawSize = CGSize(width: screenPixels.width * scale, height: screenPixels.height * scale)
        let origin = CGPoint(x: (container.width - drawSize.width) / 2, y: (container.height - drawSize.height) / 2)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard local.x >= 0, local.y >= 0, local.x <= drawSize.width, local.y <= drawSize.height else {
            return nil
        }
        return CGPoint(x: local.x / scale, y: local.y / scale)
    }

    private func refreshScreen() async {
        guard !captureInFlight else { return }
        captureInFlight = true
        defer { captureInFlight = false }
        await captureStillFrame()
    }

    private func restartStream() async {
        guard !captureInFlight else { return }
        captureInFlight = true
        defer { captureInFlight = false }

        lastStreamRestart = Date()
        lastFrameDate = nil
        activeStreamID = model.screenStreamID
        screenImage = nil
        screenLabel = "starting stream"
        if await model.startScreenStream(to: streamFrameURL) {
            await captureStillFrame()
            await loadStreamFrame()
        } else {
            await captureStillFrame()
        }
    }

    private func captureStillFrame() async {
        guard await model.captureScreen(to: liveScreenURL), let image = NSImage(contentsOf: liveScreenURL) else {
            screenLabel = "capture failed"
            return
        }
        screenImage = image
        screenPixels = image.pixelSize
        screenLabel = DateFormatter.logTime.string(from: Date())
    }

    private func loadStreamFrame() async {
        guard let frame = await StreamFrameLoader.load(from: streamFrameURL, after: lastFrameDate) else { return }

        lastFrameDate = frame.modified
        screenImage = NSImage(cgImage: frame.cgImage, size: frame.pixelSize)
        screenPixels = frame.pixelSize
        updateFrameRate()
    }

    private func restartStreamIfStale() async {
        guard StreamStaleness.shouldRestart(
            lastFrameDate: lastFrameDate,
            now: Date(),
            lastRestart: lastStreamRestart,
            staleAfter: staleStreamSeconds,
            minRestartGap: minStreamRestartGap,
            hasImage: screenImage != nil
        ) else { return }

        screenLabel = "restarting stream"
        await restartStream()
    }

    private func updateFrameRate() {
        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        guard elapsed >= 1 else { return }
        let fps = Double(frameCount) / elapsed
        screenLabel = fps < 1 ? "stream ready" : "\(Int(fps)) fps"
        frameCount = 0
        fpsWindowStart = Date()
    }
}

extension NSImage {
    var pixelSize: CGSize {
        if let rep = representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}

struct TrackpadHorizontalSwipeReader: NSViewRepresentable {
    let onSwipe: (TrackpadSwipeDirection) -> Void

    func makeNSView(context: Context) -> TrackpadHorizontalSwipeView {
        let view = TrackpadHorizontalSwipeView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: TrackpadHorizontalSwipeView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

@MainActor
final class TrackpadHorizontalSwipeView: NSView {
    var onSwipe: ((TrackpadSwipeDirection) -> Void)?

    private var monitor: Any?
    private var accumulator = TrackpadSwipeAccumulator()
    private var lastScrollEvent = Date.distantPast

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            accumulator.reset()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return event }

        let now = Date()
        if now.timeIntervalSince(lastScrollEvent) > 0.35 {
            accumulator.reset()
        }
        lastScrollEvent = now

        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let decision = accumulator.observe(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY,
            isGestureEnding: phase.contains(.ended) ||
                phase.contains(.cancelled) ||
                momentumPhase.contains(.ended) ||
                momentumPhase.contains(.cancelled),
            isMomentum: !momentumPhase.isEmpty,
            isDirectionInverted: event.isDirectionInvertedFromDevice
        )

        if let direction = decision.direction {
            onSwipe?(direction)
        }
        return decision.shouldConsumeEvent ? nil : event
    }
}

struct DockTargetReader: NSViewRepresentable {
    let onChange: (DockFrame) -> Void

    func makeNSView(context: Context) -> DockTargetView {
        let view = DockTargetView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: DockTargetView, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleUpdate()
    }
}

final class DockTargetView: NSView {
    var onChange: ((DockFrame) -> Void)?
    private var lastFrame: DockFrame?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    override func layout() {
        super.layout()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.publishFrame()
        }
    }

    private func publishFrame() {
        guard let window, let screen = window.screen else { return }
        let rectInWindow = convert(bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        let inset: CGFloat = 12
        let dockRect = rectOnScreen.insetBy(dx: inset, dy: inset)
        let topLeftY = screen.frame.maxY - dockRect.maxY
        let frame = DockFrame(
            x: max(0, Int(dockRect.minX.rounded())),
            y: max(0, Int(topLeftY.rounded())),
            width: max(240, Int(dockRect.width.rounded())),
            height: max(360, Int(dockRect.height.rounded()))
        )
        if frame != lastFrame {
            lastFrame = frame
            try? "\(frame.x) \(frame.y) \(frame.width) \(frame.height)\n"
                .write(toFile: "/tmp/r6c-scrcpy-dock-frame", atomically: true, encoding: .utf8)
            onChange?(frame)
        }
    }
}

struct StatusChip: View {
    let title: String
    let value: String
    let isGood: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(isGood ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

enum PhoneSnapshotLoader {
    static func load() -> (image: NSImage?, label: String) {
        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                return (image, url.lastPathComponent)
            }
        }
        return (nil, "No local screen capture found")
    }

    private static var candidates: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("R6CPhoneControl")
            .appendingPathComponent("r6c-android-control")

        let names = [
            "latest-screen.png",
            "latest-screen-final.png",
            "latest-screen-awake.png",
            "latest-screen-after-power.png",
            "easyeuicc-step-after-unlock.png",
            "easyeuicc-step-lock.png",
            "public-screen-token.png"
        ]

        let fileManager = FileManager.default
        let existing = names
            .map { support.appendingPathComponent($0) }
            .compactMap { url -> (url: URL, modified: Date, size: Int64)? in
                guard
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                    let modified = values.contentModificationDate,
                    let size = values.fileSize
                else {
                    return nil
                }
                return (url, modified, Int64(size))
            }
            .filter { fileManager.fileExists(atPath: $0.url.path) }

        let useful = existing
            .filter { $0.size > 100_000 }
            .sorted { $0.modified > $1.modified }
            .map(\.url)

        if !useful.isEmpty {
            return useful
        }

        return existing
            .sorted { $0.modified > $1.modified }
            .map(\.url)
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var detail: String? = nil
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .center)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary)
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct ProfileRow: View {
    let profile: Profile
    let isAmbiguous: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(profile.isEnabled ? .primary : .secondary)
                    Text(profile.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isAmbiguous {
                    Text("Duplicate")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                } else if profile.isEnabled {
                    Text("Active")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(8)
            .background(profile.isEnabled ? Color.accentColor.opacity(0.05) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .disabled(isAmbiguous)
        .help(isAmbiguous ? "Multiple eSIM profiles have this same name and provider, and no ICCID was reported." : "")
    }
}

struct HSplitter<Content: View>: View {
    var content: () -> Content
    
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
    }
}

extension View {
    func border(_ color: Color, edges: Set<Edge>) -> some View {
        self.overlay(
            ZStack {
                if edges.contains(.top) {
                    Rectangle().frame(height: 1).foregroundColor(color).frame(maxHeight: .infinity, alignment: .top)
                }
                if edges.contains(.bottom) {
                    Rectangle().frame(height: 1).foregroundColor(color).frame(maxHeight: .infinity, alignment: .bottom)
                }
                if edges.contains(.leading) {
                    Rectangle().frame(width: 1).foregroundColor(color).frame(maxWidth: .infinity, alignment: .leading)
                }
                if edges.contains(.trailing) {
                    Rectangle().frame(width: 1).foregroundColor(color).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        )
    }
}
