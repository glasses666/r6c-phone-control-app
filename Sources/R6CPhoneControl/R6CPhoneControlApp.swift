import AppKit
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Profile: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let nickname: String?
    let state: String
    let provider: String
    let iccid: String
    let isdpAid: String

    init(
        name: String,
        nickname: String? = nil,
        state: String,
        provider: String,
        iccid: String = "",
        isdpAid: String = ""
    ) {
        self.name = name
        let cleanNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nickname = cleanNickname?.isEmpty == false ? cleanNickname : nil
        self.state = state
        self.provider = provider
        self.iccid = iccid
        self.isdpAid = isdpAid
    }

    var isEnabled: Bool {
        state.localizedCaseInsensitiveContains("enabled") || state.contains("已启用")
    }

    var title: String {
        provider.isEmpty ? displayName : "\(displayName) / \(provider)"
    }

    var displayName: String {
        guard let nickname, !nickname.isEmpty else { return name }
        return nickname
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

struct PhoneMessage: Identifiable, Equatable {
    let id = UUID()
    let dateMilliseconds: Int64
    let address: String
    let type: String
    let body: String

    var date: Date? {
        guard dateMilliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(dateMilliseconds) / 1000)
    }

    var typeLabel: String {
        switch type {
        case "1": return "Inbox"
        case "2": return "Sent"
        case "3": return "Draft"
        case "4": return "Outbox"
        case "5": return "Failed"
        case "6": return "Queued"
        default: return type.isEmpty ? "SMS" : "SMS \(type)"
        }
    }
}

struct CommandResult {
    let exitCode: Int32
    let output: String
}

enum SensitiveLogRedactor {
    static func redact(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"LPA:1\$[^\s"',}]+"#, with: "LPA:1$[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)"activationCode"\s*:\s*"[^"]+""#, with: #""activationCode":"[REDACTED]""#, options: .regularExpression)
            .replacingOccurrences(of: #"(?i)"matchingId"\s*:\s*"[^"]+""#, with: #""matchingId":"[REDACTED]""#, options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(\+QCCID:\s*)[0-9]{10,22}F?"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(?<![0-9])[0-9]{18,22}F?(?![0-9A-F])"#, with: "[ICCID REDACTED]", options: .regularExpression)
    }
}

struct RemoteConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var sshHost: String
    var sshPort: String

    static let localUSB = RemoteConfig(name: "This Mac", sshHost: "", sshPort: "22")

    var isLocal: Bool { sshHost.isEmpty }
    var connectionLabel: String { isLocal ? "This Mac · USB" : name }
    var connectionDetail: String { isLocal ? "Local ADB" : "\(sshHost):\(sshPort)" }
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

enum ManagedDeviceKind: String {
    case android
    case dji4G
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

enum ScreenCoordinateMapper {
    static func touchSize(for videoSize: CGSize, deviceSize: CGSize) -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0, deviceSize.width > 0, deviceSize.height > 0 else {
            return videoSize
        }
        let videoLandscape = videoSize.width > videoSize.height
        let deviceLandscape = deviceSize.width > deviceSize.height
        return videoLandscape == deviceLandscape ? deviceSize : CGSize(width: deviceSize.height, height: deviceSize.width)
    }

    static func mapPoint(_ point: CGPoint, from videoSize: CGSize, to deviceSize: CGSize) -> CGPoint {
        let target = touchSize(for: videoSize, deviceSize: deviceSize)
        guard videoSize.width > 0, videoSize.height > 0 else { return point }
        return CGPoint(
            x: point.x * target.width / videoSize.width,
            y: point.y * target.height / videoSize.height
        )
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
                self?.onStatus("h264")
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
        process.arguments = [configuration.helperPath, "h264-stream"]
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
            onStatus("h264 starting")
        } catch {
            onStatus("h264 failed")
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
                onStatus("h264")
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
    private struct JSONProfile: Decodable {
        let iccid: String?
        let state: String?
        let name: String?
        let nickName: String?
        let displayName: String?
        let provider: String?
    }

    static func statusFields(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines(in: output) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }
        return fields
    }

    static func physicalDisplaySize(_ output: String) -> CGSize? {
        for line in lines(in: output) where line.hasPrefix("Physical size:") {
            let value = line.replacingOccurrences(of: "Physical size:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: "x", maxSplits: 1).compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                return CGSize(width: parts[0], height: parts[1])
            }
        }
        return nil
    }

    static func profiles(_ output: String) -> [Profile] {
        lines(in: output).compactMap { line -> Profile? in
            guard line.hasPrefix("PROFILE ") else { return nil }
            return Profile(
                name: extract("name", from: line),
                state: extract("state", from: line),
                provider: extract("provider", from: line),
                iccid: extract("iccid", from: line)
            )
        }
    }

    static func profilesJSON(_ output: String) -> [Profile] {
        guard let data = output.data(using: .utf8) else { return [] }
        guard let rawProfiles = try? JSONDecoder().decode([JSONProfile].self, from: data) else { return [] }
        return rawProfiles.compactMap { raw in
            let name = firstNonEmpty(raw.displayName, raw.nickName, raw.name)
            guard !name.isEmpty else { return nil }
            return Profile(
                name: name,
                state: localizedState(raw.state ?? ""),
                provider: raw.provider ?? "",
                iccid: raw.iccid ?? ""
            )
        }
    }

