import Darwin
import Foundation

enum DJISIMState: String, Equatable {
    case ready = "Ready"
    case locked = "Locked"
    case missing = "No SIM"
    case unknown = "Unknown"
}

enum DJIRegistrationState: String, Equatable {
    case home = "Registered"
    case roaming = "Roaming"
    case searching = "Searching"
    case denied = "Denied"
    case notRegistered = "Not registered"
    case unknown = "Unknown"

    var isRegistered: Bool {
        self == .home || self == .roaming
    }
}

enum DJIUSBMode: Int, CaseIterable, Identifiable {
    case rmnet = 0
    case ecm = 1
    case mbim = 2
    case rndis = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .rmnet: return "RmNet"
        case .ecm: return "ECM"
        case .mbim: return "MBIM"
        case .rndis: return "RNDIS"
        }
    }
}

enum DJIStatusIndicatorColor: String, Equatable {
    case off
    case green
    case blue
    case red
}

enum DJIStatusIndicatorBehavior: String, Equatable {
    case off
    case steady
    case flashing
}

struct DJIStatusIndicator: Equatable {
    let color: DJIStatusIndicatorColor
    let behavior: DJIStatusIndicatorBehavior

    static let off = DJIStatusIndicator(color: .off, behavior: .off)

    var displayName: String {
        switch (color, behavior) {
        case (.green, .steady): return "Green steady · 4G strong"
        case (.green, .flashing): return "Green flashing · 4G weak"
        case (.blue, .steady): return "Blue steady · 2G/3G strong"
        case (.blue, .flashing): return "Blue flashing · 2G/3G weak"
        case (.red, .steady): return "Red steady · SIM unavailable"
        case (.red, .flashing): return "Red flashing · SIM present, no network"
        default: return "Off · no live modem state"
        }
    }
}

struct DJI4GSnapshot: Equatable {
    var isConnected = false
    var manufacturer = "DJI"
    var model = "IG830"
    var firmware = "Unknown"
    var simState: DJISIMState = .unknown
    var maskedICCID = "Unavailable"
    var registration: DJIRegistrationState = .unknown
    var operatorName = "No operator"
    var radioAccessTechnology = "Unknown"
    var duplexMode = "Unknown"
    var mccMnc = "Unknown"
    var cellID = "Unknown"
    var pci: Int?
    var earfcn: Int?
    var band = "Unknown"
    var tac = "Unknown"
    var rsrp: Int?
    var rsrq: Int?
    var rssi: Int?
    var sinr: Int?
    var csq: Int?
    var usbMode = "Unknown"
    var usbModeCode: Int?
    var pdpAddress = "Unavailable"
    var usbNetworkState = "Unknown"
    var imsState = "Unknown"
    var volteState = "Unknown"
    var callControlState = "Unknown"
    var phoneNumber: String?
    var ledMode = "Unknown"
    var capturedAt = Date()

    static let disconnected = DJI4GSnapshot()

    var displayName: String {
        "DJI IG830"
    }

    var signalLabel: String {
        guard let rsrp else { return "Unavailable" }
        switch rsrp {
        case (-80)...: return "Excellent"
        case -90 ..< -80: return "Good"
        case -100 ..< -90: return "Fair"
        case -110 ..< -100: return "Weak"
        default: return "Very weak"
        }
    }

    var signalBars: Int {
        guard let rsrp else { return 0 }
        switch rsrp {
        case (-80)...: return 4
        case -90 ..< -80: return 3
        case -100 ..< -90: return 2
        case -110 ..< -100: return 1
        default: return 0
        }
    }

    var voiceReady: Bool {
        phoneNumber != nil && imsState == "Enabled" && volteState != "Disabled"
    }

    var hasDataSession: Bool {
        pdpAddress != "Unavailable" && pdpAddress != "0.0.0.0" && !pdpAddress.isEmpty
    }

    // Mirrors the DJI Cellular module's documented tri-color status indicator.
    var statusIndicator: DJIStatusIndicator {
        guard isConnected else { return .off }

        switch simState {
        case .missing, .locked:
            return DJIStatusIndicator(color: .red, behavior: .steady)
        case .unknown:
            guard registration.isRegistered else { return .off }
        case .ready:
            guard registration.isRegistered else {
                return DJIStatusIndicator(color: .red, behavior: .flashing)
            }
        }

        let color: DJIStatusIndicatorColor = isLTE ? .green : .blue
        return DJIStatusIndicator(color: color, behavior: hasStrongSignal ? .steady : .flashing)
    }

