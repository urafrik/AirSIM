import SwiftUI

/// AirSIM 只引导安卓手机配对；不检查旧模块 USB ECM、AT 或 QDC507 固件。
struct AirSIMFirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("airsim.first-connection-complete") private var completed = false
    @AppStorage(LocalModePreference.key) private var localModeEnabled = false
    @AppStorage(CloudModePreference.key) private var cloudModeEnabled = true
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 76, height: 76)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))

                VStack(alignment: .leading, spacing: 8) {
                    Text("连接安卓手机")
                        .font(.largeTitle.bold())
                    Text("通过同一 Wi-Fi 或安卓手机热点连接；外出时可在设置中配置 frp 远程直连。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("在安卓手机启动 AirSIM 和音频桥", systemImage: "1.circle.fill")
                    Label("将两台设备连接到同一局域网", systemImage: "2.circle.fill")
                    Label("输入安卓手机显示的六位配对码", systemImage: "3.circle.fill")
                }
                .font(.body.weight(.medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                Label("配对后可接打电话、收发短信", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("开始配对", systemImage: "lock.shield") {
                    localModeEnabled = true
                    cloudModeEnabled = false
                    model.setLocalModeEnabled(true)
                    showingPairing = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("稍后在设置中配对") { completed = true }
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("AirSIM")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPairing, onDismiss: {
                if model.vowlan.availability.isOnlineForDisplay { completed = true }
            }) {
                NavigationStack {
                    SamsungPairingView()
                        .environmentObject(model)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingPairing = false }
                            }
                        }
                }
            }
        }
    }
}

struct AirSIMSettingsView: View {
    private enum SelfTestPhase {
        case idle
        case running
        case completed
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @AppStorage(LocalModePreference.key) private var localModeEnabled = false
    @AppStorage(CloudModePreference.key) private var cloudModeEnabled = true
    @AppStorage(LiveActivityVisibilityPreference.key) private var liveActivityEnabled = true
    @State private var relayURL = RelayConfiguration.effectiveURL(
        stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"),
        buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
        bundleID: Bundle.main.bundleIdentifier
    )
    @State private var directHost = UserDefaults.standard.string(forKey: ManualDirectConfiguration.hostKey) ?? ManualDirectConfiguration.defaultHost
    @State private var directControl = UserDefaults.standard.string(forKey: ManualDirectConfiguration.controlKey) ?? "17592"
    @State private var directPCM = UserDefaults.standard.string(forKey: ManualDirectConfiguration.pcmKey) ?? "17593"
    @State private var directPin = UserDefaults.standard.string(forKey: ManualDirectConfiguration.pinKey) ?? ManualDirectConfiguration.defaultCertificateSHA256
    @AppStorage(ManualDirectConfiguration.modeKey) private var directMode = DirectConnectionMode.automatic.rawValue
    @State private var directMessage: String?
    @State private var recordings: [URL] = []
    @State private var message: String?
    @State private var selfTestPhase: SelfTestPhase = .idle
    @State private var selfTestReport: CloudSelfTestReport?
    @State private var selfTestTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("连接方式", value: cloudRelayEnabled ? "直连优先，云端备用" : "安卓直连")
                } footer: {
                    Text("安卓直连支持局域网和 frp 外网连接。你目前的 frp 方案无需启用云端中继；云端关闭时不能保证锁屏后台来电唤醒。")
                }

