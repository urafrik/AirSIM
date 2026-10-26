import Foundation
import Network

struct VoWLANEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let controlPort: UInt16
    let pcmPort: UInt16
    let usesTLS: Bool
    let certificateSHA256: String?

    var isManual: Bool { usesTLS }

    init(host: String, controlPort: UInt16, pcmPort: UInt16) throws {
        guard Self.isPrivateIPv4(host), controlPort >= 1024, pcmPort >= 1024 else {
            throw VoWLANControllerError.invalidAdvertisement
        }
        self.host = host
        self.controlPort = controlPort
        self.pcmPort = pcmPort
        self.usesTLS = false
        self.certificateSHA256 = nil
    }

    /// Explicit user configuration only; Bonjour remains restricted to private IPv4.
    init(manualHost: String, controlPort: UInt16, pcmPort: UInt16, certificateSHA256: String? = nil) throws {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidManualHost(host), controlPort > 0, pcmPort > 0,
              controlPort != pcmPort else { throw VoWLANControllerError.invalidManualEndpoint }
        self.host = host
        self.controlPort = controlPort
        self.pcmPort = pcmPort
        if let certificateSHA256 {
            guard let normalized = PinnedTLS.normalize(certificateSHA256) else {
                throw VoWLANControllerError.invalidCertificatePin
            }
            self.certificateSHA256 = normalized
        } else { self.certificateSHA256 = nil }
        self.usesTLS = true
    }

    static func isValidManualHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, host.allSatisfy({ $0.isASCII }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return labels.count == 4 && labels.allSatisfy { part in
                guard let octet = UInt8(part) else { return false }
                return String(octet) == part
            }
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    var controlBaseURL: URL {
        URL(string: "\(usesTLS ? "https" : "http")://\(host):\(controlPort)/")!
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let fields = host.split(separator: ".").compactMap { UInt8($0) }
        guard fields.count == 4 else { return false }
        return fields[0] == 10 || (fields[0] == 172 && (16...31).contains(fields[1]))
            || (fields[0] == 192 && fields[1] == 168)
    }
}

struct VoWLANDiscoveredAgent: Equatable, Identifiable, Sendable {
    let id: String
    let endpoint: VoWLANEndpoint
    let deviceName: String
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?
    let agentKind: String?
}

private struct VoWLANHealthIdentity: Decodable {
    let ok: Bool
    let agentID: String?
    let agentKind: String?
    let deviceName: String?
    let manufacturer: String?
    let model: String?
    let phoneNumber: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case agentID = "agent_id"
        case agentKind = "agent_kind"
        case deviceName = "device_name"
        case manufacturer, model
        case phoneNumber = "phone_number"
    }
}

enum VoWLANAvailability: Equatable, Sendable {
    case unpaired
    case discovering
    case discovered(VoWLANEndpoint, at: Date)
    case verified(VoWLANEndpoint, at: Date)
    case unavailable(String)

    var endpoint: VoWLANEndpoint? {
        switch self {
        case let .discovered(value, _), let .verified(value, _): return value
        default: return nil
        }
    }

    func isReady(at now: Date = Date()) -> Bool {
        guard case let .verified(_, verifiedAt) = self else { return false }
        return now.timeIntervalSince(verifiedAt) >= 0 && now.timeIntervalSince(verifiedAt) <= 10
    }

    var isOnlineForDisplay: Bool {
        if case .verified = self { return true }
        return false
    }

    /// 拨号动作会在真正发起前重新执行签名健康检查，因此 UI 只需确认该端点
    /// 曾验证成功；不能用 10 秒的严格建链时效永久禁用拨号按钮。
    var allowsCallAttempt: Bool { isOnlineForDisplay }
}

enum ConnectionStatusHeadline {
    static func title(summary: ModuleConnectionSummary, vowlanOnline: Bool) -> String {
        if vowlanOnline { return "VoWLAN 在线" }
        switch summary {
        case .localOnline: return L10n.t("在线")
        case .localOnlineNoService: return "在线 · 蜂窝无服务"
        case .cloudOnly: return "云端在线 · USB 重连中"
        case .offline: return L10n.t("离线")
        }
    }
}