    private var isLTE: Bool {
        let rat = radioAccessTechnology.uppercased()
        return rat.contains("LTE") || rat.contains("4G")
    }

    private var hasStrongSignal: Bool {
        if let rsrp { return rsrp >= -90 }
        if let csq { return csq >= 15 }
        return false
    }
}

struct DJINeighborCell: Identifiable, Equatable {
    let id = UUID()
    let kind: String
    let radioAccessTechnology: String
    let earfcn: Int?
    let pci: Int?
    let rsrq: Int?
    let rsrp: Int?
    let rssi: Int?
    let sinr: Int?

    static func == (lhs: DJINeighborCell, rhs: DJINeighborCell) -> Bool {
        lhs.kind == rhs.kind &&
            lhs.radioAccessTechnology == rhs.radioAccessTechnology &&
            lhs.earfcn == rhs.earfcn &&
            lhs.pci == rhs.pci &&
            lhs.rsrq == rhs.rsrq &&
            lhs.rsrp == rhs.rsrp &&
            lhs.rssi == rhs.rssi &&
            lhs.sinr == rhs.sinr
    }
}

struct DJINetworkOperator: Identifiable, Equatable {
    var id: String { "\(numeric)-\(accessTechnology)" }
    let status: Int
    let longName: String
    let shortName: String
    let numeric: String
    let accessTechnology: Int

    var statusLabel: String {
        switch status {
        case 1: return "Available"
        case 2: return "Current"
        case 3: return "Forbidden"
        default: return "Unknown"
        }
    }

    var technologyLabel: String {
        switch accessTechnology {
        case 0: return "GSM"
        case 2: return "UTRAN"
        case 7: return "LTE"
        case 9: return "NB-IoT"
        default: return "Act \(accessTechnology)"
        }
    }
}

struct DJIHostNetworkSnapshot: Equatable {
    var serviceName = "Baiwang"
    var interfaceName = "Unavailable"
    var ipv4Address = "Unavailable"
    var router = "Unavailable"
    var dnsServers: [String] = []

    static let disconnected = DJIHostNetworkSnapshot()

    var isReady: Bool {
        ipv4Address != "Unavailable" && !ipv4Address.hasPrefix("169.254.") && router != "Unavailable"
    }
}

enum DJIHostNetworkParser {
    static func snapshot(hardwarePorts: String, networkInfo: String, dnsInfo: String) -> DJIHostNetworkSnapshot {
        var snapshot = DJIHostNetworkSnapshot()
        let hardwareLines = hardwarePorts.components(separatedBy: .newlines)
        for index in hardwareLines.indices {
            guard hardwareLines[index].trimmingCharacters(in: .whitespaces) == "Hardware Port: Baiwang" else {
                continue
            }
            let following = hardwareLines.index(after: index)
            if hardwareLines.indices.contains(following),
               hardwareLines[following].trimmingCharacters(in: .whitespaces).hasPrefix("Device:") {
                snapshot.interfaceName = value(afterColonIn: hardwareLines[following])
            }
            break
        }

        for line in networkInfo.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.hasPrefix("IP address:") {
                snapshot.ipv4Address = normalizedNetworkValue(value(afterColonIn: clean))
            } else if clean.hasPrefix("Router:") {
                snapshot.router = normalizedNetworkValue(value(afterColonIn: clean))
            }
        }

        snapshot.dnsServers = dnsInfo.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("aren't any DNS") }
        return snapshot
    }

    private static func value(afterColonIn line: String) -> String {
        line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func normalizedNetworkValue(_ value: String) -> String {
        value.isEmpty || value == "(null)" ? "Unavailable" : value
    }
}

enum DJILPACResponseParser {
    private struct ProfileEnvelope: Decodable {
        let payload: ProfilePayload
    }

    private struct ProfilePayload: Decodable {
        let code: Int
        let data: [RawProfile]
    }

    private struct RawProfile: Decodable {
        let iccid: String
        let isdpAid: String?
        let profileState: String
        let profileNickname: String?
        let serviceProviderName: String?
        let profileName: String?
    }