                Section("当前连接") {
                    LabeledContent("当前模式", value: model.connectionModePresentation.title)
                    LabeledContent("连接状态", value: model.connectionModePresentation.status)
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    LabeledContent(
                        "云端 Relay",
                        value: localModeEnabled
                            ? "已关闭（使用直连）"
                            : (!cloudModeEnabled
                            ? "已关闭"
                            : (model.cloudAgentStatus?.cloudOnline == true ? "Agent 在线" : "不可达"))
                    )
                    Text(model.connectionModePresentation.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let connectionMessage = model.connectionMessage, !connectionMessage.isEmpty {
                        Text(connectionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("连接选择", selection: $directMode) {
                        ForEach(DirectConnectionMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: directMode) { value in
                        ManualDirectConfiguration.setMode(DirectConnectionMode(rawValue: value) ?? .automatic)
                        model.reloadDirectConnection()
                        directMessage = "连接选择已更新，正在重新验证。"
                    }
                    TextField("域名或 IPv4（例如 airsim.example.com）", text: $directHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("公网控制端口", text: $directControl).keyboardType(.numberPad)
                    TextField("公网音频端口", text: $directPCM).keyboardType(.numberPad)
                    TextField("证书 SHA256 指纹（自签证书必填）", text: $directPin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    Button("保存并连接") {
                        do {
                            try ManualDirectConfiguration.save(host: directHost, control: directControl, pcm: directPCM, certificateSHA256: directPin, connectionMode: DirectConnectionMode(rawValue: directMode) ?? .automatic)
                            localModeEnabled = true
                            cloudModeEnabled = false
                            model.setLocalModeEnabled(true)
                            model.reloadDirectConnection()
                            directMessage = "已保存；请查看连接状态确认鉴权结果"
                        } catch { directMessage = error.localizedDescription }
                    }
                    LabeledContent("公网备用地址", value: ManualDirectConfiguration.savedEndpoint() == nil ? "尚未保存" : (directMode == DirectConnectionMode.lanOnly.rawValue ? "已保存，当前仅使用局域网" : "已保存，自动验证后连接"))
                    if let directMessage { Text(directMessage).font(.footnote) }
                } header: {
                    Text("frp / 内网穿透直连")
                } footer: {
                    Text("先在同一局域网配对。两个端口都需要 TLS 网关。自签证书须填写服务器证书的 SHA256 指纹；不符即拒绝连接。留空时使用系统 CA 验证。音频端口为 TLS/TCP，不是 HTTPS。自动模式优先局域网，离开后回退到已保存的公网地址，回到局域网后重新验证并优先使用局域网。切换前仍会校验证书和配对身份；通话进行中保持原链路，不跨网络迁移。请保持电脑网关和安卓服务运行。通话中不能修改端点。")
                }
                .disabled(model.callLifecycleSnapshot.state.representsCall)

                Section("安卓手机连接") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("配对安卓手机", systemImage: "personalhotspot")
                    }
                    Button("重新发现", systemImage: "arrow.clockwise") {
                        model.vowlan.restartBrowsing()
                        Task { await model.vowlan.probeNow() }
                    }
                }

                Section {
                    Toggle(isOn: $liveActivityEnabled) {
                        Label("显示灵动岛", systemImage: "platter.filled.top.iphone")
                    }
                    .onChange(of: liveActivityEnabled) { enabled in
                        model.setLiveActivityEnabled(enabled)
                    }
                } header: {
                    Text("灵动岛与实时活动")
                } footer: {
                    Text("关闭后结束 AirSIM 的灵动岛与锁屏实时活动；通话和短信仍可正常使用。")
                }

                Section {
                    DisclosureGroup("云端中继（Relay，高级设置）") {
                        Text("Relay 是另行部署的云端服务，可中转通话、短信，并配合 Apple 推送唤醒来电。它与 frp 穿透是两套方案；仅填写地址不能自动获得后台来电功能。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("启用云端备用与推送", isOn: Binding(
                            get: { cloudRelayEnabled },
                            set: { updateCloudRelay(enabled: $0) }
                        ))

                        if cloudRelayEnabled {
                            TextField("自建服务地址：https://relay.example.com", text: $relayURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("保存中继地址") {
                                VoIPPushController.shared.updateRelayURL(relayURL)
                                resetCloudSelfTest()
                                Task {
                                    if let (api, _) = await model.readyVoWLANRoute() {
                                        await VoIPPushController.shared.syncRegistration(with: api)
                                    }
                                    await model.refreshCloudStatusForDiagnostics()
                                }
                                message = "地址已保存；请运行自检确认服务和推送配置。"
                            }
                            if let message { Text(message).foregroundStyle(.secondary) }

                            Button {
                                startCloudSelfTest()
                            } label: {
                                HStack {
                                    Label("检查云端服务与推送", systemImage: "stethoscope")
                                    Spacer()
                                    if selfTestPhase == .running { ProgressView() }
                                }
                            }
                            .disabled(selfTestPhase == .running)

                            if let report = selfTestReport {
                                ForEach(report.steps) { step in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: selfTestSymbol(for: step.state))
                                            .foregroundStyle(selfTestColor(for: step.state))
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(step.title)
                                            Text(step.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if selfTestPhase == .completed {
                                    Text(report.allPassed ? "云端服务自检通过" : "自检未通过，请检查失败项目")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(report.allPassed ? .green : .orange)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(model.callLifecycleSnapshot.state.representsCall
                        ? "通话中不能切换连接方式。"
                        : "使用 frp 时保持关闭即可。开启前需自行部署 Relay 并配置推送。")
                }
                .disabled(model.callLifecycleSnapshot.state.representsCall)

                Section {
                    ForEach(recordings, id: \.self) { file in
                        ShareLink(item: file) {
                            Label(file.deletingPathExtension().lastPathComponent, systemImage: "waveform")
                        }
                    }
                    Button("刷新录音列表") { recordings = LocalCallPCMRecorder.recordings() }
                } header: {
                    Text("通话录音")
                } footer: {
                    Text("在通话页点击录音后，双向语音仅保存在本机。停止录音或挂断后可在这里分享，也可从“文件 → 我的 iPhone → AirSIM → Recordings”访问。")
                }

                Section("关于") {
                    LabeledContent("项目", value: "AirSIM · Android")
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    Picker("外观", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .task {
                recordings = LocalCallPCMRecorder.recordings()
                if !localModeEnabled {
                    await model.refreshCloudStatusForDiagnostics()
                }
            }
            .onDisappear {
                selfTestTask?.cancel()
                selfTestTask = nil
                if selfTestPhase == .running { selfTestPhase = .idle }
            }
        }
    }

    private var cloudRelayEnabled: Bool { !localModeEnabled && cloudModeEnabled }

    private func resetCloudSelfTest() {
        selfTestTask?.cancel()
        selfTestPhase = .idle
        selfTestReport = nil
    }

    private func updateCloudRelay(enabled: Bool) {
        resetCloudSelfTest()
        localModeEnabled = !enabled
        cloudModeEnabled = enabled
        model.setLocalModeEnabled(!enabled)
        Task {
            if let (api, _) = await model.readyVoWLANRoute() {
                await VoIPPushController.shared.setCloudModeEnabled(enabled, with: api)
            } else {
                await VoIPPushController.shared.setCloudModeEnabled(enabled)
            }
            await model.refreshCloudStatusForDiagnostics()
        }
    }

    private func startCloudSelfTest() {
        selfTestTask?.cancel()
        selfTestPhase = .running
        selfTestReport = .initial
        selfTestTask = Task { @MainActor in
            let report = await VoIPPushController.shared.runCloudSelfTest { update in
                guard !Task.isCancelled else { return }
                selfTestReport = update
            }
            guard !Task.isCancelled else { return }
            selfTestReport = report
            selfTestPhase = .completed
            await model.refreshCloudStatusForDiagnostics()
        }
    }

    private func selfTestSymbol(for state: CloudSelfTestStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func selfTestColor(for state: CloudSelfTestStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }
}
