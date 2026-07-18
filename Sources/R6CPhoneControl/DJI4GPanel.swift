import AppKit
import SwiftUI

struct DJI4GPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsNicknameEditor = false
    @State private var nicknameDraft = ""

    private var snapshot: DJI4GSnapshot { model.djiSnapshot }

    var body: some View {
        GeometryReader { proxy in
            let innerWidth = max(proxy.size.width - 28, 0)
            let usesCompactLayout = proxy.size.width < 840
            let inspectorWidth = min(430, max(320, innerWidth * 0.40))
            let modelWidth = max(320, innerWidth - inspectorWidth - 14)

            VStack(alignment: .leading, spacing: 12) {
                header

                if usesCompactLayout {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            modelStage
                                .frame(height: min(max(proxy.size.width * 0.58, 300), 460))
                            inspectorContent
                        }
                        .padding(.trailing, 6)
                    }
                    .scrollIndicators(.visible)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        modelStage
                            .frame(width: modelWidth)
                            .frame(maxHeight: .infinity)

                        ScrollView {
                            inspectorContent
                                .padding(.trailing, 6)
                        }
                        .scrollIndicators(.visible)
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.34))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(connectionColor)
                .frame(width: 34, height: 34)
                .background(connectionColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text("DJI IG830 Cellular Module")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(snapshot.manufacturer) \(snapshot.model)  ·  USB 2ca3:4006")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                Text(snapshot.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 7))

            Button {
                Task { await model.refreshDJIStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.djiStatusInFlight || model.djiProfileInFlight)
            .help("Refresh DJI status")
        }
        .frame(height: 46)
    }

    private var modelStage: some View {
        ZStack(alignment: .bottomLeading) {
            DJIModelView(snapshot: snapshot)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.displayName)
                        .font(.system(size: 18, weight: .semibold))
                    Text("52.4 × 23 × 8 mm")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                SignalBars(level: snapshot.signalBars, color: signalColor)
                Text(snapshot.signalLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(signalColor)
            }
            .padding(16)
            .background(Color.black.opacity(0.54))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            inspectorSection("eSIM Profiles") {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(model.djiProfiles) { profile in
                            Button {
                                model.switchDJIProfile(profile)
                            } label: {
                                Label(profile.title, systemImage: profile.isEnabled ? "checkmark.circle.fill" : "simcard")
                            }
                            .disabled(profile.isEnabled || model.djiProfileInFlight || model.djiNetworkInFlight)
                        }

                        Divider()

                        Button {
                            Task { await model.refreshDJIProfiles() }
                        } label: {
                            Label("Refresh Profiles", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "simcard")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(activeProfile?.displayName ?? "No eSIM profile")
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(profileDetail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 6)

                            if model.djiProfileInFlight {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!snapshot.isConnected || model.djiNetworkInFlight)

                    Button {
                        nicknameDraft = activeProfile?.nickname ?? ""
                        showsNicknameEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(activeProfile == nil || model.djiProfileInFlight || model.djiNetworkInFlight)
                    .help("Edit eSIM remark")
                    .popover(isPresented: $showsNicknameEditor, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("eSIM Remark")
                                .font(.headline)
                            TextField("Remark", text: $nicknameDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(saveNickname)
                            HStack {
                                Button("Cancel") { showsNicknameEditor = false }
                                Spacer()
                                Button("Save", action: saveNickname)
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(16)
                        .frame(width: 280)
                    }
                }
            }

            inspectorSection("Mac Uplink") {
                statusRow("USB Ethernet", model.djiMacUplinkIsReady ? "Connected" : snapshot.usbNetworkState, icon: "network")
                statusRow("Driver", "Native ECM", icon: "puzzlepiece.extension")
                statusRow("Interface", model.djiHostNetwork.interfaceName, icon: "cable.connector")
                statusRow("IPv4", model.djiHostNetwork.ipv4Address, icon: "number")
                statusRow("PDP", snapshot.pdpAddress, icon: "antenna.radiowaves.left.and.right")
                statusRow("DNS", dnsSummary, icon: "checkmark.shield")

                HStack(spacing: 8) {
                    Button(action: model.connectDJIToMac) {
                        Label(model.djiMacUplinkIsReady ? "Reconnect" : "Connect Mac", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: model.disconnectDJIFromMac) {
                        Image(systemName: "stop.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.bordered)
                    .help("Stop the cellular data session")
                }
                .disabled(!snapshot.isConnected || model.djiNetworkInFlight || model.djiProfileInFlight)

                Menu {
                    ForEach(DJIUSBMode.allCases) { mode in
                        Button {
                            model.setDJIUSBMode(mode)
                        } label: {
                            if snapshot.usbModeCode == mode.rawValue {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    Label("USB Mode · \(snapshot.usbMode)", systemImage: "switch.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!snapshot.isConnected || model.djiNetworkInFlight || model.djiProfileInFlight)

                if model.djiNetworkInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }

            inspectorSection("Connection") {
                statusRow("Registration", snapshot.registration.rawValue, icon: "network")
                statusRow("Operator", snapshot.operatorName, icon: "building.2")
                statusRow("SIM", snapshot.simState.rawValue, icon: "simcard")
                statusRow("Modeled LED", snapshot.statusIndicator.displayName, icon: "lightbulb")
                statusRow("LED config", snapshot.ledMode, icon: "slider.horizontal.3")
                statusRow("ICCID", snapshot.maskedICCID, icon: "number")
            }

            inspectorSection("Voice") {
                statusRow("Phone number", snapshot.phoneNumber ?? "Not provisioned", icon: "phone")
                statusRow("IMS", snapshot.imsState, icon: "wave.3.right")
                statusRow("VoLTE", snapshot.volteState, icon: "phone.connection")
                statusRow("Call control", snapshot.callControlState, icon: "dial.low")
            }

                inspectorSection("Radio") {
                    compactGrid([
                        ("RAT", snapshot.radioAccessTechnology),
                        ("Band", snapshot.band),
                        ("Duplex", snapshot.duplexMode),
                        ("MCC-MNC", snapshot.mccMnc),
                        ("EARFCN", optionalInt(snapshot.earfcn)),
                        ("USB", snapshot.usbMode)
                    ])
                }

                inspectorSection("Serving Cell") {
                    compactGrid([
                        ("Cell ID", snapshot.cellID),
                        ("PCI", optionalInt(snapshot.pci)),
                        ("TAC", snapshot.tac),
                        ("CSQ", optionalInt(snapshot.csq))
                    ])
                }

                inspectorSection("Signal") {
                    compactGrid([
                        ("RSRP", metric(snapshot.rsrp, unit: "dBm")),
                        ("RSRQ", metric(snapshot.rsrq, unit: "dB")),
                        ("RSSI", metric(snapshot.rssi, unit: "dBm")),
                        ("SINR", metric(snapshot.sinr, unit: "dB"))
                    ])
                }

                inspectorSection("Discovery") {
                    HStack(spacing: 8) {
                        Button(action: model.scanDJINeighborCells) {
                            Label("Cells", systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        Button(action: model.scanDJIOperators) {
                            Label("Operators", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !snapshot.isConnected || model.djiProfileInFlight || model.djiNetworkInFlight ||
                            model.djiNeighborScanInFlight || model.djiOperatorScanInFlight
                    )

                    if model.djiNeighborScanInFlight || model.djiOperatorScanInFlight {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(model.djiNeighborCells.prefix(8)) { cell in
                        HStack(spacing: 8) {
                            Text(cell.kind.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: 38, alignment: .leading)
                            Text("PCI \(optionalInt(cell.pci))")
                            Text("EARFCN \(optionalInt(cell.earfcn))")
                            Spacer()
                            Text(metric(cell.rsrp, unit: "dBm"))
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }

                    ForEach(model.djiOperators.prefix(8)) { network in
                        HStack(spacing: 8) {
                            Text(network.shortName.isEmpty ? network.longName : network.shortName)
                                .lineLimit(1)
                            Spacer()
                            Text(network.numeric)
                                .font(.system(size: 10, design: .monospaced))
                            Text(network.technologyLabel)
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 11))
                    }
                }

                inspectorSection("Hardware") {
                    statusRow("Firmware", snapshot.firmware, icon: "memorychip")
                    statusRow("AT transport", "USB interface 3", icon: "cable.connector")
                }

                inspectorSection("Activity") {
                    Text(model.djiLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func statusRow(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
    }

    private func compactGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(item.1)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.66), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var connectionColor: Color {
        snapshot.isConnected ? .green : .secondary
    }

    private var signalColor: Color {
        switch snapshot.signalBars {
        case 4: return .green
        case 2...3: return .yellow
        default: return .red
        }
    }

    private var activeProfile: Profile? {
        model.djiProfiles.first(where: \.isEnabled)
    }

    private var profileDetail: String {
        guard let activeProfile else {
            return model.djiProfiles.isEmpty ? "No profiles loaded" : "\(model.djiProfiles.count) profiles"
        }
        let provider = activeProfile.provider.isEmpty ? "Unknown provider" : activeProfile.provider
        return "\(provider) · \(model.djiProfiles.count) profiles"
    }

    private var dnsSummary: String {
        model.djiHostNetwork.dnsServers.isEmpty
            ? "System default"
            : model.djiHostNetwork.dnsServers.joined(separator: " · ")
    }

    private func saveNickname() {
        guard let activeProfile else { return }
        model.renameDJIProfile(activeProfile, nickname: nicknameDraft)
        showsNicknameEditor = false
    }

    private func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func metric(_ value: Int?, unit: String) -> String {
        value.map { "\($0) \(unit)" } ?? "—"
    }
}

private struct SignalBars: View {
    let level: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < level ? color : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .frame(width: 20, height: 16, alignment: .bottomLeading)
    }
}