    static func profiles(from output: String) -> [Profile] {
        guard
            let data = output.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(ProfileEnvelope.self, from: data),
            envelope.payload.code == 0
        else { return [] }

        return envelope.payload.data.map { profile in
            Profile(
                name: firstNonEmpty(profile.profileName, "Unnamed profile"),
                nickname: firstNonEmpty(profile.profileNickname),
                state: profile.profileState,
                provider: profile.serviceProviderName ?? "",
                iccid: profile.iccid,
                isdpAid: profile.isdpAid ?? ""
            )
        }
    }

    static func result(from output: String) -> (code: Int, message: String)? {
        guard
            let data = output.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["payload"] as? [String: Any],
            let code = payload["code"] as? Int
        else { return nil }
        return (code, payload["message"] as? String ?? "Unknown lpac result")
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}

enum DJIATResponseParser {
    static func snapshot(from output: String) -> DJI4GSnapshot {
        let sections = sections(from: output)
        var snapshot = DJI4GSnapshot()
        snapshot.isConnected = !sections.isEmpty && !output.contains("was not found")

        parseIdentity(sections["IDENTITY"], into: &snapshot)
        parseSIM(sections: sections, into: &snapshot)
        parseOperator(sections["OPERATOR"], into: &snapshot)
        parseRegistration(sections["EPS_REGISTRATION"] ?? sections["PACKET_REGISTRATION"], into: &snapshot)
        parseSignal(sections["SIGNAL"], into: &snapshot)
        parseNetworkInfo(sections["NETWORK_INFO"], into: &snapshot)
        parseServingCell(sections["SERVING_CELL"], into: &snapshot)
        parseDataSession(sections: sections, into: &snapshot)
        parseVoiceCapability(sections: sections, into: &snapshot)
        parseLEDMode(sections["LED_MODE"], into: &snapshot)
        parseUSBMode(sections["USB_MODE"], into: &snapshot)
        return snapshot
    }

    static func commandSucceeded(_ output: String) -> Bool {
        let response = sections(from: output)["RAW"] ?? output
        let lines = response.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.contains("OK") && !lines.contains(where: {
            $0 == "ERROR" || $0.hasPrefix("+CME ERROR:") || $0.hasPrefix("+CMS ERROR:")
        })
    }

    static func wwanAddress(from output: String) -> String? {
        let content = sections(from: output)["WWAN_STATUS"]
            ?? sections(from: output)["RAW"]
            ?? output
        guard let line = responseLines(in: content, prefix: "+QLWWANSTATUS:").first else { return nil }
        let values = csvValues(afterColonIn: line)
        guard values.count > 1, values[1] != "0.0.0.0", !values[1].isEmpty else { return nil }
        return values[1]
    }

    static func iccid(from output: String) -> String? {
        let content = sections(from: output)["ICCID"]
            ?? sections(from: output)["RAW"]
            ?? output
        guard let line = responseLines(in: content, prefix: "+QCCID:").first,
              let value = line.split(separator: ":", maxSplits: 1).last else {
            return nil
        }
        return normalizedICCID(String(value))
    }

    static func neighborCells(from output: String) -> [DJINeighborCell] {
        let text = sections(from: output)["NEIGHBOR_CELLS"] ?? output
        return responseLines(in: text, prefix: "+QENG:").compactMap { line in
            let values = csvValues(afterColonIn: line)
            guard values.count >= 7, values[0].hasPrefix("neighbourcell") else { return nil }
            return DJINeighborCell(
                kind: values[0].split(separator: " ").last.map(String.init) ?? "neighbor",
                radioAccessTechnology: values[1],
                earfcn: Int(values[2]),
                pci: Int(values[3]),
                rsrq: Int(values[4]),
                rsrp: Int(values[5]),
                rssi: Int(values[6]),
                sinr: values.count > 7 ? Int(values[7]) : nil
            )
        }
    }

    static func operators(from output: String) -> [DJINetworkOperator] {
        let text = sections(from: output)["OPERATORS"] ?? output
        let pattern = #"\((\d+),\"([^\"]*)\",\"([^\"]*)\",\"(\d+)\",(\d+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 6 else { return nil }
            let values = (1..<6).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
            guard values.count == 5, let status = Int(values[0]), let act = Int(values[4]) else { return nil }
            return DJINetworkOperator(
                status: status,
                longName: values[1],
                shortName: values[2],
                numeric: values[3],
                accessTechnology: act
            )
        }
    }