enum ModuleConnectionPresentationLevel: Equatable {
    case online
    case warning
    case cloud
    case offline
}

struct ModuleConnectionPresentation: Equatable {
    let title: String
    let routeTitle: String
    let description: String
    let level: ModuleConnectionPresentationLevel
    let systemImage: String

    static func make(
        summary: ModuleConnectionSummary,
        vowlanOnline: Bool,
        reconnecting: Bool,
        message: String?
    ) -> Self {
        if vowlanOnline {
            return Self(
                title: "VoWLAN 在线",
                routeTitle: "同一 Wi-Fi / 安卓手机热点",
                description: "VoWLAN 已连接，状态会自动刷新",
                level: .online,
                systemImage: "wifi"
            )
        }
        switch summary {
        case .localOnline:
            return Self(
                title: "模块在线", routeTitle: "USB ECM 直连",
                description: message ?? "USB ECM 已连接，状态会自动刷新",
                level: .online, systemImage: "checkmark.circle.fill"
            )
        case .localOnlineNoService:
            return Self(
                title: "模块在线 · 无服务", routeTitle: "USB ECM 已连接",
                description: message ?? "USB ECM 已连接，蜂窝网络正在自动恢复",
                level: .warning, systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .cloudOnly:
            return Self(
                title: "云端在线", routeTitle: "公网 Relay",
                description: message ?? "USB ECM 本地连接中断，模块仍可通过公网接收来电和短信",
                level: .cloud, systemImage: "icloud.fill"
            )
        case .offline:
            return Self(
                title: reconnecting ? "正在重新连接" : "模块离线",
                routeTitle: reconnecting ? "正在恢复连接" : "连接不可用",
                description: message ?? "请检查模块供电、蜂窝网络与 USB ECM 连接",
                level: reconnecting ? .warning : .offline,
                systemImage: reconnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill"
            )
        }
    }
}

enum PushRegistrationRouteSelector {
    static func select<Route>(primary: Route, verifiedVoWLAN: Route?) -> Route {
        verifiedVoWLAN ?? primary
    }
}

enum VoWLANStatusCopy {
    static func text(for availability: VoWLANAvailability, activeCall: Bool = false) -> String {
        if activeCall { return "通话中（VoWLAN）" }
        switch availability {
        case .unpaired: return "未配对"
        case .discovering: return "正在发现"
        case let .discovered(endpoint, _): return endpoint.isManual ? "远程直连正在验证" : "已发现，正在验证"
        case let .verified(endpoint, _): return endpoint.isManual ? "远程直连就绪（TLS）" : "VoWLAN 就绪"
        case let .unavailable(reason):
            return reason.contains("局域网已断开") ? "局域网已断开 · 已回退云端（下一通）" : reason
        }
    }
}

/// Non-secret routing configuration. The paired HMAC secret stays in Keychain.
enum ManualDirectConfiguration {
    static let enabledKey = "airsim.direct.enabled"
    static let modeKey = "airsim.direct.selection-mode"
    static let hostKey = "airsim.direct.host"
    static let controlKey = "airsim.direct.control-port"
    static let pcmKey = "airsim.direct.pcm-port"
    static let pinKey = "airsim.direct.certificate-sha256"
    static let defaultHost = "vip.gz.frp.one"
    static let defaultCertificateSHA256 = "75ec813f2a20007c2f8e7ded2c1a372f8d7d5e1a6178e3f6ddd34e667c3ad6ba"