    static func devices(_ output: String) -> [AndroidDevice] {
        lines(in: output).compactMap { line in
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

    static func messages(_ output: String) -> [PhoneMessage] {
        lines(in: output).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == "SMS" else { return nil }
            return PhoneMessage(
                dateMilliseconds: Int64(parts[1]) ?? 0,
                address: String(parts[2]),
                type: String(parts[3]),
                body: String(parts[4])
            )
        }
    }

    static func profileLogLines(_ profiles: [Profile]) -> String {
        profiles.map { profile in
            #"PROFILE name="\#(escaped(profile.name))" state="\#(escaped(profile.state))" provider="\#(escaped(profile.provider))" iccid="\#(escaped(profile.iccid))""#
        }
        .joined(separator: "\n")
    }

    private static func extract(_ key: String, from line: String) -> String {
        let marker = "\(key)=\""
        guard let start = line.range(of: marker) else { return "" }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return String(rest) }
        return String(rest[..<end])
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func localizedState(_ state: String) -> String {
        let clean = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if lower == "enabled" || lower == "enable" || clean.contains("已启用") {
            return "已启用"
        }
        if lower == "disabled" || lower == "disable" || clean.contains("已禁用") {
            return "已禁用"
        }
        return clean
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }

    private static func lines(in output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
    @Published var batteryState = "unknown"
    @Published var networkState = "unknown"
    @Published var carrierState = "unknown"
    @Published var mobileDataState = "unknown"
    @Published var wifiState = "unknown"
    @Published var bluetoothState = "unknown"
    @Published var profiles: [Profile] = []
    @Published var messages: [PhoneMessage] = []
    @Published var remotes: [RemoteConfig] = []
    @Published var selectedRemoteID: UUID?
    @Published var devices: [AndroidDevice] = []
    @Published var selectedDeviceSerial = ""
    @Published var selectedDeviceKind: ManagedDeviceKind = .android
    @Published var djiSnapshot = DJI4GSnapshot.disconnected
    @Published var djiNeighborCells: [DJINeighborCell] = []
    @Published var djiOperators: [DJINetworkOperator] = []
    @Published var djiProfiles: [Profile] = []
    @Published var djiHostNetwork = DJIHostNetworkSnapshot.disconnected
    @Published var djiLog = "Connect the DJI cellular dongle over USB to begin."
    @Published var djiStatusInFlight = false
    @Published var djiNetworkInFlight = false
    @Published var djiOperatorScanInFlight = false
    @Published var djiNeighborScanInFlight = false
    @Published var djiProfileInFlight = false
    @Published var newRemoteName = ""
    @Published var newRemoteHost = ""
    @Published var newRemotePort = "22"
    @Published var downloadInput = ""
    @Published var shellInput = ""
    @Published var log = "Ready."
    @Published var isBusy = false
    @Published var fastDisplayMode = false
    @Published var touchScreenPixels = CGSize(width: 1080, height: 2340)
    @Published var lastUpdated = Date()

    private let helperPath: String
    private let djiATClient: DJIATClient
    private let djiLPACClient: DJILPACClient
    private let djiHostNetworkClient = DJIHostNetworkClient()
    private var statusInFlight = false
    private var profilesInFlight = false
    private var messagesInFlight = false
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

        let djiHelperPath: String
        if let bundled = Bundle.main.path(forResource: "dji-at-helper", ofType: nil) {
            djiHelperPath = bundled
        } else {
            djiHelperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/dji-at-helper")
                .path
        }
        djiATClient = DJIATClient(helperPath: djiHelperPath)

        let djiLPACPath: String
        if let bundled = Bundle.main.url(forResource: "lpac", withExtension: nil, subdirectory: "lpac") {
            djiLPACPath = bundled.path
        } else {
            djiLPACPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Vendor/lpac-dji/lpac")
                .path
        }
        djiLPACClient = DJILPACClient(executablePath: djiLPACPath)

        if
            let data = defaults.data(forKey: "r6c.remotes"),
            let decoded = try? JSONDecoder().decode([RemoteConfig].self, from: data),
            !decoded.isEmpty
        {
            remotes = decoded
            if let localIndex = remotes.firstIndex(where: \.isLocal) {
                remotes[localIndex].name = "This Mac"
            } else {
                remotes.insert(.localUSB, at: 0)
            }
        } else {
            remotes = [.localUSB]
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
        if let savedKind = defaults.string(forKey: "r6c.selectedManagedDeviceKind") {
            selectedDeviceKind = ManagedDeviceKind(rawValue: savedKind) ?? .android
        }

        // Remove a native stream left behind by an unclean previous launch.
        _ = CommandRunner.runSync(
            helper: helperPath,
            arguments: ["stop-h264-stream"],
            environment: commandEnvironment,
            timeout: 3
        )
    }

    var adbIsConnected: Bool { adbState == "connected" }
    var scrcpyIsRunning: Bool { scrcpyState == "running" }
    var mobileDataIsOn: Bool { mobileDataState == "on" }
    var wifiIsOn: Bool { wifiState == "on" }
    var bluetoothIsOn: Bool { bluetoothState == "on" }
    var djiMacUplinkIsReady: Bool { djiHostNetwork.isReady && djiSnapshot.hasDataSession }
    var selectedRemote: RemoteConfig {
        remotes.first(where: { $0.id == selectedRemoteID }) ?? remotes[0]
    }
    var remoteDraftError: String? {
        RemoteDraftValidator.error(host: newRemoteHost, port: newRemotePort)
    }
    var ambiguousProfileKeys: Set<String> {
        Profile.ambiguousIdentityKeys(in: profiles)
    }
    var activeProfile: Profile? {
        profiles.first(where: \.isEnabled) ?? profiles.first
    }
    var selectedAndroidDevice: AndroidDevice? {
        devices.first(where: { $0.serial == selectedDeviceSerial })
    }
    var screenStreamID: String {
        "\(selectedRemote.isLocal ? "local" : selectedRemote.connectionDetail):\(selectedDeviceSerial)"
    }
    var h264StreamConfiguration: H264StreamConfiguration {
        H264StreamConfiguration(identity: screenStreamID, helperPath: helperPath, environment: commandEnvironment)
    }

    func refreshAll() {
        Task {
            await refreshDevices()
            if selectedDeviceKind == .dji4G {
                await refreshDJIStatus()
                await refreshDJIProfiles()
            } else {
                await refreshStatus()
                await refreshProfiles()
                await refreshMessages()
                await detectDJI4G()
            }
        }
    }

    func selectRemote(_ remote: RemoteConfig) {
        scrcpyControlStream.stop()
        selectedRemoteID = remote.id
        selectedDeviceSerial = savedSelectedDeviceSerial(allowLegacy: false)
        defaults.set(remote.id.uuidString, forKey: "r6c.selectedRemoteID")
        devices = []
        profiles = []
        messages = []
        refreshAll()
    }

    func selectDevice(_ device: AndroidDevice) {
        guard device.serial != selectedDeviceSerial || selectedDeviceKind != .android else { return }
        scrcpyControlStream.stop()
        selectedDeviceKind = .android
        selectedDeviceSerial = device.serial
        defaults.set(ManagedDeviceKind.android.rawValue, forKey: "r6c.selectedManagedDeviceKind")
        defaults.set(device.serial, forKey: selectedDeviceKey)
        profiles = []
        messages = []
        Task {
            await stopAllInputRelays()
            await refreshStatus()
            await refreshProfiles()
            await refreshMessages()
        }
    }

    func selectDJI4G() {
        guard selectedDeviceKind != .dji4G else { return }
        scrcpyControlStream.stop()
        selectedDeviceKind = .dji4G
        defaults.set(ManagedDeviceKind.dji4G.rawValue, forKey: "r6c.selectedManagedDeviceKind")
        Task {
            await stopAllInputRelays()
            await refreshDJIStatus()
            await refreshDJIProfiles()
        }
    }

    func refreshDJIStatus(allowDuringProfileOperation: Bool = false) async {
        guard !djiStatusInFlight, allowDuringProfileOperation || !djiProfileInFlight else { return }
        djiStatusInFlight = true
        defer { djiStatusInFlight = false }

        let result = await djiATClient.run(["status"])
        guard result.exitCode == 0 else {
            djiSnapshot = .disconnected
            djiHostNetwork = .disconnected
            djiLog = SensitiveLogRedactor.redact(result.output)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastUpdated = Date()
            return
        }

        djiSnapshot = DJIATResponseParser.snapshot(from: result.output)
        djiHostNetwork = await djiHostNetworkClient.snapshot()
        djiLog = "Live modem status refreshed over USB interface 3."
        lastUpdated = Date()
    }

    func detectDJI4G() async {
        guard !djiStatusInFlight, !djiProfileInFlight, !djiSnapshot.isConnected else { return }
        djiStatusInFlight = true
        defer { djiStatusInFlight = false }
        let result = await djiATClient.run(["detect"])
        if result.exitCode == 0 {
            var detected = DJIATResponseParser.snapshot(from: result.output)
            detected.isConnected = true
            djiSnapshot = detected
            djiHostNetwork = await djiHostNetworkClient.snapshot()
            djiLog = "DJI cellular dongle detected on USB."
        }
    }

    func setDJIUSBMode(_ mode: DJIUSBMode) {
        guard djiSnapshot.isConnected, !djiNetworkInFlight, !djiProfileInFlight else { return }
        Task {
            djiNetworkInFlight = true
            defer { djiNetworkInFlight = false }
            guard await applyDJIUSBMode(mode) else { return }
            await refreshDJIStatus()
            djiLog = "USB mode changed to \(mode.displayName)."
        }
    }

    func connectDJIToMac() {
        guard djiSnapshot.isConnected, !djiNetworkInFlight, !djiProfileInFlight else { return }
        Task {
            djiNetworkInFlight = true
            defer { djiNetworkInFlight = false }
            djiLog = "Starting the native ECM network link..."

            let result = await startDJIDataSession(forceECM: true)
            if result.ready {
                let dnsNote = result.dnsConfigured ? "trusted DNS" : "carrier DNS"
                djiLog = "Mac uplink ready on \(djiHostNetwork.interfaceName) · \(djiHostNetwork.ipv4Address) · \(dnsNote)."
            } else if djiHostNetwork.isReady {
                djiLog = "USB Ethernet has DHCP, but the cellular PDP session is offline."
            } else {
                djiLog = "ECM is active, but macOS has not received a DHCP lease yet."
            }
        }
    }

    func disconnectDJIFromMac() {
        guard djiSnapshot.isConnected, !djiNetworkInFlight, !djiProfileInFlight else { return }
        Task {
            djiNetworkInFlight = true
            defer { djiNetworkInFlight = false }
            let result = await djiATClient.run(["raw", "AT+QLWWANDOWN=1,\"IP\""])
            guard DJIATResponseParser.commandSucceeded(result.output) else {
                djiLog = "Unable to stop the USB data session."
                return
            }
            try? await Task.sleep(for: .seconds(1))
            djiHostNetwork = await djiHostNetworkClient.snapshot()
            await refreshDJIStatus()
            djiLog = "Mac cellular data session stopped."
        }
    }

    private func applyDJIUSBMode(_ mode: DJIUSBMode) async -> Bool {
        guard djiSnapshot.usbModeCode != mode.rawValue else { return true }
        let result = await djiATClient.run(["raw", "AT+QCFG=\"usbnet\",\(mode.rawValue)"])
        guard DJIATResponseParser.commandSucceeded(result.output) else {
            djiLog = "USB mode change failed."
            return false
        }

        djiLog = "USB mode changed. Waiting for the module to re-enumerate..."
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(1))
            let probe = await djiATClient.run(["detect"])
            if probe.exitCode == 0 { return true }
        }
        djiLog = "The module did not reconnect after the USB mode change."
        return false
    }