    static func sections(from output: String) -> [String: String] {
        let normalized = output.replacingOccurrences(of: "\r", with: "")
        var result: [String: String] = [:]
        var activeName: String?
        var activeLines: [String] = []

        for line in normalized.components(separatedBy: .newlines) {
            if line.hasPrefix("@@BEGIN ") {
                activeName = String(line.dropFirst("@@BEGIN ".count))
                activeLines = []
            } else if line.hasPrefix("@@END ") {
                if let activeName {
                    result[activeName] = activeLines.joined(separator: "\n")
                }
                activeName = nil
                activeLines = []
            } else if activeName != nil {
                activeLines.append(line)
            }
        }
        return result
    }

    private static func parseIdentity(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let text else { return }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "ATI" && $0 != "OK" }
        if let revision = lines.first(where: { $0.hasPrefix("Revision:") }) {
            snapshot.firmware = revision.replacingOccurrences(of: "Revision:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        let identity = lines.filter { !$0.hasPrefix("Revision:") }
        if let manufacturer = identity.first { snapshot.manufacturer = manufacturer }
        if identity.count > 1 { snapshot.model = identity[1] }
    }

    private static func parseSIM(sections: [String: String], into snapshot: inout DJI4GSnapshot) {
        let pin = sections["SIM_PIN"] ?? ""
        let state = sections["SIM_STATE"] ?? ""
        if pin.localizedCaseInsensitiveContains("READY") {
            snapshot.simState = .ready
        } else if pin.localizedCaseInsensitiveContains("SIM PIN") || pin.localizedCaseInsensitiveContains("SIM PUK") {
            snapshot.simState = .locked
        } else if pin.contains("+CME ERROR: 10") || state.contains(",0") {
            snapshot.simState = .missing
        } else if state.contains(",1") {
            snapshot.simState = .ready
        }

        if let iccid = iccid(from: sections["ICCID"] ?? "") {
            snapshot.maskedICCID = maskICCID(iccid)
        }
    }

    private static func parseOperator(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = responseLines(in: text ?? "", prefix: "+COPS:").first else { return }
        let values = csvValues(afterColonIn: line)
        if values.count > 2, !values[2].isEmpty {
            snapshot.operatorName = values[2]
        }
        if values.count > 3 {
            snapshot.radioAccessTechnology = accessTechnologyName(values[3])
        }
    }

    private static func parseRegistration(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = (text ?? "").components(separatedBy: .newlines).first(where: {
            $0.contains("+CEREG:") || $0.contains("+CGREG:")
        }) else { return }
        let values = csvValues(afterColonIn: line)
        guard let codeText = values.count > 1 ? values.last : values.first, let code = Int(codeText) else { return }
        switch code {
        case 1: snapshot.registration = .home
        case 2: snapshot.registration = .searching
        case 3: snapshot.registration = .denied
        case 5: snapshot.registration = .roaming
        case 0: snapshot.registration = .notRegistered
        default: snapshot.registration = .unknown
        }
    }

    private static func parseSignal(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = responseLines(in: text ?? "", prefix: "+CSQ:").first else { return }
        let values = csvValues(afterColonIn: line)
        snapshot.csq = values.first.flatMap(Int.init)
    }

    private static func parseNetworkInfo(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = responseLines(in: text ?? "", prefix: "+QNWINFO:").first else { return }
        let values = csvValues(afterColonIn: line)
        if let access = values.first {
            snapshot.radioAccessTechnology = access.contains("LTE") ? "LTE" : access
            if access.hasPrefix("FDD") { snapshot.duplexMode = "FDD" }
            if access.hasPrefix("TDD") { snapshot.duplexMode = "TDD" }
        }
        if values.count > 1 { snapshot.mccMnc = formatMCCMNC(values[1]) }
        if values.count > 2 {
            let digits = values[2].filter(\.isNumber)
            if !digits.isEmpty { snapshot.band = "B\(digits)" }
        }
        if values.count > 3 { snapshot.earfcn = Int(values[3]) }
    }

    private static func parseServingCell(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = responseLines(in: text ?? "", prefix: "+QENG:").first(where: { $0.contains("servingcell") }) else { return }
        let values = csvValues(afterColonIn: line)
        guard values.count >= 17 else { return }
        snapshot.registration = servingState(values[1], fallback: snapshot.registration)
        snapshot.radioAccessTechnology = values[2]
        snapshot.duplexMode = values[3]
        snapshot.mccMnc = "\(values[4])-\(values[5])"
        snapshot.cellID = values[6]
        snapshot.pci = Int(values[7])
        snapshot.earfcn = Int(values[8])
        snapshot.band = "B\(values[9])"
        snapshot.tac = values[12]
        snapshot.rsrp = Int(values[13])
        snapshot.rsrq = Int(values[14])
        snapshot.rssi = Int(values[15])
        snapshot.sinr = Int(values[16])
    }

    private static func parseDataSession(sections: [String: String], into snapshot: inout DJI4GSnapshot) {
        if let line = responseLines(in: sections["PDP_ADDRESS"] ?? "", prefix: "+CGPADDR:").first {
            let values = csvValues(afterColonIn: line)
            if values.count > 1, values[1] != "0.0.0.0", !values[1].isEmpty {
                snapshot.pdpAddress = values[1]
            }
        }

        if let line = responseLines(in: sections["WWAN_STATUS"] ?? "", prefix: "+QLWWANSTATUS:").first {
            let values = csvValues(afterColonIn: line)
            if values.count > 1, values[1] != "0.0.0.0", !values[1].isEmpty {
                snapshot.pdpAddress = values[1]
            } else {
                // QLWWANSTATUS is live; CGPADDR may retain an address after the PDP session has ended.
                snapshot.pdpAddress = "Unavailable"
            }
        }

        if let line = responseLines(in: sections["NETDEV_STATUS"] ?? "", prefix: "+QNETDEVSTATUS:").first {
            let values = csvValues(afterColonIn: line)
            let state = values.count > 1 ? values[1] : ""
            switch state {
            case "2": snapshot.usbNetworkState = "Connected"
            case "1": snapshot.usbNetworkState = "Ready for DHCP"
            case "0": snapshot.usbNetworkState = "Disconnected"
            default: snapshot.usbNetworkState = "Idle"
            }
        }
    }

    private static func parseVoiceCapability(sections: [String: String], into snapshot: inout DJI4GSnapshot) {
        if let line = responseLines(in: sections["IMS_CONFIG"] ?? "", prefix: "+QCFG:").first {
            let values = csvValues(afterColonIn: line)
            if values.count > 1 {
                snapshot.imsState = values[1] == "1" ? "Enabled" : "Disabled"
            }
        }

        if let line = responseLines(in: sections["VOLTE_CONFIG"] ?? "", prefix: "+QCFG:").first {
            let values = csvValues(afterColonIn: line)
            if values.count > 1 {
                snapshot.volteState = values[1] == "0" ? "Enabled" : "Disabled"
            }
        }

        if let line = responseLines(in: sections["CALL_CONTROL"] ?? "", prefix: "+QCFG:").first {
            let values = csvValues(afterColonIn: line)
            if values.count > 1 {
                snapshot.callControlState = values.dropFirst().joined(separator: " · ")
            }
        }

        if let line = responseLines(in: sections["PHONE_NUMBER"] ?? "", prefix: "+CNUM:").first {
            let values = csvValues(afterColonIn: line)
            if values.count > 1 {
                let number = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.phoneNumber = number.isEmpty ? nil : number
            }
        }
    }

    private static func parseLEDMode(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = responseLines(in: text ?? "", prefix: "+QCFG:").first else { return }
        let values = csvValues(afterColonIn: line)
        if values.count > 1 {
            snapshot.ledMode = "Firmware mode \(values[1])"
        }
    }

    private static func parseUSBMode(_ text: String?, into snapshot: inout DJI4GSnapshot) {
        guard let line = responseLines(in: text ?? "", prefix: "+QCFG:").first else { return }
        let values = csvValues(afterColonIn: line)
        guard let code = values.last, let rawValue = Int(code) else { return }
        snapshot.usbModeCode = rawValue
        snapshot.usbMode = DJIUSBMode(rawValue: rawValue)?.displayName ?? "Mode \(rawValue)"
    }

    private static func responseLines(in text: String, prefix: String) -> [String] {
        text.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix(prefix) }
    }