    static func configuredPin(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: pinKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static func endpoint(defaults: UserDefaults = .standard) -> VoWLANEndpoint? {
        guard mode(defaults: defaults) != .lanOnly else { return nil }
        return savedEndpoint(defaults: defaults)
    }

    static func mode(defaults: UserDefaults = .standard) -> DirectConnectionMode {
        DirectConnectionMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .automatic
    }

    static func setMode(_ mode: DirectConnectionMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.set(mode != .lanOnly, forKey: enabledKey)
    }

    static func permits(_ endpoint: VoWLANEndpoint, defaults: UserDefaults = .standard) -> Bool {
        if endpoint.isManual { return endpoint == self.endpoint(defaults: defaults) }
        return mode(defaults: defaults) != .remoteOnly
    }

    static func savedEndpoint(defaults: UserDefaults = .standard) -> VoWLANEndpoint? {
        guard let host = defaults.string(forKey: hostKey),
              let control = UInt16(defaults.string(forKey: controlKey) ?? ""),
              let pcm = UInt16(defaults.string(forKey: pcmKey) ?? "") else { return nil }
        return try? VoWLANEndpoint(manualHost: host, controlPort: control, pcmPort: pcm, certificateSHA256: configuredPin(defaults: defaults))
    }

    static func save(host: String, control: String, pcm: String, certificateSHA256: String = "",
                     connectionMode: DirectConnectionMode = .automatic,
                     defaults: UserDefaults = .standard) throws {
        guard let controlPort = UInt16(control), let pcmPort = UInt16(pcm) else {
            throw VoWLANControllerError.invalidManualEndpoint
        }
        let rawPin = certificateSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = try VoWLANEndpoint(manualHost: host, controlPort: controlPort, pcmPort: pcmPort,
                                        certificateSHA256: rawPin.isEmpty ? nil : rawPin)
        defaults.set(endpoint.certificateSHA256 ?? "", forKey: pinKey)
        defaults.set(endpoint.host, forKey: hostKey)
        defaults.set(String(controlPort), forKey: controlKey)
        defaults.set(String(pcmPort), forKey: pcmKey)
        setMode(connectionMode, defaults: defaults)
    }
}

enum VoWLANControllerError: LocalizedError {
    case invalidAdvertisement
    case invalidManualEndpoint
    case invalidCertificatePin
    case notDiscovered
    case notPaired
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCertificatePin: return "证书 SHA256 指纹必须是 64 位十六进制，可带冒号或空格"
        case .invalidManualEndpoint: return "请输入域名或 IPv4 地址及两个不同的端口（1–65535），不要填写协议或路径"
        case .invalidAdvertisement: return "VoWLAN 广播内容无效"
        case .notDiscovered: return "尚未发现安卓手机 VoWLAN"
        case .notPaired: return "VoWLAN 尚未配对"
        case .authenticationFailed: return "VoWLAN 鉴权失败"
        }
    }
}

@MainActor
enum VoWLANProbeRecovery {
    static func run<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            guard isDefunctConnection(error) else { throw error }
            try? await Task.sleep(for: .milliseconds(200))
            return try await operation()
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if isDefunctConnection(error) {
            return "VoWLAN 连接已失效，请保持 iPhone 与安卓手机处于同一局域网"
        }
        return error.localizedDescription
    }

    private static func isDefunctConnection(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("defunctconnection")
            || message.contains("defunct connection")
            || message.contains("65569")
    }
}

struct VoWLANBrowserLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isRunning = false

    mutating func startIfNeeded() -> UInt64? {
        guard !isRunning else { return nil }
        return begin()
    }

    mutating func restart() -> UInt64 { begin() }

    mutating func stop() {
        generation &+= 1
        isRunning = false
    }

    mutating func markFailed(_ candidate: UInt64) -> Bool {
        guard accepts(candidate) else { return false }
        isRunning = false
        return true
    }

    func accepts(_ candidate: UInt64) -> Bool {
        isRunning && generation == candidate
    }

    private mutating func begin() -> UInt64 {
        generation &+= 1
        isRunning = true
        return generation
    }
}

/// A transient VPN route change can invalidate a successful probe without changing
/// Bonjour's result set. Keep retrying the saved endpoint, but bound retries when
/// the phone is genuinely offline.
struct VoWLANRecoveryGate {
    private var nextAttemptAt = Date.distantPast