    private func readDJIModemState() async -> (snapshot: DJI4GSnapshot, iccid: String?)? {
        let result = await djiATClient.run(["status"])
        guard result.exitCode == 0 else { return nil }
        return (
            DJIATResponseParser.snapshot(from: result.output),
            DJIATResponseParser.iccid(from: result.output)
        )
    }

    private func captureDJIDataSessionState() async -> Bool {
        guard let live = await readDJIModemState() else { return false }
        djiSnapshot = live.snapshot
        djiHostNetwork = await djiHostNetworkClient.snapshot()
        lastUpdated = Date()
        return live.snapshot.hasDataSession
    }

    private func pauseDJIDataSessionIfNeeded(_ shouldPause: Bool) async -> Bool {
        guard shouldPause else { return true }

        _ = await djiATClient.run(["raw", "AT+QLWWANDOWN=1,\"IP\""])
        for _ in 0..<12 {
            let status = await djiATClient.run(["raw", "AT+QLWWANSTATUS=1"])
            if DJIATResponseParser.wwanAddress(from: status.output) == nil {
                djiSnapshot.pdpAddress = "Unavailable"
                lastUpdated = Date()
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func startDJIDataSession(forceECM: Bool) async -> (ready: Bool, dnsConfigured: Bool) {
        if forceECM, !(await applyDJIUSBMode(.ecm)) {
            return (false, false)
        }

        _ = await djiATClient.run(["raw", "AT+QLWWANUP=1,\"IP\",1"])

        for _ in 0..<25 {
            let wwan = await djiATClient.run(["raw", "AT+QLWWANSTATUS=1"])
            djiSnapshot.pdpAddress = DJIATResponseParser.wwanAddress(from: wwan.output) ?? "Unavailable"
            djiHostNetwork = await djiHostNetworkClient.snapshot()
            let hostRequired = forceECM || djiSnapshot.usbModeCode == DJIUSBMode.ecm.rawValue
            if djiSnapshot.hasDataSession && (!hostRequired || djiHostNetwork.isReady) {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }

        if let live = await readDJIModemState() {
            djiSnapshot = live.snapshot
        }
        djiHostNetwork = await djiHostNetworkClient.snapshot()

        var dnsConfigured = false
        if djiSnapshot.usbModeCode == DJIUSBMode.ecm.rawValue,
           djiHostNetwork.interfaceName != "Unavailable" {
            let dnsResult = await djiHostNetworkClient.configureTrustedDNS()
            dnsConfigured = dnsResult.exitCode == 0
            djiHostNetwork = await djiHostNetworkClient.snapshot()
        }

        lastUpdated = Date()
        let hostRequired = forceECM || djiSnapshot.usbModeCode == DJIUSBMode.ecm.rawValue
        return (djiSnapshot.hasDataSession && (!hostRequired || djiHostNetwork.isReady), dnsConfigured)
    }

    func scanDJINeighborCells() {
        guard !djiNeighborScanInFlight, !djiProfileInFlight, !djiNetworkInFlight else { return }
        Task {
            djiNeighborScanInFlight = true
            defer { djiNeighborScanInFlight = false }
            let result = await djiATClient.run(["neighbors"])
            if result.exitCode == 0 {
                djiNeighborCells = DJIATResponseParser.neighborCells(from: result.output)
                djiLog = "Found \(djiNeighborCells.count) neighboring cells."
            } else {
                djiLog = SensitiveLogRedactor.redact(result.output)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lastUpdated = Date()
        }
    }

    func scanDJIOperators() {
        guard !djiOperatorScanInFlight, !djiProfileInFlight, !djiNetworkInFlight else { return }
        Task {
            djiOperatorScanInFlight = true
            djiLog = "Scanning visible operators. This can take up to three minutes."
            defer { djiOperatorScanInFlight = false }
            let result = await djiATClient.run(["operators"])
            if result.exitCode == 0 {
                djiOperators = DJIATResponseParser.operators(from: result.output)
                djiLog = "Found \(djiOperators.count) visible operator entries."
            } else {
                djiLog = SensitiveLogRedactor.redact(result.output)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            lastUpdated = Date()
        }
    }

    func refreshDJIProfiles() async {
        guard !djiProfileInFlight, !djiNetworkInFlight else { return }
        djiProfileInFlight = true
        defer { djiProfileInFlight = false }
        while djiStatusInFlight {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let shouldRestoreData = await captureDJIDataSessionState()
        guard await pauseDJIDataSessionIfNeeded(shouldRestoreData) else {
            if shouldRestoreData {
                _ = await startDJIDataSession(forceECM: false)
            }
            djiLog = "Unable to pause cellular data before reading eSIM profiles."
            return
        }
        let loaded = await loadDJIProfiles(maxAttempts: 3)
        if shouldRestoreData {
            let restored = await startDJIDataSession(forceECM: false)
            if loaded, !restored.ready {
                djiLog = "Profiles refreshed, but the previous cellular data session could not be restored."
            }
        }
    }

    func switchDJIProfile(_ profile: Profile) {
        guard !profile.iccid.isEmpty, !profile.isEnabled, !djiProfileInFlight,
              !djiNetworkInFlight else { return }
        djiProfileInFlight = true
        Task {
            defer { djiProfileInFlight = false }
            while djiStatusInFlight {
                try? await Task.sleep(for: .milliseconds(100))
            }
            djiLog = "Switching eSIM to \(profile.title)..."
            let shouldRestoreData = await captureDJIDataSessionState()
            guard await pauseDJIDataSessionIfNeeded(shouldRestoreData) else {
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "Unable to pause cellular data before switching eSIM profiles."
                return
            }

            let enableResult = await enableDJIProfileWithRetry(profile)
            guard enableResult.succeeded else {
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "eSIM switch failed: \(enableResult.message)"
                return
            }

            let reboot = await djiATClient.run(["raw", "AT+CFUN=1,1"], timeout: 10)
            guard reboot.exitCode == 0 else {
                _ = await loadDJIProfiles(maxAttempts: 5)
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "Profile changed, but the modem refresh failed. Reconnect the module to apply it."
                return
            }

            djiLog = "Profile written. Waiting for the physical ICCID to change..."
            var physicalProfileConfirmed = false
            for _ in 0..<45 {
                try? await Task.sleep(for: .seconds(1))
                let iccidResult = await djiATClient.run(["raw", "AT+QCCID"], timeout: 4)
                if DJIATResponseParser.iccid(from: iccidResult.output) == profile.iccid {
                    physicalProfileConfirmed = true
                    break
                }
            }

            guard physicalProfileConfirmed else {
                _ = await loadDJIProfiles(maxAttempts: 5)
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "The modem restarted, but its physical ICCID did not change to \(profile.title)."
                return
            }

            if let live = await readDJIModemState() {
                djiSnapshot = live.snapshot
                djiHostNetwork = await djiHostNetworkClient.snapshot()
                lastUpdated = Date()
            }

            let loaded = await loadDJIProfiles(maxAttempts: 10)
            let profileListConfirmed = loaded && djiProfiles.contains {
                $0.iccid == profile.iccid && $0.isEnabled
            }
            guard profileListConfirmed else {
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "The physical SIM changed, but eSTK did not confirm \(profile.title) as enabled."
                return
            }

            if shouldRestoreData {
                let restored = await startDJIDataSession(forceECM: false)
                if restored.ready {
                    djiLog = "Active eSIM: \(profile.title). Cellular data restored."
                } else {
                    djiLog = "Active eSIM: \(profile.title), but the previous cellular data session could not be restored."
                }
            } else {
                djiLog = "Active eSIM: \(profile.title)."
            }
        }
    }

    private func enableDJIProfileWithRetry(
        _ profile: Profile,
        maxAttempts: Int = 3
    ) async -> (succeeded: Bool, message: String) {
        var lastFailure = "Unknown lpac error"
        let identifiers = profile.isdpAid.isEmpty
            ? [profile.iccid]
            : [profile.iccid, profile.isdpAid]
        for attempt in 0..<max(1, maxAttempts) {
            let identifier = identifiers[attempt % identifiers.count]
            let result = await djiLPACClient.run(["profile", "enable", identifier, "1"])
            let commandResult = DJILPACResponseParser.result(from: result.output)
            if result.exitCode == 0, commandResult?.code == 0 {
                return (true, "success")
            }

            lastFailure = SensitiveLogRedactor.redact(commandResult?.message ?? result.output)

            let physicalICCID = await djiATClient.run(["raw", "AT+QCCID"], timeout: 4)
            if DJIATResponseParser.iccid(from: physicalICCID.output) == profile.iccid {
                return (true, "already active")
            }

            let hasAnotherAttempt = attempt + 1 < maxAttempts
            if hasAnotherAttempt {
                djiLog = "eSTK is busy. Cooling down before retry \(attempt + 2)/\(maxAttempts)..."
            }
            try? await Task.sleep(for: .seconds(8))

            if await loadDJIProfiles(),
               djiProfiles.contains(where: { $0.iccid == profile.iccid && $0.isEnabled }) {
                return (true, "enabled")
            }

            if hasAnotherAttempt {
                djiLog = "Retrying \(profile.title) (\(attempt + 2)/\(maxAttempts))..."
            }
        }
        return (false, lastFailure)
    }

    func renameDJIProfile(_ profile: Profile, nickname: String) {
        guard !profile.iccid.isEmpty, !djiProfileInFlight, !djiNetworkInFlight else { return }
        djiProfileInFlight = true
        Task {
            defer { djiProfileInFlight = false }
            while djiStatusInFlight {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let shouldRestoreData = await captureDJIDataSessionState()
            guard await pauseDJIDataSessionIfNeeded(shouldRestoreData) else {
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "Unable to pause cellular data before updating the eSIM remark."
                return
            }

            let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            var arguments = ["profile", "nickname", profile.iccid]
            if !clean.isEmpty { arguments.append(clean) }
            let result = await djiLPACClient.run(arguments)
            guard
                result.exitCode == 0,
                DJILPACResponseParser.result(from: result.output)?.code == 0
            else {
                let message = SensitiveLogRedactor.redact(
                    DJILPACResponseParser.result(from: result.output)?.message ?? result.output
                )
                if shouldRestoreData {
                    _ = await startDJIDataSession(forceECM: false)
                }
                djiLog = "Unable to update the eSIM remark: \(message)"
                return
            }

            let loaded = await loadDJIProfiles(maxAttempts: 5)
            let restored = shouldRestoreData
                ? await startDJIDataSession(forceECM: false).ready
                : true
            if loaded, restored {
                djiLog = clean.isEmpty ? "eSIM remark cleared." : "eSIM remark saved as \(clean)."
            } else if loaded {
                djiLog = "eSIM remark saved, but the previous cellular data session could not be restored."
            }
        }
    }

    private func loadDJIProfiles(maxAttempts: Int = 1) async -> Bool {
        var lastFailure = "Unknown lpac error"
        for attempt in 0..<max(1, maxAttempts) {
            let result = await djiLPACClient.run(["profile", "list"])
            let commandResult = DJILPACResponseParser.result(from: result.output)
            if result.exitCode == 0, commandResult?.code == 0 {
                djiProfiles = DJILPACResponseParser.profiles(from: result.output)
                lastUpdated = Date()
                return true
            }
            lastFailure = SensitiveLogRedactor.redact(commandResult?.message ?? result.output)
            if attempt + 1 < maxAttempts {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        djiLog = "Unable to read eSIM profiles: \(lastFailure)"
        return false
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
        guard remotes.count > 1, !selectedRemote.isLocal, let selectedRemoteID else { return }
        remotes.removeAll { $0.id == selectedRemoteID }
        defaults.removeObject(forKey: DeviceSelectionStore.key(for: selectedRemoteID))
        persistRemotes()
        self.selectedRemoteID = remotes.first?.id
        selectedDeviceSerial = savedSelectedDeviceSerial(allowLegacy: false)
        devices = []
        profiles = []
        messages = []
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

        let jsonResult = await run(["profiles-json"], busyMessage: "Reading EasyEUICC profiles...")
        if jsonResult.exitCode == 0 {
            let parsedProfiles = R6CLineParser.profilesJSON(jsonResult.output)
            if !parsedProfiles.isEmpty {
                profiles = parsedProfiles
                appendLog(R6CLineParser.profileLogLines(parsedProfiles))
                lastUpdated = Date()
                return
            }
        }

        let result = await run(["profiles"], busy: false)
        if result.exitCode == 0 {
            profiles = parseProfiles(result.output)
        }
        appendLog(result.output)
        lastUpdated = Date()
    }

    func refreshMessages() async {
        guard !messagesInFlight else { return }
        messagesInFlight = true
        defer { messagesInFlight = false }

        let result = await run(["messages", "20"], busyMessage: "Reading phone messages...")
        if result.exitCode == 0 {
            messages = R6CLineParser.messages(result.output)
            appendLog("Loaded \(messages.count) messages.")
            lastUpdated = Date()
        }
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

    func decodeQRCodeImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = CIImage(contentsOf: url) else {
            appendLog("ERROR failed to open QR image.")
            return
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let payload = detector?.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
        guard let payload, !payload.isEmpty else {
            appendLog("ERROR no QR code found in image.")
            return
        }
        downloadInput = payload
        appendLog("OK decoded QR payload.")
    }

    func downloadDryRun() {
        let activation = downloadInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activation.isEmpty else {
            appendLog("ERROR missing eSIM activation code or QR payload.")
            return
        }
        Task {
            let result = await run(["download-dry-run", activation], busyMessage: "Checking eSIM activation code...")
            appendLog(result.output)
        }
    }

    func downloadProfile() {
        let activation = downloadInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activation.isEmpty else {
            appendLog("ERROR missing eSIM activation code or QR payload.")
            return
        }
        Task {
            let result = await run(["download", activation], busyMessage: "Downloading eSIM profile...")
            appendLog(result.output)
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
            if result.exitCode == 0 {
                updateTouchScreenPixels(from: result.output)
                fastDisplayMode = true
            }
        }
    }

    func resetDisplay() {
        Task {
            let result = await run(["display", "reset"], busyMessage: "Restoring display mode...")
            appendLog(result.output)
            if result.exitCode == 0 {
                updateTouchScreenPixels(from: result.output)
                fastDisplayMode = false
            }
        }
    }

    private func updateTouchScreenPixels(from output: String) {
        if let size = R6CLineParser.physicalDisplaySize(output) {
            touchScreenPixels = size
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

    func setNetwork(_ target: String, enabled: Bool) {
        let mode = enabled ? "on" : "off"
        Task {
            let result = await run(["net", target, mode], busyMessage: "Setting \(target) \(mode)...")
            appendLog(result.output)
            parseStatus(result.output)
            await refreshStatus()
        }
    }

    func runShellCommand() {
        runShellCommand(arguments: ["shell"], message: "Running adb shell...")
    }

    func runKaliShellCommand() {
        runShellCommand(arguments: ["kali-shell"], message: "Running Kali shell...")
    }

    private func runShellCommand(arguments: [String], message: String) {
        let command = shellInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        Task {
            let result = await run(arguments + [command], busyMessage: message)
            appendLog(result.output)
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
            "R6C_H264_STREAM_BITRATE": fastDisplayMode ? "4M" : "8M"
        ]
        if fastDisplayMode {
            env["R6C_STREAM_SIZE"] = "540x1170"
            env["R6C_H264_STREAM_SIZE"] = "540x1170"
        }
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
            case "battery": batteryState = value
            case "network": networkState = value
            case "carrier": carrierState = value
            case "mobile_data": mobileDataState = value
            case "wifi": wifiState = value
            case "bluetooth": bluetoothState = value
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
        let clean = SensitiveLogRedactor.redact(text.isEmpty ? "(no output)" : text)
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

    static let messageTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
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
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    if !didRequestInitialRefresh {
                        didRequestInitialRefresh = true
                        await model.stopAllInputRelays()
                        model.refreshAll()
                    }
                    var ticks = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if model.selectedDeviceKind == .dji4G {
                            await model.refreshDJIStatus()
                        } else {
                            await model.refreshStatus()
                        }
                        ticks += 1
                        if ticks % 3 == 0 {
                            await model.refreshDevices()
                            await model.detectDJI4G()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopInputRelayNow()
                    model.stopNativeStreamNow()
                    model.stopScreenStreamNow()
                }
        }
        .defaultSize(width: 1440, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsRemoteEditor = false

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                controlColumn
                Divider()
                detailColumn
            }
            .padding(.top, 10)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: 20) {
                    remoteSection
                    deviceSection
                    if model.selectedDeviceKind == .android {
                        messageSection
                        downloadSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }

            footerView
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 360)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Connection")
                Spacer()
                Button {
                    showsRemoteEditor.toggle()
                } label: {
                    Image(systemName: showsRemoteEditor ? "xmark" : "plus")
                }
                .buttonStyle(.borderless)
                .help(showsRemoteEditor ? "Close remote editor" : "Add an r6c remote")
            }

            HStack(spacing: 10) {
                Image(systemName: model.selectedRemote.isLocal ? "cable.connector" : "network")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedRemote.connectionLabel)
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.selectedRemote.connectionDetail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Menu {
                    ForEach(model.remotes) { remote in
                        Button(remote.connectionLabel) {
                            model.selectRemote(remote)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 7))

            if showsRemoteEditor {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Name", text: $model.newRemoteName)
                        TextField("Port", text: $model.newRemotePort)
                            .frame(width: 58)
                    }
                    HStack(spacing: 8) {
                        TextField("IP or user@host", text: $model.newRemoteHost)
                        Button("Add", action: model.addRemote)
                            .disabled(model.remoteDraftError != nil)
                    }
                    if let error = model.remoteDraftError, !model.newRemoteHost.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            if !model.selectedRemote.isLocal {
                Button(role: .destructive, action: { model.removeSelectedRemote() }) {
                    Label("Remove remote", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Managed Devices")
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
                                let isSelected = model.selectedDeviceKind == .android && device.serial == model.selectedDeviceSerial
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .green : .secondary)
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
                        .background(model.selectedDeviceKind == .android && device.serial == model.selectedDeviceSerial ? Color.accentColor.opacity(0.08) : Color.clear)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                    }
                }
            }

            Divider()
                .padding(.vertical, 2)

            Button {
                model.selectDJI4G()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 24)
                        .foregroundColor(model.djiSnapshot.isConnected ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DJI IG830 4G")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Local USB  2ca3:4006")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(model.djiSnapshot.isConnected ? "Connected" : "Offline")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((model.djiSnapshot.isConnected ? Color.green : Color.secondary).opacity(0.16))
                        .foregroundColor(model.djiSnapshot.isConnected ? .green : .secondary)
                        .cornerRadius(4)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(model.selectedDeviceKind == .dji4G ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var deviceCountText: String {
        let ready = model.devices.filter(\.isReady).count
        return "\(ready)/\(model.devices.count) Android"
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Messages")
                if !model.messages.isEmpty {
                    Text("\(model.messages.count)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { Task { await model.refreshMessages() } }) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if model.messages.isEmpty {
                Text("No messages loaded.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message)
                    }
                }
            }
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var detailColumn: some View {
        GeometryReader { proxy in
            let phoneMaxHeight = min(max(proxy.size.height - 90, 420), 860)
            let phoneMaxWidth = max(proxy.size.width - 56, 180)

            VStack(spacing: 0) {
                if model.selectedDeviceKind == .dji4G {
                    DJI4GPanel()
                        .environmentObject(model)
                } else {
                    PhoneScreenPanel(
                        phoneMaxSize: CGSize(width: phoneMaxWidth, height: phoneMaxHeight),
                        availableWidth: max(proxy.size.width - 16, 0)
                    )
                        .environmentObject(model)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("R6C Phone Control")
                    .font(.system(size: 18, weight: .bold))
                Text(model.selectedRemote.isLocal ? "Local USB device management" : "Remote Android management")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { model.refreshAll() }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
            .help("Refresh all devices")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: 64)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
        .border(Color(NSColor.separatorColor), edges: [.bottom])
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("eSIM Download")

            TextField("LPA link or QR payload", text: $model.downloadInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(action: model.decodeQRCodeImage) {
                    Label("QR Image", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)

                Button(action: model.downloadDryRun) {
                    Label("Dry Run", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.downloadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: model.downloadProfile) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.downloadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.bottom, 4)
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
            Text(model.selectedRemote.connectionDetail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .border(Color(NSColor.separatorColor), edges: [.top])
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
    let availableWidth: CGFloat

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
    private let phonePanelGap: CGFloat = 14
    private let targetStatusPanelWidth: CGFloat = 172
    private let minStatusPanelWidth: CGFloat = 132
    private let targetConsolePanelWidth: CGFloat = 360
    private let minConsolePanelWidth: CGFloat = 220
    private let maxSidePanelWidth: CGFloat = 620
    private let sidePanelGap: CGFloat = 12
    private let minPhoneWidth: CGFloat = 180
    private var minSidePanelWidth: CGFloat { minStatusPanelWidth + sidePanelGap + minConsolePanelWidth }
    private var targetSidePanelWidth: CGFloat { targetStatusPanelWidth + sidePanelGap + targetConsolePanelWidth }
    private var touchPixels: CGSize {
        ScreenCoordinateMapper.touchSize(for: screenPixels, deviceSize: model.touchScreenPixels)
    }

    private var deviceName: String {
        let modelName = model.selectedAndroidDevice?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return modelName.isEmpty ? "Android Device" : modelName.replacingOccurrences(of: "_", with: " ")
    }

    private var deviceConnectionDetail: String {
        let source = model.selectedRemote.isLocal ? "Local USB" : model.selectedRemote.name
        let serial = model.selectedDeviceSerial.isEmpty ? "detecting device" : model.selectedDeviceSerial
        return "\(source)  ·  \(serial)  ·  H.264 \(Int(screenPixels.width))×\(Int(screenPixels.height))"
    }

    var body: some View {
        let innerWidth = max(availableWidth - 28, 0)
        let desiredSidePanelWidth = min(maxSidePanelWidth, max(targetSidePanelWidth, innerWidth * 0.42))
        let sidePanelWidth = min(desiredSidePanelWidth, max(0, innerWidth - phonePanelGap - minPhoneWidth))
        let phoneStageWidth = max(0, innerWidth - sidePanelWidth - phonePanelGap)
        let fittedPhoneSize = ScreenFit.size(
            for: screenPixels,
            in: CGSize(width: phoneStageWidth, height: phoneMaxSize.height)
        )
        let contentWidth = phoneStageWidth + phonePanelGap + sidePanelWidth
        let pickerWidth = min(340, max(220, sidePanelWidth * 0.58))

        return VStack(alignment: .leading, spacing: 12) {
            panelHeader(pickerWidth: pickerWidth)

            HStack(alignment: .top, spacing: phonePanelGap) {
                ZStack {
                    embeddedScreen(maxSize: fittedPhoneSize)
                }
                .frame(width: phoneStageWidth, height: phoneMaxSize.height, alignment: .center)

                phoneSidePanel(width: sidePanelWidth)
            }
            .frame(width: contentWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: contentWidth + 28, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.34))
        .onAppear {
            model.stopScreenStream()
        }
    }

    private func panelHeader(pickerWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.selectedRemote.isLocal ? "cable.connector" : "network")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(model.adbIsConnected ? .green : .orange)
                .frame(width: 34, height: 34)
                .background(
                    (model.adbIsConnected ? Color.green : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(deviceName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(deviceConnectionDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            ESIMProfilePicker()
                .environmentObject(model)
                .frame(width: pickerWidth)
        }
        .frame(height: 46)
    }

    private func phoneSidePanel(width: CGFloat) -> some View {
        let statusPanelWidth = min(width, min(targetStatusPanelWidth, max(minStatusPanelWidth, width * 0.32)))
        let remainingWidth = max(0, width - statusPanelWidth)
        let columnGap = remainingWidth > sidePanelGap ? sidePanelGap : 0
        let consolePanelWidth = max(0, remainingWidth - columnGap)

        return HStack(alignment: .top, spacing: columnGap) {
            statusColumn
                .frame(width: statusPanelWidth)
            consoleColumn
                .frame(width: consolePanelWidth)
        }
        .frame(width: width, height: phoneMaxSize.height, alignment: .topLeading)
    }

    private var statusColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                StatusChip(title: "ADB", value: model.adbState, isGood: model.adbState == "connected")
                StatusChip(title: "stream", value: h264StreamReady ? "h264" : "starting", isGood: h264StreamReady)
                StatusChip(title: "device", value: model.selectedDeviceSerial.isEmpty ? "auto" : model.selectedDeviceSerial, isGood: model.adbState == "connected")
                StatusChip(title: "battery", value: model.batteryState, isGood: !model.batteryState.contains("unknown"))
                StatusChip(title: "carrier", value: model.carrierState, isGood: !model.carrierState.contains("unknown"))
                StatusChip(title: "network", value: model.networkState, isGood: model.networkState.contains("connected"))

                Divider()
                    .padding(.vertical, 4)

                networkControls

                if !model.adbIsConnected {
                    Button {
                        model.authorizeADB()
                    } label: {
                        Label("Authorize ADB", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help(model.selectedRemote.isLocal ? "Approve the USB debugging prompt on the phone" : "Open the ADB authorization prompt")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var consoleColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sidePanelSection("Controls") {
                VStack(alignment: .leading, spacing: 8) {
                    navigationControls
                    textInputControls
                    swipeControls
                    streamControls
                    powerControls
                }
            }

            terminalPanel
        }
        .frame(height: phoneMaxSize.height, alignment: .top)
    }

    private var terminalPanel: some View {
        sidePanelSection("Terminal", accessory: DateFormatter.logTime.string(from: model.lastUpdated)) {
            ScrollView {
                Text(model.log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )

            TextField("adb / kali command", text: $model.shellInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.runShellCommand)

            HStack(spacing: 8) {
                Button(action: model.runShellCommand) {
                    Label("ADB", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                Button(action: model.runKaliShellCommand) {
                    Label("Kali", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.shellInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidePanelSection<Content: View>(_ title: String, accessory: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let accessory {
                    Text(accessory)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            content()
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    private var navigationControls: some View {
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
    }

    private var textInputControls: some View {
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
    }

    private var swipeControls: some View {
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
    }

    private var streamControls: some View {
        VStack(spacing: 8) {
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
        }
    }

    private var powerControls: some View {
        VStack(spacing: 8) {
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
                model.fastDisplayMode ? model.resetDisplay() : model.setFastDisplay()
            } label: {
                Label(model.fastDisplayMode ? "Normal Display" : "Fast Display", systemImage: model.fastDisplayMode ? "rectangle.expand.vertical" : "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
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
                            h264StreamReady = status == "h264"
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

    private var networkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Network")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 8) {
                networkButton(title: "Data", icon: "simcard", isOn: model.mobileDataIsOn, target: "mobile")
                networkButton(title: "Wi-Fi", icon: "wifi", isOn: model.wifiIsOn, target: "wifi")
                networkButton(title: "Bluetooth", icon: "dot.radiowaves.left.and.right", isOn: model.bluetoothIsOn, target: "bluetooth")
            }
        }
    }

    private func networkButton(title: String, icon: String, isOn: Bool, target: String) -> some View {
        Button {
            model.setNetwork(target, enabled: !isOn)
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .green : .secondary)
        .help(isOn ? "Turn \(title) off" : "Turn \(title) on")
    }

    private func sendTrackpadSwipe(_ direction: TrackpadSwipeDirection) {
        let targetSize = touchPixels
        let y = targetSize.height / 2
        let startX = direction == .left ? targetSize.width * 0.75 : targetSize.width * 0.25
        let endX = direction == .left ? targetSize.width * 0.25 : targetSize.width * 0.75
        model.swipeScreen(
            from: CGPoint(x: startX, y: y),
            to: CGPoint(x: endX, y: y),
            screenSize: targetSize
        )
    }

    private func screenGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let point = mapToTouch(value.location, in: size) else { return }
                let x = Int(point.x.rounded())
                let y = Int(point.y.rounded())
                lastTouchPoint = point
                if !touchIsDown {
                    touchIsDown = true
                    lastTouchMoveDate = .distantPast
                    model.touchScreen(.down, x: x, y: y, screenSize: touchPixels)
                    return
                }
                let now = Date()
                guard now.timeIntervalSince(lastTouchMoveDate) >= 0.012 else { return }
                lastTouchMoveDate = now
                model.touchScreen(.move, x: x, y: y, screenSize: touchPixels)
            }
            .onEnded { value in
                let point = mapToTouch(value.location, in: size) ?? lastTouchPoint
                if let point {
                    let x = Int(point.x.rounded())
                    let y = Int(point.y.rounded())
                    if !touchIsDown {
                        model.touchScreen(.down, x: x, y: y, screenSize: touchPixels)
                    }
                    model.touchScreen(.up, x: x, y: y, screenSize: touchPixels)
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
        let targetSize = touchPixels
        let x = targetSize.width / 2
        let top = targetSize.height * 0.25
        let bottom = targetSize.height * 0.75
        model.swipeScreen(
            from: CGPoint(x: x, y: up ? bottom : top),
            to: CGPoint(x: x, y: up ? top : bottom),
            screenSize: targetSize
        )
    }

    private func restartNativeStream() {
        h264StreamReady = false
        screenLabel = "h264 restarting"
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

    private func mapToTouch(_ point: CGPoint, in container: CGSize) -> CGPoint? {
        guard let videoPoint = mapToPhone(point, in: container) else { return nil }
        return ScreenCoordinateMapper.mapPoint(videoPoint, from: screenPixels, to: model.touchScreenPixels)
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

struct ESIMProfilePicker: View {
    @EnvironmentObject private var model: AppModel

    private var activeProfile: Profile? {
        model.activeProfile
    }

    private var detailText: String {
        guard let profile = activeProfile else {
            return model.profiles.isEmpty ? "Refresh profiles" : "\(model.profiles.count) profiles"
        }
        let provider = profile.provider.isEmpty ? "Unknown provider" : profile.provider
        return "\(provider) - \(profile.state) - \(model.profiles.count) profiles"
    }

    var body: some View {
        Menu {
            if model.profiles.isEmpty {
                Button {
                    Task { await model.refreshProfiles() }
                } label: {
                    Label("Refresh Profiles", systemImage: "arrow.clockwise")
                }
            } else {
                ForEach(model.profiles) { profile in
                    let isAmbiguous = model.ambiguousProfileKeys.contains(profile.identityKey)
                    Button {
                        model.switchProfile(profile)
                    } label: {
                        Label(
                            isAmbiguous ? "\(profile.title) (duplicate)" : profile.title,
                            systemImage: profile.isEnabled ? "checkmark.circle.fill" : "simcard"
                        )
                    }
                    .disabled(profile.isEnabled || isAmbiguous)
                }

                Divider()

                Button {
                    Task { await model.refreshProfiles() }
                } label: {
                    Label("Refresh Profiles", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "simcard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(activeProfile?.name ?? "No eSIM")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Switch eSIM profile")
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
                    .lineLimit(2)
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

struct MessageRow: View {
    let message: PhoneMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(message.address.isEmpty ? "Unknown" : message.address)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(message.typeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if let date = message.date {
                    Text(DateFormatter.messageTime.string(from: date))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(message.body.isEmpty ? "(empty)" : message.body)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(8)
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