    private static func csvValues(afterColonIn line: String) -> [String] {
        let payload = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? line
        return payload.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        }
    }

    private static func maskICCID(_ iccid: String) -> String {
        guard iccid.count > 12 else { return iccid }
        return "\(iccid.prefix(6))...\(iccid.suffix(6))"
    }

    private static func normalizedICCID(_ value: String) -> String? {
        var iccid = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")).uppercased()
        while iccid.hasSuffix("F") {
            iccid.removeLast()
        }
        guard iccid.count >= 10, iccid.allSatisfy({ $0.isNumber }) else { return nil }
        return iccid
    }

    private static func formatMCCMNC(_ numeric: String) -> String {
        guard numeric.count >= 5 else { return numeric }
        return "\(numeric.prefix(3))-\(numeric.dropFirst(3))"
    }

    private static func accessTechnologyName(_ code: String) -> String {
        switch code {
        case "0": return "GSM"
        case "2": return "UMTS"
        case "7": return "LTE"
        case "9": return "NB-IoT"
        default: return "Act \(code)"
        }
    }

    private static func servingState(_ state: String, fallback: DJIRegistrationState) -> DJIRegistrationState {
        switch state.uppercased() {
        case "NOCONN", "CONNECT": return fallback
        case "LIMSRV": return .searching
        case "SEARCH": return .searching
        default: return fallback
        }
    }
}