    mutating func shouldAttempt(for availability: VoWLANAvailability, at now: Date) -> Bool {
        guard availability != .unpaired, !availability.isOnlineForDisplay,
              now >= nextAttemptAt else { return false }
        nextAttemptAt = now.addingTimeInterval(10)
        return true
    }

    mutating func reset() { nextAttemptAt = .distantPast }
}

@MainActor
final class VoWLANController: ObservableObject {
    @Published private(set) var availability: VoWLANAvailability =
        VoWLANCredentialStore.load() == nil ? .unpaired : .discovering {
        didSet { onAvailabilityChange?(availability) }
    }

    var onAvailabilityChange: ((VoWLANAvailability) -> Void)?

    @Published private(set) var discoveredAgents: [VoWLANDiscoveredAgent] = [] {
        didSet { onDiscoveredAgentsChange?() }
    }
    var onDiscoveredAgentsChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.example.airsim.vowlan.discovery")
    private var browser: NWBrowser?
    private var browserLifecycle = VoWLANBrowserLifecycle()
    private var recoveryGate = VoWLANRecoveryGate()
    private var discoveredEndpoint: VoWLANEndpoint?
    private var localAgents: [VoWLANDiscoveredAgent] = []
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkPath: String?
    private var probeEpoch: UInt64 = 0
    private var probeTask: Task<Void, Never>?
    private var nextVerificationAt = Date.distantPast
    var lockedCallEndpoint: VoWLANEndpoint?

