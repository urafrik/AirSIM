import SwiftUI

/// AirSIM 只引导三星配对；不检查旧模块 USB ECM、AT 或 QDC507 固件。
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
                    Text("连接三星手机")
                        .font(.largeTitle.bold())
                    Text("AirSIM 通过同一 Wi-Fi 或三星热点建立 VoWLAN；离开局域网时可使用独立云端 Relay。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("在三星手机启动 AirSIM 和音频桥", systemImage: "1.circle.fill")
                    Label("将两台设备连接到同一局域网", systemImage: "2.circle.fill")
                    Label("输入三星显示的六位配对码", systemImage: "3.circle.fill")
                }
                .font(.body.weight(.medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                Toggle(isOn: $localModeEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("仅本地模式", systemImage: "wifi")
                            .font(.headline)
                        Text("只使用 VoWLAN，不需要 Relay、PushKit 或 CallKit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: localModeEnabled) { enabled in
                    if enabled { cloudModeEnabled = false }
                    model.setLocalModeEnabled(enabled)
                }

                Spacer()

                Button("开始配对", systemImage: "lock.shield") {
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
    @State private var directHost = UserDefaults.standard.string(forKey: ManualDirectConfiguration.hostKey) ?? ""
    @State private var directControl = UserDefaults.standard.string(forKey: ManualDirectConfiguration.controlKey) ?? "17592"
    @State private var directPCM = UserDefaults.standard.string(forKey: ManualDirectConfiguration.pcmKey) ?? "17593"
    @State private var directMessage: String?
    @State private var message: String?
    @State private var selfTestPhase: SelfTestPhase = .idle
    @State private var selfTestReport: CloudSelfTestReport?
    @State private var selfTestTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $localModeEnabled) {
                        Label("仅本地模式", systemImage: "wifi")
                    }
                    .onChange(of: localModeEnabled) { enabled in
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        if enabled { cloudModeEnabled = false }
                        model.setLocalModeEnabled(enabled)
                    }
                } header: {
                    Text("运行模式")
                } footer: {
                    Text(localModeEnabled
                        ? "使用局域网 VoWLAN 或已配置的远程直连。不会注册 Relay、APNs、PushKit 或 CallKit。"
                        : "关闭后可按需启用云端 Relay、PushKit 和 CallKit。")
                }

                Section("当前连接") {
                    LabeledContent("当前模式", value: model.connectionModePresentation.title)
                    LabeledContent("连接状态", value: model.connectionModePresentation.status)
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    LabeledContent(
                        "云端 Relay",
                        value: localModeEnabled
                            ? "本地模式已关闭"
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
                    TextField("域名或 IPv4（例如 airsim.example.com）", text: $directHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("公网控制端口", text: $directControl).keyboardType(.numberPad)
                    TextField("公网音频端口", text: $directPCM).keyboardType(.numberPad)
                    Button("保存并启用仅直连（停用云端）") {
                        do {
                            try ManualDirectConfiguration.save(host: directHost, control: directControl, pcm: directPCM)
                            localModeEnabled = true
                            cloudModeEnabled = false
                            model.reloadDirectConnection()
                            directMessage = "已保存；请查看连接状态确认鉴权结果"
                        } catch { directMessage = error.localizedDescription }
                    }
                    Button("停用远程直连，恢复局域网发现") {
                        UserDefaults.standard.set(false, forKey: ManualDirectConfiguration.enabledKey)
                        model.reloadDirectConnection()
                        directMessage = "已恢复自动发现"
                    }
                    LabeledContent("手动端点", value: ManualDirectConfiguration.endpoint() == nil ? "未启用" : "已配置 TLS，连通性见连接状态")
                    if let directMessage { Text(directMessage).font(.footnote) }
                } header: {
                    Text("frp / 内网穿透直连")
                } footer: {
                    Text("先在同一局域网配对。两个端口都需要 TLS 网关及有效证书，音频端口为 TLS/TCP，不是 HTTPS。启用后优先使用手动端点，不依赖 Bonjour；关闭云端模式可避免 Relay 回退。完全停用 Relay 后，仅能在 App 活跃时接听来电，不能保证锁屏后台来电唤醒。通话中不能修改端点。")
                }
                .disabled(model.callLifecycleSnapshot.state.representsCall)

                Section("三星连接") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("配对三星手机", systemImage: "personalhotspot")
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
                    Toggle(isOn: $cloudModeEnabled) {
                        Label("远程通话与短信", systemImage: "cloud")
                    }
                    .disabled(localModeEnabled)
                    .onChange(of: cloudModeEnabled) { enabled in
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        Task {
                            if let (api, _) = await model.readyVoWLANRoute() {
                                await VoIPPushController.shared.setCloudModeEnabled(enabled, with: api)
                            } else {
                                await VoIPPushController.shared.setCloudModeEnabled(enabled)
                            }
                            await model.refreshCloudStatusForDiagnostics()
                        }
                    }

                    TextField("https://relay.example.com", text: $relayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(localModeEnabled)
                    Button("保存 Relay 地址") {
                        VoIPPushController.shared.updateRelayURL(relayURL)
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        Task {
                            if let (api, _) = await model.readyVoWLANRoute() {
                                await VoIPPushController.shared.syncRegistration(with: api)
                            }
                            await model.refreshCloudStatusForDiagnostics()
                        }
                        message = "地址已保存；配对后自动注册。"
                    }
                    .disabled(localModeEnabled)
                    if let message { Text(message).foregroundStyle(.secondary) }
                } header: {
                    Text("云端 Relay")
                } footer: {
                    Text("云端关闭后可使用 VoWLAN 或手动远程直连；后台来电唤醒仍需要自建 Relay 与 APNs。")
                }

                Section {
                    Button {
                        startCloudSelfTest()
                    } label: {
                        HStack {
                            Label("运行云端模式自检", systemImage: "stethoscope")
                            Spacer()
                            if selfTestPhase == .running {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(localModeEnabled || selfTestPhase == .running)

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
                            Text(report.allPassed ? "云端模式自检通过" : "自检未通过，请按失败步骤修复后重试")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(report.allPassed ? .green : .orange)
                        }
                    }
                } header: {
                    Text("云端模式自检")
                } footer: {
                    Text(localModeEnabled
                        ? "本地模式不运行云端自检。"
                        : "依次验证本机 Push 凭据、AirSIM Relay 身份、设备注册和 Agent 最近 90 秒心跳；不会拨号或发送短信。")
                }

                Section("关于") {
                    LabeledContent("项目", value: "AirSIM · Samsung")
                    Picker("外观", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .task {
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