actor DJIATClient {
    let helperPath: String

    init(helperPath: String) {
        self.helperPath = helperPath
    }

    func run(_ arguments: [String], timeout: TimeInterval? = nil) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return CommandResult(exitCode: 127, output: "DJI AT helper is not installed at \(helperPath).")
        }

        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("r6c-dji-at-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return CommandResult(exitCode: 126, output: "Unable to create DJI AT output buffer.")
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DJI_AT_INTERFACE": "3"
        ]) { _, bundled in bundled }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout(for: arguments))
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            let didTimeOut = process.isRunning
            if didTimeOut {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            try? outputHandle.synchronize()
            try? outputHandle.close()
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            var output = String(data: data, encoding: .utf8) ?? ""
            if didTimeOut {
                if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
                output += "DJI AT helper timed out."
            }
            return CommandResult(
                exitCode: didTimeOut ? 124 : process.terminationStatus,
                output: output
            )
        } catch {
            return CommandResult(exitCode: 126, output: error.localizedDescription)
        }
    }

    private func defaultTimeout(for arguments: [String]) -> TimeInterval {
        switch arguments.first {
        case "operators": return 190
        case "status": return 70
        case "neighbors": return 12
        case "raw":
            return arguments.dropFirst().first == "AT+QCCID" ? 6 : 35
        default: return 8
        }
    }
}

actor DJILPACClient {
    let executablePath: String

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func run(_ arguments: [String]) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return CommandResult(exitCode: 127, output: "DJI eSIM runtime is not installed at \(executablePath).")
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment.merging([
            "LPAC_APDU": "dji_usb",
            "LPAC_HTTP": "curl",
            "DJI_AT_INTERFACE": "3"
        ]) { _, bundled in bundled }
        for key in ["ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "all_proxy", "https_proxy", "http_proxy"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                exitCode: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: 126, output: error.localizedDescription)
        }
    }
}

actor DJIHostNetworkClient {
    private let executablePath = "/usr/sbin/networksetup"
    private let serviceName = "Baiwang"

    func snapshot() -> DJIHostNetworkSnapshot {
        let ports = run(["-listallhardwareports"])
        let info = run(["-getinfo", serviceName])
        let dns = run(["-getdnsservers", serviceName])
        guard ports.exitCode == 0 else { return .disconnected }
        return DJIHostNetworkParser.snapshot(
            hardwarePorts: ports.output,
            networkInfo: info.output,
            dnsInfo: dns.output
        )
    }

    func configureTrustedDNS() -> CommandResult {
        run(["-setdnsservers", serviceName, "1.1.1.1", "8.8.8.8"])
    }

    private func run(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                exitCode: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: 126, output: error.localizedDescription)
        }
    }
}