    private func invalidateProbe() {
        nextVerificationAt = .distantPast
        probeEpoch &+= 1
        probeTask?.cancel()
        probeTask = nil
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.cellular))-\(path.usesInterfaceType(.wiredEthernet))"
            Task { @MainActor [weak self] in
                guard let self, self.lastNetworkPath != signature else { return }
                self.lastNetworkPath = signature
                if !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet) {
                    self.localAgents = []
                    self.discoveredAgents.removeAll { !$0.endpoint.isManual }
                }
                self.invalidateProbe()
                self.startBrowsing()
                await self.probeNow()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }


    func startBrowsing() {
        startPathMonitorIfNeeded()
        guard VoWLANCredentialStore.load() != nil else {
            stopBrowserSession()
            availability = .unpaired
            return
        }
        if activateManualEndpoint() { return }
        guard let generation = browserLifecycle.startIfNeeded() else { return }
        beginBrowsing(generation: generation)
    }

    func restartBrowsing() {
        startPathMonitorIfNeeded()
        invalidateProbe()
        guard VoWLANCredentialStore.load() != nil else {
            stopBrowserSession()
            availability = .unpaired
            return
        }
        if activateManualEndpoint() { return }
        let generation = browserLifecycle.restart()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        discoveredAgents = []
        localAgents = []
        beginBrowsing(generation: generation)
        Task {
            await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "ios", category: "vowlan", phase: "browser_restarted",
                title: "VoWLAN 浏览器已重建",
                fields: ["generation": String(generation)]
            )
        }
    }

    private func activateManualEndpoint() -> Bool {
        guard ManualDirectConfiguration.mode() == .remoteOnly else { return false }
        browserLifecycle.stop()
        stopCurrentBrowser()
        guard let endpoint = ManualDirectConfiguration.endpoint() else {
            discoveredEndpoint = nil
            discoveredAgents = []
            availability = .unavailable("远程直连配置无效，请重新保存")
            return true
        }
        if discoveredEndpoint != endpoint {
            discoveredEndpoint = endpoint
            discoveredAgents = [VoWLANDiscoveredAgent(
                id: "manual-direct", endpoint: endpoint, deviceName: "远程直连 Android",
                manufacturer: nil, model: nil, phoneNumber: nil, agentKind: nil
            )]
            availability = .discovered(endpoint, at: Date())
            Task { await self.probeNow() }
        }
        return true
    }

    private func beginBrowsing(generation: UInt64) {
        if !availability.isOnlineForDisplay { availability = .discovering }
        Task { await self.probeNow() }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let active = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_airsim-vowlan._tcp", domain: nil),
            using: parameters
        )
        active.browseResultsChangedHandler = { [weak self] results, _ in
            let agents = results.compactMap(Self.parseAgent)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.browserLifecycle.accepts(generation) else { return }
                self.discoveredAgents = agents.sorted {
                    if $0.deviceName == $1.deviceName { return $0.id < $1.id }
                    return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
                }
                self.localAgents = self.discoveredAgents
                self.invalidateProbe()
                // An empty Bonjour result must still probe the saved public endpoint.
                await self.probeNow()

            }
        }
        active.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor [weak self] in
                    guard let self, self.browserLifecycle.markFailed(generation) else { return }
                    self.stopCurrentBrowser()
                    self.localAgents = []
                    self.invalidateProbe()
                    // Bonjour can fail on cellular while a verified TLS route remains healthy.
                    if !self.availability.isOnlineForDisplay {
                        self.availability = .unavailable(VoWLANProbeRecovery.userFacingMessage(for: error))
                    }
                    await AgentVerboseTraceRecorder.shared.recordEvent(
                        source: "ios", category: "vowlan", phase: "browser_failed",
                        title: "VoWLAN 浏览器失效", detail: error.localizedDescription,
                        fields: ["generation": String(generation)], isFailure: true
                    )
                    await self.probeNow()
                }
            }
        }
        browser = active
        active.start(queue: queue)
    }

    func stopBrowsing() {
        invalidateProbe()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
        stopBrowserSession()
        if VoWLANCredentialStore.load() != nil { availability = .discovering }
    }

    private func stopBrowserSession() {
        browserLifecycle.stop()
        stopCurrentBrowser()
        discoveredEndpoint = nil
        discoveredAgents = []
        localAgents = []
    }

    private func stopCurrentBrowser() {
        let active = browser
        browser = nil
        active?.browseResultsChangedHandler = nil
        active?.stateUpdateHandler = nil
        active?.cancel()
    }

    func refreshAfterPairing() async {
        startBrowsing()
        await probeNow()
    }

    /// Called by the existing local status loop when no verified route remains.
    /// A VPN disconnect doesn't necessarily emit a new Bonjour result, so a
    /// failed health probe must not wait for Android to advertise again.
    func recoverIfNeeded() async {
        guard VoWLANCredentialStore.load() != nil else { return }
        if availability.isOnlineForDisplay {
            guard Date() >= nextVerificationAt else { return }
        } else {
            guard recoveryGate.shouldAttempt(for: availability, at: Date()) else { return }
        }
        nextVerificationAt = Date().addingTimeInterval(10)
        let browserWasRunning = browserLifecycle.isRunning
        startBrowsing()
        await probeNow()
        if availability.isOnlineForDisplay {
            recoveryGate.reset()
        } else if browserWasRunning {
            restartBrowsing()
        }
    }

    func probeNow() async {
        if let probeTask { await probeTask.value; return }
        guard let credential = VoWLANCredentialStore.load() else {
            availability = .unpaired
            return
        }
        let epoch = probeEpoch
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let mode = ManualDirectConfiguration.mode()
            let candidates = DirectConnectionPolicy.candidates(
                mode: mode, local: self.localAgents.map(\.endpoint),
                remote: ManualDirectConfiguration.endpoint(), locked: self.lockedCallEndpoint)
            do {
                let endpoint = try await DirectConnectionPolicy.firstVerified(
                    candidates: candidates,
                    isCurrent: { self.probeEpoch == epoch },
                    probe: { endpoint in try await self.verify(endpoint, credential: credential) })
                guard self.probeEpoch == epoch, !Task.isCancelled else { return }
                guard let endpoint else {
                    self.discoveredEndpoint = nil
                    self.availability = .discovering
                    return
                }
                self.discoveredEndpoint = endpoint
                self.availability = .verified(endpoint, at: Date())
            } catch is CancellationError { return }
            catch {
                guard self.probeEpoch == epoch else { return }
                self.discoveredEndpoint = nil
                self.availability = .unavailable(VoWLANProbeRecovery.userFacingMessage(for: error))
            }
        }
        probeTask = task
        await task.value
        if probeEpoch == epoch { probeTask = nil }
    }

    private func verify(_ endpoint: VoWLANEndpoint, credential: VoWLANCredential) async throws {
        let signed = try VoWLANRequestSigner(secret: credential.secret).sign(
            method: "GET", path: "/v1/health", body: Data())
        var request = URLRequest(url: endpoint.controlBaseURL.appendingPathComponent("v1/health"))
        request.timeoutInterval = endpoint.isManual ? 10 : 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        Self.apply(signed, to: &request)
        let response = try await WiredHTTPTransport(
            policy: endpoint.isManual ? .remoteDirect : .vowlan,
            certificateSHA256: endpoint.certificateSHA256).send(request)
        guard response.statusCode == 200,
              let identity = try? JSONDecoder().decode(VoWLANHealthIdentity.self, from: response.body),
              identity.ok else { throw VoWLANControllerError.authenticationFailed }
        try Task.checkCancellation()
        if !discoveredAgents.contains(where: { $0.endpoint == endpoint }) {
            discoveredAgents.append(VoWLANDiscoveredAgent(
                id: identity.agentID ?? "manual-direct", endpoint: endpoint,
                deviceName: identity.deviceName ?? "安卓手机",
                manufacturer: identity.manufacturer, model: identity.model,
                phoneNumber: identity.phoneNumber, agentKind: identity.agentKind))
        } else if let index = discoveredAgents.firstIndex(where: { $0.endpoint == endpoint }) {
            let previous = discoveredAgents[index]
            discoveredAgents[index] = VoWLANDiscoveredAgent(
                id: identity.agentID ?? previous.id, endpoint: endpoint,
                deviceName: identity.deviceName ?? previous.deviceName,
                manufacturer: identity.manufacturer ?? previous.manufacturer,
                model: identity.model ?? previous.model,
                phoneNumber: identity.phoneNumber ?? previous.phoneNumber,
                agentKind: identity.agentKind ?? previous.agentKind)
        }
    }

    nonisolated static func apply(_ signed: VoWLANSignedRequest, to request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: "X-AirSIM-VoWLAN-Version")
        request.setValue(String(signed.timestamp), forHTTPHeaderField: "X-AirSIM-VoWLAN-Timestamp")
        request.setValue(signed.nonce, forHTTPHeaderField: "X-AirSIM-VoWLAN-Nonce")
        request.setValue(signed.signature, forHTTPHeaderField: "X-AirSIM-VoWLAN-Signature")
    }

    private nonisolated static func parseAgent(_ result: NWBrowser.Result) -> VoWLANDiscoveredAgent? {
        guard case let .bonjour(record) = result.metadata,
              record["v"] == "1", let host = record["host"],
              let controlText = record["control_port"], let control = UInt16(controlText),
              let pcmText = record["pcm_port"], let pcm = UInt16(pcmText) else { return nil }
        guard let endpoint = try? VoWLANEndpoint(host: host, controlPort: control, pcmPort: pcm) else {
            return nil
        }
        let fallbackID = "vowlan-\(host)-\(control)"
        let deviceName = record["device_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VoWLANDiscoveredAgent(
            id: record["agent_id"]?.isEmpty == false ? record["agent_id"]! : fallbackID,
            endpoint: endpoint,
            deviceName: deviceName?.isEmpty == false ? deviceName! : "Android 手机",
            manufacturer: record["manufacturer"],
            model: record["model"],
            phoneNumber: nil,
            agentKind: record["agent_kind"]
        )
    }
}
