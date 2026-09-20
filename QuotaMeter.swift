import AppKit
import Combine
import CryptoKit
import Security
import SwiftUI
import WebKit

@main
struct QuotaMeterMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        controller = StatusBarController()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Quotameter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store = QuotaStore()
    private lazy var settingsWindowController = SettingsWindowController(store: store)

    override init() {
        super.init()
        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "API 额度")
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageOnly
            button.toolTip = "API 额度 / 用量"
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: QuotaPopoverView(
                store: store,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onRefresh: { [weak self] in
                    guard let self else { return }
                    Task { await self.store.refreshNow() }
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(store: QuotaStore) {
        let rootView = SettingsView(store: store)
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "API 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = host
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class DashboardLoginWindowController: NSWindowController, WKNavigationDelegate {
    private let webView: WKWebView
    private let onToken: (String) -> Void
    private let tokenKeys: [String]

    init(url: URL, tokenKeys: [String], onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        self.tokenKeys = tokenKeys
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "网页登录（登录完成后会自动同步用量）"
        window.center()
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = window.contentView?.bounds ?? .zero
        window.contentView = webView
        webView.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scanForToken(webView, attempt: 0)
    }

    private func scanForToken(_ webView: WKWebView, attempt: Int) {
        // Providers use different names; DeepSeek currently uses userToken.
        // The generic fallback names make this useful for other dashboards too.
        let keyJSON = (try? JSONSerialization.data(withJSONObject: tokenKeys))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"userToken\"]"
        let script = """
        (() => {
          const keys = \(keyJSON);
          for (const key of keys) {
            const value = localStorage.getItem(key) || sessionStorage.getItem(key);
            if (value) return value;
          }
          return null;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let raw = value as? String, !raw.isEmpty else { return }
            let token: String
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let wrapped = object["value"] as? String {
                token = wrapped
            } else {
                token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !token.isEmpty else { return }
            Task { @MainActor in
                self.onToken(token)
                // Keep the page visible so the user can see that login completed
                // and close it manually after the dashboard refreshes. Closing
                // immediately made a successful token read look like a crash.
                self.window?.title = "已获取官网登录令牌，可返回 Quotameter 查看同步数据"
            }
        }
        if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak webView] in
                guard let self, let webView, self.window?.isVisible == true else { return }
                self.scanForToken(webView, attempt: attempt + 1)
            }
        }
    }
}

enum APIProviderPreset: String, CaseIterable, Identifiable {
    case auto
    case compatible
    case openRouter
    case deepSeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "自动"
        case .compatible:
            return "兼容接口"
        case .openRouter:
            return "OpenRouter"
        case .deepSeek:
            return "DeepSeek"
        }
    }
}

struct AppConfiguration: Decodable {
    let baseURL: String?
    let apiKey: String?
    let platformToken: String?
    let providerPreset: String?
    let usagePath: String?
    let refreshIntervalSeconds: Int?

    var resolvedProviderPreset: APIProviderPreset? {
        guard let providerPreset = providerPreset?.trimmingCharacters(in: .whitespacesAndNewlines), !providerPreset.isEmpty else {
            return nil
        }
        return APIProviderPreset(rawValue: providerPreset)
            ?? APIProviderPreset(rawValue: providerPreset.lowercased())
            ?? (providerPreset.lowercased() == "openrouter" ? .openRouter : nil)
            ?? (providerPreset.lowercased() == "deepseek" ? .deepSeek : nil)
    }

    static func load() -> AppConfiguration? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for url in candidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let config = try? decoder.decode(AppConfiguration.self, from: data) else {
                continue
            }
            return config
        }
        return nil
    }

    private static func candidateURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QuotaMeter/config.json")
        ]
        urls.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("config.json"))
        urls.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("config.json"))
        return urls
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var baseURLString: String = ""
    @Published var refreshIntervalSeconds: Int = 30
    @Published var providerPreset: APIProviderPreset = .auto
    @Published var usagePath: String = "/v1/usage"
    @Published var platformToken: String = ""

    private var apiKey: String?
    private var pollingTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let configuration = AppConfiguration.load()
    private var hasPersistedBaseURL = false
    private var hasPersistedRefreshInterval = false
    private var hasPersistedProviderPreset = false
    private var hasPersistedUsagePath = false
    private let balanceUsageTracker = BalanceUsageTracker()
    private var dashboardLoginWindow: DashboardLoginWindowController?

    private enum DefaultsKey {
        static let baseURL = "QuotaMeter.baseURL"
        static let refreshInterval = "QuotaMeter.refreshInterval"
        static let providerPreset = "QuotaMeter.providerPreset"
        static let usagePath = "QuotaMeter.usagePath"
    }

    private static let platformTokenAccount = "platform-user-token"

    init() {
        loadPersistedSettings()
        applyConfigurationFallbacks()
        restartPollingIfNeeded()
    }

    deinit {
        pollingTask?.cancel()
    }

    var hasStoredKey: Bool {
        apiKey?.isEmpty == false
    }

    func openDashboardLogin(baseURLString overrideBaseURL: String? = nil) {
        let selectedBaseURL = overrideBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredBaseURL = (selectedBaseURL?.isEmpty == false ? selectedBaseURL! : baseURLString)
        let host = configuredBaseURL.lowercased()
        let isDeepSeek = host.contains("deepseek")
        let url = isDeepSeek
            ? URL(string: "https://platform.deepseek.com/usage")!
            : (URL(string: configuredBaseURL) ?? URL(string: "https://platform.openai.com")!)
        let tokenKeys = isDeepSeek
            ? ["userToken"]
            : ["userToken", "access_token", "accessToken", "auth_token", "authToken", "token"]
        dashboardLoginWindow = DashboardLoginWindowController(url: url, tokenKeys: tokenKeys) { [weak self] token in
            guard let self else { return }
            self.platformToken = token
            KeychainHelper.save(apiKey: token, service: KeychainHelper.service, account: Self.platformTokenAccount)
            Task { await self.refreshNow() }
        }
        dashboardLoginWindow?.showWindow(nil)
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        guard let key = apiKey, !key.isEmpty else {
            errorMessage = "请先在设置里输入 API Key"
            snapshot = nil
            return
        }
        let cleanedBaseURL = sanitisedBaseURLString(baseURLString)
        guard !cleanedBaseURL.isEmpty else {
            errorMessage = "请输入 Base URL，例如 https://your-api.example.com"
            return
        }
        guard let baseURL = normalisedBaseURL(cleanedBaseURL, providerPreset: providerPreset) else {
            errorMessage = "Base URL 格式无效，请填写完整的 http:// 或 https:// 地址"
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let data = try await UsageClient.fetchUsage(
                apiKey: key,
                platformToken: platformToken,
                baseURL: baseURL,
                providerPreset: providerPreset,
                usagePath: usagePath,
                daysBack: 90
            )
            snapshot = (providerPreset == .deepSeek || baseURL.host?.localizedCaseInsensitiveCompare("api.deepseek.com") == .orderedSame) && platformToken.isEmpty
                ? data
                : balanceUsageTracker.observe(
                    data,
                    apiKey: key,
                    baseURL: baseURL,
                    providerPreset: providerPreset
                )
            if data.mode == "deepseek", data.usage == nil {
                errorMessage = "DeepSeek 官网用量接口需要网页登录令牌；API Key 只能读取余额。请在“Usage 访问令牌”中配置平台登录态后刷新。"
            }
            lastUpdated = Date()
        } catch let clientError as UsageClientError {
            errorMessage = clientError.localizedDescription
            if case .unauthorized = clientError {
                pollingTask?.cancel()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSettings(
        baseURL: String,
        refreshIntervalSeconds: Int,
        apiKey: String?,
        providerPreset: APIProviderPreset,
        usagePath: String,
        platformToken: String
    ) async {
        let trimmedBaseURL = sanitisedBaseURLString(baseURL)
        let trimmedUsagePath = normalisedUsagePath(usagePath)
        defaults.set(trimmedBaseURL, forKey: DefaultsKey.baseURL)
        defaults.set(refreshIntervalSeconds, forKey: DefaultsKey.refreshInterval)
        defaults.set(providerPreset.rawValue, forKey: DefaultsKey.providerPreset)
        defaults.set(trimmedUsagePath, forKey: DefaultsKey.usagePath)
        self.baseURLString = trimmedBaseURL
        self.refreshIntervalSeconds = max(10, refreshIntervalSeconds)
        self.providerPreset = providerPreset
        self.usagePath = trimmedUsagePath
        let trimmedPlatformToken = platformToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.platformToken = trimmedPlatformToken
        if trimmedPlatformToken.isEmpty {
            KeychainHelper.delete(service: KeychainHelper.service, account: Self.platformTokenAccount)
        } else {
            KeychainHelper.save(apiKey: trimmedPlatformToken, service: KeychainHelper.service, account: Self.platformTokenAccount)
        }

        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainHelper.save(apiKey: self.apiKey!, service: KeychainHelper.service, account: KeychainHelper.account)
        } else if !hasStoredKey {
            self.apiKey = nil
        }

        restartPollingIfNeeded()
        await refreshNow()
    }

    func clearStoredKey() async {
        apiKey = nil
        platformToken = ""
        KeychainHelper.delete(service: KeychainHelper.service, account: KeychainHelper.account)
        KeychainHelper.delete(service: KeychainHelper.service, account: Self.platformTokenAccount)
        snapshot = nil
        errorMessage = nil
        pollingTask?.cancel()
    }

    private func restartPollingIfNeeded() {
        pollingTask?.cancel()
        guard apiKey?.isEmpty == false else { return }
        let interval = max(10, refreshIntervalSeconds)
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { break }
                await self.refreshNow()
            }
        }
    }

    private func loadPersistedSettings() {
        if let storedBaseURL = defaults.string(forKey: DefaultsKey.baseURL), !storedBaseURL.isEmpty {
            let cleaned = sanitisedBaseURLString(storedBaseURL)
            // Recover from the earlier paste-routing bug, which could save an
            // sk- API key into the Base URL field.
            if cleaned.lowercased().hasPrefix("sk-") {
                baseURLString = "https://api.deepseek.com"
                defaults.set(baseURLString, forKey: DefaultsKey.baseURL)
            } else {
                baseURLString = cleaned
            }
            hasPersistedBaseURL = true
        }
        let interval = defaults.integer(forKey: DefaultsKey.refreshInterval)
        if interval > 0 {
            refreshIntervalSeconds = max(10, interval)
            hasPersistedRefreshInterval = true
        }
        if let storedPreset = defaults.string(forKey: DefaultsKey.providerPreset),
           let preset = APIProviderPreset(rawValue: storedPreset) {
            providerPreset = preset
            hasPersistedProviderPreset = true
        }
        if let storedUsagePath = defaults.string(forKey: DefaultsKey.usagePath), !storedUsagePath.isEmpty {
            usagePath = normalisedUsagePath(storedUsagePath)
            hasPersistedUsagePath = true
        }
        apiKey = KeychainHelper.read(apiKeyFor: KeychainHelper.account, service: KeychainHelper.service)
        platformToken = KeychainHelper.read(apiKeyFor: Self.platformTokenAccount, service: KeychainHelper.service) ?? ""
    }

    private func applyConfigurationFallbacks() {
        guard let configuration else { return }

        if !hasPersistedBaseURL, let baseURL = configuration.baseURL, !baseURL.isEmpty {
            baseURLString = sanitisedBaseURLString(baseURL)
        }
        if !hasPersistedRefreshInterval, let interval = configuration.refreshIntervalSeconds {
            refreshIntervalSeconds = max(10, interval)
        }
        if !hasPersistedProviderPreset, let preset = configuration.resolvedProviderPreset {
            providerPreset = preset
        }
        if !hasPersistedUsagePath, let usagePath = configuration.usagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !usagePath.isEmpty {
            self.usagePath = normalisedUsagePath(usagePath)
        }
        if apiKey == nil, let configuredKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !configuredKey.isEmpty {
            apiKey = configuredKey
            KeychainHelper.save(apiKey: configuredKey, service: KeychainHelper.service, account: KeychainHelper.account)
        }
        if platformToken.isEmpty, let configuredToken = configuration.platformToken?.trimmingCharacters(in: .whitespacesAndNewlines), !configuredToken.isEmpty {
            platformToken = configuredToken
            KeychainHelper.save(apiKey: configuredToken, service: KeychainHelper.service, account: Self.platformTokenAccount)
        }
    }

    private func sanitisedBaseURLString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        trimmed = trimmed.replacingOccurrences(of: "\u{FEFF}", with: "")
        trimmed = trimmed.replacingOccurrences(of: "\u{200B}", with: "")
        trimmed = trimmed.replacingOccurrences(of: "：", with: ":")
        trimmed = trimmed.replacingOccurrences(of: "／", with: "/")

        if trimmed.count >= 2 &&
           ((trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
            (trimmed.hasPrefix("<") && trimmed.hasSuffix(">"))) {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        if !trimmed.isEmpty && !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func normalisedBaseURL(_ raw: String, providerPreset: APIProviderPreset) -> URL? {
        let trimmed = sanitisedBaseURLString(raw)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            return nil
        }

        if providerPreset == .openRouter || url.host?.localizedCaseInsensitiveContains("openrouter.ai") == true {
            if url.path.lowercased().hasSuffix("/v1") {
                return url
            }
            if url.path.lowercased().hasSuffix("/api") {
                components.path = url.path + "/v1"
                return components.url
            }
            if url.path.isEmpty {
                components.path = "/api/v1"
                return components.url
            }
        }

        if providerPreset == .deepSeek || url.host?.localizedCaseInsensitiveCompare("platform.deepseek.com") == .orderedSame {
            if url.host?.localizedCaseInsensitiveCompare("platform.deepseek.com") == .orderedSame {
                return URL(string: "https://api.deepseek.com")
            }
        }

        return url
    }

    private func normalisedUsagePath(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return trimmed
        }
        if trimmed.isEmpty {
            return "/v1/usage"
        }
        if !trimmed.hasPrefix("/") {
            trimmed = "/" + trimmed
        }
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

/// Some API providers expose an account balance but no aggregate usage endpoint.
/// Keep a local, per-key ledger of balance decreases so the app can still show
/// spending observed after the first successful refresh. This deliberately does
/// not invent token or request counts: those cannot be reconstructed from a
/// balance response alone.
@MainActor
private final class BalanceUsageTracker {
    private struct State: Codable {
        var unit: String
        var lastBalance: Double
        var totalSpent: Double
        var dailySpent: [String: Double]
    }

    private let defaults = UserDefaults.standard
    private let statePrefix = "QuotaMeter.balanceUsage."

    func observe(
        _ snapshot: UsageResponse,
        apiKey: String,
        baseURL: URL,
        providerPreset: APIProviderPreset
    ) -> UsageResponse {
        // Prefer provider-supplied usage whenever it exists.
        guard snapshot.usage == nil,
              snapshot.dailyUsage == nil,
              let balance = snapshot.remaining ?? snapshot.balance,
              balance.isFinite else {
            return snapshot
        }

        let unit = snapshot.unit?.uppercased() ?? ""
        let key = storageKey(baseURL: baseURL, providerPreset: providerPreset, apiKey: apiKey)
        let today = QuotaDateFormatter.ymd(Date())
        var state = loadState(for: key)
        var spentToday: Double?
        var totalSpent: Double?
        var rows: [DailyUsageEntry]?

        if var existing = state, existing.unit == unit {
            // A higher balance is a top-up/grant, not negative usage. Reset the
            // baseline and keep the previously observed spending history.
            let decrease = max(existing.lastBalance - balance, 0)
            if decrease > 0 {
                existing.totalSpent += decrease
                existing.dailySpent[today, default: 0] += decrease
            }
            existing.lastBalance = balance
            state = existing
            saveState(existing, for: key)
            spentToday = existing.dailySpent[today, default: 0]
            totalSpent = existing.totalSpent
            rows = existing.dailySpent
                .filter { $0.value > 0 }
                .map { DailyUsageEntry(
                    date: $0.key,
                    requests: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheWriteTokens: nil,
                    actualCost: $0.value,
                    cost: $0.value,
                    totalTokens: nil
                ) }
        } else {
            let initial = State(unit: unit, lastBalance: balance, totalSpent: 0, dailySpent: [:])
            saveState(initial, for: key)
        }

        guard let spentToday, let totalSpent else {
            return snapshot
        }
        let todayEntry = UsageCounterEntry(
            actualCost: spentToday,
            cacheCreationTokens: nil,
            cacheReadTokens: nil,
            cost: spentToday,
            inputTokens: nil,
            outputTokens: nil,
            requests: nil,
            totalTokens: nil,
            cacheWriteTokens: nil
        )
        let totalEntry = UsageCounterEntry(
            actualCost: totalSpent,
            cacheCreationTokens: nil,
            cacheReadTokens: nil,
            cost: totalSpent,
            inputTokens: nil,
            outputTokens: nil,
            requests: nil,
            totalTokens: nil,
            cacheWriteTokens: nil
        )
        return UsageResponse(
            balance: snapshot.balance,
            dailyUsage: rows,
            isValid: snapshot.isValid,
            mode: (snapshot.mode ?? "compatible") + "-local",
            planName: snapshot.planName,
            remaining: snapshot.remaining,
            unit: snapshot.unit,
            usage: UsageSummary(
                averageDurationMs: nil,
                rpm: nil,
                tpm: nil,
                today: todayEntry,
                total: totalEntry
            ),
            quota: snapshot.quota,
            rateLimits: snapshot.rateLimits,
            subscription: snapshot.subscription,
            expiresAt: snapshot.expiresAt,
            daysUntilExpiry: snapshot.daysUntilExpiry,
            modelStats: snapshot.modelStats
        )
    }

    private func storageKey(baseURL: URL, providerPreset: APIProviderPreset, apiKey: String) -> String {
        let source = "\(baseURL.absoluteString.lowercased())|\(providerPreset.rawValue)|\(apiKey)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func loadState(for key: String) -> State? {
        guard let data = defaults.data(forKey: statePrefix + key) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State, for key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: statePrefix + key)
    }
}

enum UsageClientError: LocalizedError {
    case invalidURL
    case unauthorized(String)
    case server(Int, String)
    case decoding(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "API 地址无效"
        case .unauthorized(let message):
            return message.isEmpty ? "密钥无效或已停用" : message
        case .server(let code, let message):
            return message.isEmpty ? "请求失败 \(code)" : message
        case .decoding(let message):
            return message
        case .unsupported(let message):
            return message
        }
    }
}

enum UsageClient {
    static func fetchUsage(
        apiKey: String,
        platformToken: String,
        baseURL: URL,
        providerPreset: APIProviderPreset,
        usagePath: String,
        daysBack: Int
    ) async throws -> UsageResponse {
        if let message = webDashboardMessage(for: baseURL) {
            throw UsageClientError.unsupported(message)
        }

        switch providerPreset {
        case .openRouter:
            return try await fetchOpenRouterUsage(apiKey: apiKey, baseURL: baseURL)
        case .deepSeek:
            return try await fetchDeepSeekUsage(apiKey: apiKey, platformToken: platformToken, baseURL: baseURL)
        case .compatible:
            return try await fetchCompatibleUsage(
                apiKey: apiKey,
                authToken: platformToken,
                baseURL: baseURL,
                usagePath: usagePath,
                daysBack: daysBack
            )
        case .auto:
            if isDeepSeekHost(baseURL) {
                return try await fetchDeepSeekUsage(apiKey: apiKey, platformToken: platformToken, baseURL: baseURL)
            }
            do {
                return try await fetchCompatibleUsage(
                    apiKey: apiKey,
                    authToken: platformToken,
                    baseURL: baseURL,
                    usagePath: usagePath,
                    daysBack: daysBack
                )
            } catch {
                if shouldFallbackToOpenRouter(baseURL: baseURL, error: error) {
                    return try await fetchOpenRouterUsage(apiKey: apiKey, baseURL: baseURL)
                }
                throw error
            }
        }
    }

    private static func fetchCompatibleUsage(
        apiKey: String,
        authToken: String,
        baseURL: URL,
        usagePath: String,
        daysBack: Int
    ) async throws -> UsageResponse {
        let candidates = compatibleUsageURLCandidates(
            baseURL: baseURL,
            usagePath: usagePath,
            daysBack: daysBack
        )
        var lastError: Error?

        for (index, candidateURL) in candidates.enumerated() {
            do {
                let credential = authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiKey : authToken
                let (data, response) = try await sendRequest(url: candidateURL, apiKey: credential)
                return try decodeUsageResponse(from: data, response: response)
            } catch let clientError as UsageClientError {
                lastError = clientError
                if index < candidates.count - 1 {
                    continue
                }
            } catch {
                lastError = error
                if index < candidates.count - 1 {
                    continue
                }
            }
        }

        throw lastError ?? UsageClientError.invalidURL
    }

    private static func fetchOpenRouterUsage(apiKey: String, baseURL: URL) async throws -> UsageResponse {
        guard let url = openRouterURL(baseURL: baseURL) else {
            throw UsageClientError.invalidURL
        }
        let (data, response) = try await sendRequest(url: url, apiKey: apiKey)
        return try decodeOpenRouterResponse(from: data, response: response)
    }

    private static func fetchDeepSeekUsage(apiKey: String, platformToken: String, baseURL: URL) async throws -> UsageResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw UsageClientError.invalidURL
        }
        components.path = "/user/balance"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw UsageClientError.invalidURL
        }

        let (data, response) = try await sendRequest(url: url, apiKey: apiKey)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.server(-1, "没有收到有效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractMessage(from: data)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw UsageClientError.unauthorized(message)
            }
            throw UsageClientError.server(http.statusCode, message)
        }

        do {
            let payload = try makeDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            let balanceInfo = payload.balanceInfos.first(where: {
                $0.currency.localizedCaseInsensitiveCompare("USD") == .orderedSame
            }) ?? payload.balanceInfos.first
            let balance = balanceInfo.flatMap { Double($0.totalBalance) }
            guard let balanceInfo, let balance else {
                throw UsageClientError.decoding("DeepSeek 返回中没有可识别的余额")
            }

            let currency = balanceInfo.currency.uppercased()
            let balanceResponse = UsageResponse(
                balance: balance,
                dailyUsage: nil,
                isValid: payload.isAvailable,
                mode: "deepseek",
                planName: "DeepSeek API（官网用量自动探测）",
                remaining: balance,
                unit: currency,
                usage: nil,
                quota: nil,
                rateLimits: nil,
                subscription: nil,
                expiresAt: nil,
                daysUntilExpiry: nil,
                modelStats: nil
            )
            let credential = platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? apiKey
                : platformToken
            // DeepSeek deployments differ: newer platform endpoints accept the
            // API key, while some accounts require the web session token. Try
            // the same account-level endpoint with the configured API key first
            // so normal API-key setup works without browser DevTools.
            if !platformToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A user-supplied/login-captured platform token must produce
                // an actionable error instead of silently falling back to the
                // balance-only response.
                let platformUsage = try await fetchDeepSeekPlatformUsage(token: credential)
                return mergeDeepSeekUsage(balance: balanceResponse, usage: platformUsage)
            }
            if let platformUsage = try? await fetchDeepSeekPlatformUsage(token: credential) {
                return mergeDeepSeekUsage(balance: balanceResponse, usage: platformUsage)
            }
            return balanceResponse
        } catch let error as UsageClientError {
            throw error
        } catch {
            throw UsageClientError.decoding(error.localizedDescription)
        }
    }

    /// The platform usage page is authenticated with the browser's account
    /// `userToken`, which is deliberately different from an API key. These
    /// endpoints are the same read-only endpoints used by the official page.
    private static func fetchDeepSeekPlatformUsage(token: String) async throws -> DeepSeekPlatformUsage {
        let now = Date()
        let timezone = TimeZone.current.secondsFromGMT()
        // The platform validates day boundaries. Build a local-midnight
        // window (same convention as the official Usage page) rather than
        // sending the current hour/minute/second.
        let day = 24 * 60 * 60
        let shiftedNow = Int(now.timeIntervalSince1970) + timezone
        let todayStart = (shiftedNow / day) * day - timezone
        let end = todayStart + day
        // DeepSeek rejects overly large ranges; keep the default at 30 days.
        let start = end - (30 * day)
        let query = "start=\(start)&end=\(end)&tz=\(timezone)"
        let amountURL = URL(string: "https://platform.deepseek.com/api/v0/usage/by_api_key/amount?\(query)")!
        let amountData = try await sendPlatformRequest(url: amountURL, token: token)
        let costURL = URL(string: "https://platform.deepseek.com/api/v0/usage/by_api_key/cost?\(query)")!
        let costData = try? await sendPlatformRequest(url: costURL, token: token)

        var daily: [String: DeepSeekDailyAccumulator] = [:]
        var total = UsageCounterEntry(
            actualCost: nil, cacheCreationTokens: 0, cacheReadTokens: 0, cost: nil,
            inputTokens: 0, outputTokens: 0, requests: 0, totalTokens: 0, cacheWriteTokens: nil
        )
        let todayKey = QuotaDateFormatter.ymd(now)

        guard let amountRoot = try JSONSerialization.jsonObject(with: amountData) as? [String: Any] else {
            throw UsageClientError.decoding("DeepSeek 用量接口返回格式无效")
        }
        let amountBizData = try checkedPlatformBizData(amountRoot)
        if let series = value(in: amountBizData, keys: ["series"]) as? [[String: Any]] {
            for item in series {
                guard let buckets = value(in: item, keys: ["buckets"]) as? [[String: Any]] else { continue }
                for bucket in buckets {
                    guard let usage = value(in: bucket, keys: ["usage"]) as? [String: Any],
                          let date = platformDate(value(in: bucket, keys: ["time", "timestamp"])) else { continue }
                    let hit = numberValue(value(in: usage, keys: ["PROMPT_CACHE_HIT_TOKEN", "prompt_cache_hit_tokens"])) ?? 0
                    let miss = numberValue(value(in: usage, keys: ["PROMPT_CACHE_MISS_TOKEN", "prompt_cache_miss_tokens"])) ?? 0
                    let output = numberValue(value(in: usage, keys: ["RESPONSE_TOKEN", "response_tokens", "output_tokens"])) ?? 0
                    let requests = numberValue(value(in: usage, keys: ["REQUEST", "requests", "request_count"])) ?? 0
                    var row = daily[date] ?? DeepSeekDailyAccumulator()
                    row.inputTokens += hit + miss
                    row.cacheReadTokens += hit
                    row.outputTokens += output
                    row.totalTokens += hit + miss + output
                    row.requests += requests
                    daily[date] = row
                }
            }
        }

        if let costData,
           let root = try? JSONSerialization.jsonObject(with: costData) as? [String: Any],
           let bizData = try? checkedPlatformBizData(root),
           let currencies = value(in: bizData, keys: ["data"]) as? [[String: Any]],
           let currency = currencies.first,
           let series = value(in: currency, keys: ["series"]) as? [[String: Any]] {
            for item in series {
                guard let buckets = value(in: item, keys: ["buckets"]) as? [[String: Any]] else { continue }
                for bucket in buckets {
                    guard let date = platformDate(value(in: bucket, keys: ["time", "timestamp"])),
                          let cost = numberValue(value(in: bucket, keys: ["cost", "amount"])) else { continue }
                    var row = daily[date] ?? DeepSeekDailyAccumulator()
                    row.cost += cost
                    daily[date] = row
                }
            }
        }

        for row in daily.values {
            total = UsageCounterEntry(
                actualCost: (total.actualCost ?? 0) + row.cost,
                cacheCreationTokens: total.cacheCreationTokens,
                cacheReadTokens: (total.cacheReadTokens ?? 0) + row.cacheReadTokens,
                cost: (total.cost ?? 0) + row.cost,
                inputTokens: (total.inputTokens ?? 0) + row.inputTokens,
                outputTokens: (total.outputTokens ?? 0) + row.outputTokens,
                requests: (total.requests ?? 0) + row.requests,
                totalTokens: (total.totalTokens ?? 0) + row.totalTokens,
                cacheWriteTokens: nil
            )
        }
        let today = daily[todayKey] ?? DeepSeekDailyAccumulator()
        let dailyRows = daily.map { date, row in
            DailyUsageEntry(
                date: date,
                requests: row.requests,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: nil,
                actualCost: row.cost,
                cost: row.cost,
                totalTokens: row.totalTokens
            )
        }.sorted { ($0.date ?? "") > ($1.date ?? "") }

        return DeepSeekPlatformUsage(
            dailyUsage: dailyRows,
            today: UsageCounterEntry(
                actualCost: today.cost, cacheCreationTokens: nil, cacheReadTokens: today.cacheReadTokens,
                cost: today.cost, inputTokens: today.inputTokens, outputTokens: today.outputTokens,
                requests: today.requests, totalTokens: today.totalTokens, cacheWriteTokens: nil
            ),
            total: total
        )
    }

    private static func sendPlatformRequest(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageClientError.server(-1, "没有收到有效响应") }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractMessage(from: data)
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageClientError.unauthorized(message) }
            throw UsageClientError.server(http.statusCode, message)
        }
        return data
    }

    private static func platformBizData(_ root: [String: Any]) -> [String: Any]? {
        let data = dictionary(value(in: root, keys: ["data"])) ?? root
        return dictionary(value(in: data, keys: ["biz_data", "bizData"])) ?? data
    }

    private static func checkedPlatformBizData(_ root: [String: Any]) throws -> [String: Any] {
        let data = dictionary(value(in: root, keys: ["data"])) ?? root
        if let code = numberValue(value(in: data, keys: ["biz_code", "bizCode"])), code != 0 {
            let message = stringValue(value(in: data, keys: ["biz_msg", "bizMsg", "message"])) ?? "DeepSeek 平台接口业务错误码 \(Int(code))"
            throw UsageClientError.server(Int(code), message)
        }
        return dictionary(value(in: data, keys: ["biz_data", "bizData"])) ?? data
    }

    private static func platformDate(_ value: Any?) -> String? {
        guard let timestamp = numberValue(value) else { return nil }
        return QuotaDateFormatter.ymd(Date(timeIntervalSince1970: timestamp))
    }

    private struct DeepSeekDailyAccumulator {
        var inputTokens = 0.0
        var outputTokens = 0.0
        var totalTokens = 0.0
        var requests = 0.0
        var cacheReadTokens = 0.0
        var cost = 0.0
    }

    private struct DeepSeekPlatformUsage {
        let dailyUsage: [DailyUsageEntry]
        let today: UsageCounterEntry
        let total: UsageCounterEntry
    }

    private static func mergeDeepSeekUsage(balance: UsageResponse, usage: DeepSeekPlatformUsage) -> UsageResponse {
        UsageResponse(
            balance: balance.balance,
            dailyUsage: usage.dailyUsage,
            isValid: balance.isValid,
            mode: "deepseek-platform",
            planName: "DeepSeek API（官网同步）",
            remaining: balance.remaining,
            unit: balance.unit,
            usage: UsageSummary(averageDurationMs: nil, rpm: nil, tpm: nil, today: usage.today, total: usage.total),
            quota: balance.quota,
            rateLimits: balance.rateLimits,
            subscription: balance.subscription,
            expiresAt: balance.expiresAt,
            daysUntilExpiry: balance.daysUntilExpiry,
            modelStats: balance.modelStats
        )
    }

    private static func sendRequest(url: URL, apiKey: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request)
    }

    private static func usageURL(baseURL: URL, usagePath: String, daysBack: Int) -> URL? {
        if let absolute = URL(string: usagePath), absolute.scheme != nil, absolute.host != nil {
            var absoluteComponents = URLComponents(url: absolute, resolvingAgainstBaseURL: false)
            if absolute.path.localizedCaseInsensitiveContains("usage") {
                let end = QuotaDateFormatter.ymd(Date())
                let boundedDays = min(max(daysBack, 1), 90)
                let start = QuotaDateFormatter.ymd(Calendar.current.date(byAdding: .day, value: -boundedDays, to: Date()) ?? Date())
                absoluteComponents?.queryItems = [
                    URLQueryItem(name: "start_date", value: start),
                    URLQueryItem(name: "end_date", value: end),
                    URLQueryItem(name: "days", value: String(boundedDays)),
                    URLQueryItem(name: "timezone", value: TimeZone.current.identifier)
                ]
            }
            return absoluteComponents?.url
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        let endpoint = normalisedRelativePath(usagePath)
        components?.path = appendPath(base: path, endpoint: endpoint)

        let end = QuotaDateFormatter.ymd(Date())
        let boundedDays = min(max(daysBack, 1), 90)
        let start = QuotaDateFormatter.ymd(
            Calendar.current.date(byAdding: .day, value: -boundedDays, to: Date()) ?? Date()
        )
        if endpoint.localizedCaseInsensitiveContains("usage") {
            components?.queryItems = [
                URLQueryItem(name: "start_date", value: start),
                URLQueryItem(name: "end_date", value: end),
                URLQueryItem(name: "days", value: String(boundedDays)),
                URLQueryItem(name: "timezone", value: TimeZone.current.identifier)
            ]
        } else {
            components?.query = nil
        }
        return components?.url
    }

    private static func openRouterURL(baseURL: URL) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        components?.path = joinPaths(path, "/key")
        return components?.url
    }

    private static func normalisedRelativePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = "/v1/usage"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func compatibleUsageURLCandidates(
        baseURL: URL,
        usagePath: String,
        daysBack: Int
    ) -> [URL] {
        var baseURLs = [baseURL]
        if !baseURL.path.isEmpty,
           let rootURL = rootBaseURL(from: baseURL),
           rootURL.absoluteString != baseURL.absoluteString {
            baseURLs.append(rootURL)
        }

        let paths = [
            normalisedRelativePath(usagePath),
            "/v1/usage",
            "/usage",
            "/api/usage",
            "/api/v1/usage",
            "/v1/user/usage",
            "/user/usage",
            "/v1/account/usage",
            "/account/usage",
            "/billing/usage",
            "/v1/dashboard/billing/usage",
            "/v1/organization/usage/completions",
            "/v1/balance",
            "/balance",
            "/api/balance",
            "/user/balance",
            "/api/user/balance"
        ]
        var candidates: [URL] = []
        var seen = Set<String>()

        for candidateBaseURL in baseURLs {
            for path in paths {
                guard let url = usageURL(
                    baseURL: candidateBaseURL,
                    usagePath: path,
                    daysBack: daysBack
                ) else {
                    continue
                }
                if seen.insert(url.absoluteString).inserted {
                    candidates.append(url)
                }
            }
        }

        return candidates
    }

    private static func rootBaseURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func joinPaths(_ base: String, _ addition: String) -> String {
        let left = base.hasSuffix("/") ? String(base.dropLast()) : base
        let right = addition.hasPrefix("/") ? addition : "/" + addition
        if left.isEmpty {
            return right
        }
        return left + right
    }

    private static func appendPath(base: String, endpoint: String) -> String {
        let normalisedBase = base.isEmpty
            ? ""
            : "/" + base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalisedEndpoint = "/" + endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalisedBase.isEmpty {
            return normalisedEndpoint
        }
        if normalisedEndpoint == normalisedBase ||
           normalisedEndpoint.hasPrefix(normalisedBase + "/") {
            return normalisedEndpoint
        }
        return joinPaths(normalisedBase, normalisedEndpoint)
    }

    private static func decodeUsageResponse(from data: Data, response: URLResponse) throws -> UsageResponse {
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.server(-1, "没有收到有效响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = extractMessage(from: data)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw UsageClientError.unauthorized(message)
            }
            throw UsageClientError.server(http.statusCode, message)
        }

        let decoder = makeDecoder()
        if let response = try? decoder.decode(UsageResponse.self, from: data),
           hasUsageData(response) {
            return response
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = dictionary(value(in: json, keys: ["data"])) , looksLikeUsageResponse(nested) {
                let nestedData = try JSONSerialization.data(withJSONObject: nested)
                if let response = try? decoder.decode(UsageResponse.self, from: nestedData),
                   hasUsageData(response) {
                    return response
                }
            }
            if let nested = dictionary(value(in: json, keys: ["result"])) , looksLikeUsageResponse(nested) {
                let nestedData = try JSONSerialization.data(withJSONObject: nested)
                if let response = try? decoder.decode(UsageResponse.self, from: nestedData),
                   hasUsageData(response) {
                    return response
                }
            }
            if let response = flexibleUsageResponse(from: json) {
                return response
            }
        }

        throw UsageClientError.decoding("无法识别接口返回格式")
    }

    private static func hasUsageData(_ response: UsageResponse) -> Bool {
        response.balance != nil ||
        response.remaining != nil ||
        response.usage != nil ||
        response.dailyUsage != nil ||
        response.quota != nil ||
        response.rateLimits != nil ||
        response.subscription != nil ||
        response.modelStats != nil ||
        response.isValid != nil
    }

    private static func flexibleUsageResponse(from root: [String: Any]) -> UsageResponse? {
        let payload = dictionary(value(in: root, keys: ["data"])) ??
            dictionary(value(in: root, keys: ["result", "response"])) ?? root
        let quota = dictionary(value(in: payload, keys: ["quota", "limits", "credit"]))
        let usage = dictionary(value(in: payload, keys: ["usage", "usage_summary", "usageSummary"]))
        let today = dictionary(value(in: usage, keys: ["today", "daily", "current_day"])) ??
            dictionary(value(in: payload, keys: ["today", "today_usage", "todayUsage", "daily_usage", "dailyUsage"]))
        let total = dictionary(value(in: usage, keys: ["total", "all_time", "allTime", "cumulative"])) ??
            dictionary(value(in: payload, keys: ["total", "total_usage", "totalUsage", "cumulative_usage", "cumulativeUsage"]))

        let balance = firstNumber(
            in: payload,
            keys: ["balance", "remaining", "remaining_balance", "credit_balance", "credits", "total_balance", "available_balance", "available_credit", "available_credits"]
        ) ?? quota.flatMap {
            firstNumber(in: $0, keys: ["remaining", "balance", "total_balance", "available_balance"])
        }
        let todayEntry = makeUsageCounter(today)
        let totalEntry = makeUsageCounter(total)
        let dailyUsage = makeDailyUsage(payload)
        let derivedToday = aggregateDailyUsage(dailyUsage, date: QuotaDateFormatter.ymd(Date()))
        let derivedTotal = aggregateDailyUsage(dailyUsage, date: nil)
        let isValid = boolValue(value(in: payload, keys: ["is_valid", "isValid", "valid", "available", "is_available"]))
        let hasRecognizedData = balance != nil ||
            todayEntry != nil ||
            totalEntry != nil ||
            !dailyUsage.isEmpty

        guard hasRecognizedData else { return nil }

        let limit = quota.flatMap {
            firstNumber(in: $0, keys: ["limit", "total", "maximum", "credit_limit"])
        }
        let used = quota.flatMap {
            firstNumber(in: $0, keys: ["used", "usage", "consumed", "spent", "amount_used"])
        }
        let remaining = quota.flatMap {
            firstNumber(in: $0, keys: ["remaining", "balance", "available", "available_balance"])
        }
        let quotaSummary = (limit != nil || used != nil || remaining != nil)
            ? QuotaSummary(limit: limit, used: used, remaining: remaining)
            : nil

        return UsageResponse(
            balance: balance,
            dailyUsage: dailyUsage.isEmpty ? nil : dailyUsage,
            isValid: isValid,
            mode: stringValue(value(in: payload, keys: ["mode", "provider", "provider_name"])) ?? "compatible",
            planName: stringValue(value(in: payload, keys: ["plan_name", "planName", "plan", "label"])) ?? "兼容接口",
            remaining: remaining ?? balance,
            unit: stringValue(value(in: payload, keys: ["unit", "currency", "currency_code"])) ?? "",
            usage: (todayEntry ?? derivedToday) != nil || (totalEntry ?? derivedTotal) != nil
                ? UsageSummary(
                    averageDurationMs: nil,
                    rpm: nil,
                    tpm: nil,
                    today: todayEntry ?? derivedToday,
                    total: totalEntry ?? derivedTotal
                )
                : nil,
            quota: quotaSummary,
            rateLimits: nil,
            subscription: nil,
            expiresAt: nil,
            daysUntilExpiry: nil,
            modelStats: nil
        )
    }

    private static func makeUsageCounter(_ object: [String: Any]?) -> UsageCounterEntry? {
        guard let object else { return nil }
        let entry = UsageCounterEntry(
            actualCost: firstNumber(in: object, keys: ["actual_cost", "actualCost", "cost", "total_cost", "amount", "spent", "usage_amount"]),
            cacheCreationTokens: firstNumber(in: object, keys: ["cache_creation_tokens", "cacheCreationTokens"]),
            cacheReadTokens: firstNumber(in: object, keys: ["cache_read_tokens", "cacheReadTokens"]),
            cost: firstNumber(in: object, keys: ["cost", "actual_cost", "actualCost", "amount", "spent"]),
            inputTokens: firstNumber(in: object, keys: ["input_tokens", "inputTokens", "prompt_tokens", "prompt_token_count", "input_token_count"]),
            outputTokens: firstNumber(in: object, keys: ["output_tokens", "outputTokens", "completion_tokens", "generated_tokens", "output_token_count"]),
            requests: firstNumber(in: object, keys: ["requests", "request_count", "requests_count", "num_model_requests", "api_calls", "calls"]),
            totalTokens: firstNumber(in: object, keys: ["total_tokens", "totalTokens", "tokens", "token_count", "total_token_count", "tokens_used"]),
            cacheWriteTokens: firstNumber(in: object, keys: ["cache_write_tokens", "cacheWriteTokens"])
        )
        return entry.actualCost != nil ||
            entry.cacheCreationTokens != nil ||
            entry.cacheReadTokens != nil ||
            entry.cost != nil ||
            entry.inputTokens != nil ||
            entry.outputTokens != nil ||
            entry.requests != nil ||
            entry.totalTokens != nil ||
            entry.cacheWriteTokens != nil
            ? entry
            : nil
    }

    private static func makeDailyUsage(_ payload: [String: Any]) -> [DailyUsageEntry] {
        let rawRows = (value(in: payload, keys: ["daily_usage", "dailyUsage", "records", "daily", "items", "data"]) as? [[String: Any]]) ?? []

        return rawRows.compactMap { row in
            guard let date = dateValue(value(in: row, keys: ["date", "day", "period", "start_date", "startDate", "start_time", "startTime", "timestamp"])) else {
                return nil
            }
            return DailyUsageEntry(
                date: date,
                requests: firstNumber(in: row, keys: ["requests", "request_count", "requests_count", "num_model_requests", "api_calls", "calls"]),
                inputTokens: firstNumber(in: row, keys: ["input_tokens", "inputTokens", "prompt_tokens", "prompt_token_count", "input_token_count"]),
                outputTokens: firstNumber(in: row, keys: ["output_tokens", "outputTokens", "completion_tokens", "generated_tokens", "output_token_count"]),
                cacheReadTokens: firstNumber(in: row, keys: ["cache_read_tokens", "cacheReadTokens"]),
                cacheWriteTokens: firstNumber(in: row, keys: ["cache_write_tokens", "cacheWriteTokens"]),
                actualCost: firstNumber(in: row, keys: ["actual_cost", "actualCost", "cost", "amount", "spent"]),
                cost: firstNumber(in: row, keys: ["cost", "actual_cost", "actualCost", "amount", "spent"]),
                totalTokens: firstNumber(in: row, keys: ["total_tokens", "totalTokens", "tokens", "token_count", "total_token_count", "tokens_used"])
            )
        }
    }

    private static func aggregateDailyUsage(_ rows: [DailyUsageEntry], date: String?) -> UsageCounterEntry? {
        let selected = date == nil ? rows : rows.filter { $0.date == date }
        guard !selected.isEmpty else { return nil }
        func sum(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : present.reduce(0, +)
        }
        return UsageCounterEntry(
            actualCost: sum(selected.map { $0.actualCost }),
            cacheCreationTokens: nil,
            cacheReadTokens: sum(selected.map { $0.cacheReadTokens }),
            cost: sum(selected.map { $0.cost }),
            inputTokens: sum(selected.map { $0.inputTokens }),
            outputTokens: sum(selected.map { $0.outputTokens }),
            requests: sum(selected.map { $0.requests }),
            totalTokens: sum(selected.map { $0.totalTokens }),
            cacheWriteTokens: sum(selected.map { $0.cacheWriteTokens })
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func firstNumber(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = numberValue(value(in: object, keys: [key])) {
                return value
            }
        }
        return nil
    }

    /// Providers disagree on casing and separators (for example
    /// `totalTokens`, `TOTAL_TOKENS`, and `total-tokens`). Normalize these
    /// variations before looking up a field rather than requiring a preset.
    private static func value(in object: [String: Any]?, keys: [String]) -> Any? {
        guard let object else { return nil }
        let wanted = Set(keys.map(normalisedFieldName))
        return object.first { wanted.contains(normalisedFieldName($0.key)) }?.value
    }

    private static func normalisedFieldName(_ key: String) -> String {
        key.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).lowercased() }
            .joined()
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func dateValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let timestamp = numberValue(value) {
            return QuotaDateFormatter.ymd(Date(timeIntervalSince1970: timestamp))
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? String {
            return Bool(value)
        }
        return nil
    }

    private static func decodeOpenRouterResponse(from data: Data, response: URLResponse) throws -> UsageResponse {
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.server(-1, "没有收到有效响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = extractMessage(from: data)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw UsageClientError.unauthorized(message)
            }
            throw UsageClientError.server(http.statusCode, message)
        }

        let decoder = makeDecoder()
        do {
            let payload = try decoder.decode(OpenRouterKeyResponse.self, from: data)
            return adaptOpenRouter(payload.data)
        } catch {
            throw UsageClientError.decoding(error.localizedDescription)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .formatted(QuotaDateFormatter.dateOnly)
        return decoder
    }

    private static func looksLikeUsageResponse(_ object: [String: Any]) -> Bool {
        if value(in: object, keys: ["balance", "remaining", "available_balance", "credit_balance"]) != nil {
            return true
        }
        if value(in: object, keys: ["quota", "rateLimits", "subscription", "usage", "daily_usage", "records"]) != nil {
            return true
        }
        return false
    }

    private static func shouldFallbackToOpenRouter(baseURL: URL, error: Error) -> Bool {
        guard baseURL.host?.localizedCaseInsensitiveContains("openrouter.ai") == true else { return false }
        if let clientError = error as? UsageClientError {
            switch clientError {
            case .server(let code, _):
                return code == 404 || code == 405 || code == 410
            case .decoding:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func isDeepSeekHost(_ baseURL: URL) -> Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "api.deepseek.com" || host == "platform.deepseek.com"
    }

    private static func webDashboardMessage(for baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased() else { return nil }
        switch host {
        case "platform.openai.com":
            return "这是 OpenAI 网页地址，不是 API 地址。请填写 API 根地址；组织用量查询还需要 Admin API Key。"
        case "console.anthropic.com":
            return "这是 Anthropic 网页地址，不是 API 地址。请填写 API 根地址；组织用量查询需要 Admin API Key。"
        case "aistudio.google.com":
            return "这是 Google AI Studio 网页地址，不是 API 地址。普通 Gemini API Key 不能直接查询账户累计用量。"
        case "console.groq.com":
            return "这是 Groq 网页地址，不是 API 地址。请填写实际 API 根地址或中转站 Usage 接口。"
        default:
            return nil
        }
    }

    private static func extractMessage(from data: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(data: data, encoding: .utf8) ?? "" }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = obj["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func adaptOpenRouter(_ payload: OpenRouterKeyData) -> UsageResponse {
        let today = QuotaDateFormatter.ymd(Date())
        let usageToday = payload.usageDaily ?? payload.byokUsageDaily ?? payload.usage ?? 0
        let usageTotal = payload.usage ?? payload.byokUsage ?? usageToday
        let limit = payload.limit
        let remaining = payload.limitRemaining
        let used = limit.flatMap { max($0 - (remaining ?? usageTotal), 0) } ?? usageTotal
        let quota = QuotaSummary(limit: limit, used: used, remaining: remaining)
        let dailyUsage = [
            DailyUsageEntry(
                date: today,
                requests: nil,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                actualCost: usageToday,
                cost: usageToday,
                totalTokens: nil
            )
        ]
        let usage = UsageSummary(
            averageDurationMs: nil,
            rpm: nil,
            tpm: nil,
            today: UsageCounterEntry(
                actualCost: usageToday,
                cacheCreationTokens: nil,
                cacheReadTokens: nil,
                cost: usageToday,
                inputTokens: nil,
                outputTokens: nil,
                requests: nil,
                totalTokens: nil,
                cacheWriteTokens: nil
            ),
            total: UsageCounterEntry(
                actualCost: usageTotal,
                cacheCreationTokens: nil,
                cacheReadTokens: nil,
                cost: usageTotal,
                inputTokens: nil,
                outputTokens: nil,
                requests: nil,
                totalTokens: nil,
                cacheWriteTokens: nil
            )
        )
        let rateLimits: [RateLimitEntry]? = limit.map {
            [
                RateLimitEntry(
                    window: "month",
                    limit: $0,
                    used: used,
                    resetAt: payload.limitReset
                )
            ]
        }

        return UsageResponse(
            balance: remaining ?? limit,
            dailyUsage: dailyUsage,
            isValid: true,
            mode: "openrouter",
            planName: payload.label,
            remaining: remaining,
            unit: "credits",
            usage: usage,
            quota: quota,
            rateLimits: rateLimits,
            subscription: nil,
            expiresAt: payload.limitReset,
            daysUntilExpiry: nil,
            modelStats: nil
        )
    }

    private struct OpenRouterKeyResponse: Decodable {
        let data: OpenRouterKeyData
    }

    private struct DeepSeekBalanceResponse: Decodable {
        let isAvailable: Bool
        let balanceInfos: [DeepSeekBalanceInfo]
    }

    private struct DeepSeekBalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String
    }

    private struct OpenRouterKeyData: Decodable {
        let label: String?
        let limit: Double?
        let limitReset: String?
        let limitRemaining: Double?
        let usage: Double?
        let usageDaily: Double?
        let usageWeekly: Double?
        let usageMonthly: Double?
        let byokUsage: Double?
        let byokUsageDaily: Double?
        let byokUsageWeekly: Double?
        let byokUsageMonthly: Double?
        let includeByokInLimit: Bool?
        let isFreeTier: Bool?
    }
}

struct UsageResponse: Decodable {
    let balance: Double?
    let dailyUsage: [DailyUsageEntry]?
    let isValid: Bool?
    let mode: String?
    let planName: String?
    let remaining: Double?
    let unit: String?
    let usage: UsageSummary?

    let quota: QuotaSummary?
    let rateLimits: [RateLimitEntry]?
    let subscription: SubscriptionSummary?
    let expiresAt: String?
    let daysUntilExpiry: Int?
    let modelStats: [ModelStat]?

    private enum CodingKeys: String, CodingKey {
        case balance, dailyUsage, isValid, mode, planName, remaining, unit, usage
        case quota, rateLimits, subscription, expiresAt, daysUntilExpiry, modelStats
    }
}

typealias UsageSnapshot = UsageResponse

struct QuotaSummary: Decodable {
    let limit: Double?
    let used: Double?
    let remaining: Double?
}

struct RateLimitEntry: Decodable {
    let window: String?
    let limit: Double?
    let used: Double?
    let resetAt: String?
}

struct SubscriptionSummary: Decodable {
    let dailyLimitUsd: Double?
    let dailyUsageUsd: Double?
    let weeklyLimitUsd: Double?
    let weeklyUsageUsd: Double?
    let monthlyLimitUsd: Double?
    let monthlyUsageUsd: Double?
    let expiresAt: String?
}

struct UsageSummary: Decodable {
    let averageDurationMs: Double?
    let rpm: Double?
    let tpm: Double?
    let today: UsageCounterEntry?
    let total: UsageCounterEntry?
}

struct UsageCounterEntry: Decodable {
    let actualCost: Double?
    let cacheCreationTokens: Double?
    let cacheReadTokens: Double?
    let cost: Double?
    let inputTokens: Double?
    let outputTokens: Double?
    let requests: Double?
    let totalTokens: Double?
    let cacheWriteTokens: Double?
}

struct DailyUsageEntry: Decodable {
    let date: String?
    let requests: Double?
    let inputTokens: Double?
    let outputTokens: Double?
    let cacheReadTokens: Double?
    let cacheWriteTokens: Double?
    let actualCost: Double?
    let cost: Double?
    let totalTokens: Double?
}

struct ModelStat: Decodable {
    let model: String?
    let requests: Double?
    let inputTokens: Double?
    let outputTokens: Double?
    let cacheCreationTokens: Double?
    let cacheReadTokens: Double?
    let totalTokens: Double?
    let actualCost: Double?
    let cost: Double?
}

private enum UsageDisplayStyle {
    case tokens
    case credits
    case dollars
}

enum QuotaDateFormatter {
    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func ymd(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

enum KeychainHelper {
    static let service = "com.codex.quotameter"
    static let account = "api-key"

    static func save(apiKey: String, service: String, account: String) {
        let data = Data(apiKey.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var existingItem: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &existingItem) == errSecSuccess {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func read(apiKeyFor account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct QuotaPopoverView: View {
    @ObservedObject var store: QuotaStore
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if store.isRefreshing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }

                if let message = store.errorMessage {
                    banner(text: message, background: Color.orange.opacity(0.12), foreground: .orange)
                }

                if !store.hasStoredKey {
                    banner(text: "先在设置里保存 API Key", background: Color.blue.opacity(0.12), foreground: .blue)
                }

                if let snapshot = store.snapshot {
                    balanceSection(snapshot)
                    summaryGrid(snapshot)
                    if let limits = visibleRateLimits(snapshot), !limits.isEmpty {
                        let style = usageDisplayStyle(for: snapshot)
                        sectionTitle("限额")
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(limits.enumerated()), id: \.offset) { _, item in
                                rateLimitRow(item, style: style)
                            }
                        }
                    }
                    dailyUsageSection(snapshot)
                    tokenSection(snapshot)
                } else if store.hasStoredKey && !store.isRefreshing {
                    banner(text: "暂时没有可显示的数据", background: Color.gray.opacity(0.12), foreground: .secondary)
                }

                footer
            }
            .padding(16)
            .frame(width: 420, alignment: .leading)
        }
        .frame(width: 420, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API 额度")
                    .font(.system(size: 18, weight: .semibold))
                Text(store.snapshot?.planName ?? (store.hasStoredKey ? "实时刷新" : "等待密钥"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                iconButton("arrow.clockwise", action: onRefresh)
                iconButton("gearshape", action: onOpenSettings)
                iconButton("power", action: onQuit)
            }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func banner(text: String, background: Color, foreground: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(foreground)
            Text(text)
                .font(.caption)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
    }

    private func balanceSection(_ snapshot: UsageResponse) -> some View {
        let style = balanceDisplayStyle(for: snapshot)
        let balance = displayAmount(snapshot.remaining ?? snapshot.balance, style: style)
        let subtitle: String
        switch style {
        case .tokens:
            subtitle = "剩余 token"
        case .credits:
            subtitle = "剩余额度"
        case .dollars:
            subtitle = "钱包余额"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(balance)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
                Text(snapshot.isValid == false ? "已停用" : "有效")
                Text("·")
                Text(snapshot.mode ?? "-")
                if let unit = snapshot.unit, !unit.isEmpty {
                    Text("·")
                    Text(unit)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func summaryGrid(_ snapshot: UsageResponse) -> some View {
        let style = usageDisplayStyle(for: snapshot)
        let today = snapshot.usage?.today
        let total = snapshot.usage?.total
        return LazyVGrid(columns: gridColumns, spacing: 10) {
            metricTile(title: summaryTitle(for: .today, style: style), value: displayAmount(summaryMetricValue(today, style: style), style: style))
            metricTile(title: summaryTitle(for: .total, style: style), value: displayAmount(summaryMetricValue(total, style: style), style: style))
            metricTile(title: "今日请求", value: displayCount(today?.requests))
            metricTile(title: "累计请求", value: displayCount(total?.requests))
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func visibleRateLimits(_ snapshot: UsageResponse) -> [RateLimitEntry]? {
        snapshot.rateLimits?.filter { $0.window != nil }
    }

    private func rateLimitRow(_ item: RateLimitEntry, style: UsageDisplayStyle) -> some View {
        let used = item.used ?? 0
        let limit = item.limit ?? 0
        let ratio = limit > 0 ? min(used / limit, 1) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(rateLimitTitle(item.window))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(displayAmount(used, style: style)) / \(displayAmount(limit, style: style))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: ratio)
                .tint(progressTint(ratio))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func dailyUsageSection(_ snapshot: UsageResponse) -> some View {
        let style = usageDisplayStyle(for: snapshot)
        let rows = (snapshot.dailyUsage ?? [])
            .compactMap { row -> DailyDisplayRow? in
                guard let date = row.date else { return nil }
                let amount: Double
                let cost = row.actualCost ?? row.cost
                switch style {
                case .tokens:
                    amount = row.totalTokens ?? cost ?? row.requests ?? 0
                case .credits, .dollars:
                    amount = cost ?? row.totalTokens ?? row.requests ?? 0
                }
                return DailyDisplayRow(
                    date: date,
                    requests: row.requests ?? 0,
                    amount: amount,
                    cost: cost,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    hasTokenBreakdown: row.totalTokens != nil || row.inputTokens != nil || row.outputTokens != nil
                )
            }
            .sorted { $0.date > $1.date }
            .prefix(7)

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("每日使用")
            if rows.isEmpty {
                Text("暂无每日记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        dailyRow(row, style: style)
                    }
                }
            }
        }
    }

    private func dailyRow(_ row: DailyDisplayRow, style: UsageDisplayStyle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.date)
                    .font(.subheadline.weight(.medium))
                if row.hasTokenBreakdown {
                    Text("输入 \(displayTokens(row.inputTokens)) · 输出 \(displayTokens(row.outputTokens))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if row.requests > 0 {
                    Text("\(displayCount(row.requests)) req")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(displayAmount(row.amount, style: style))
                    .font(.subheadline.weight(.semibold))
                if row.hasTokenBreakdown {
                    Text("\(displayCount(row.requests)) req\(row.cost == nil ? "" : " · " + displayMoney(row.cost))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if row.requests > 0 {
                    Text("\(displayCount(row.requests)) req")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    private func tokenSection(_ snapshot: UsageResponse) -> some View {
        let style = usageDisplayStyle(for: snapshot)
        let total = snapshot.usage?.total
        let lines = detailLines(for: snapshot, style: style, total: total)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("累计明细")
            VStack(spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(displayAmount(item.1, style: style))
                            .font(.caption.weight(.medium))
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text(store.lastUpdated.map { "更新于 \(timeString($0))" } ?? "等待刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let interval = store.hasStoredKey ? store.refreshIntervalSeconds : nil {
                    Text("每 \(interval) 秒刷新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func progressTint(_ ratio: Double) -> Color {
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .green
    }

    private func rateLimitTitle(_ window: String?) -> String {
        switch window {
        case "5h":
            return "5 小时"
        case "1d":
            return "1 天"
        case "7d":
            return "7 天"
        case "month", "monthly":
            return "每月"
        default:
            return window ?? "-"
        }
    }

    private enum SummaryKind {
        case today
        case total
    }

    private func usageDisplayStyle(for snapshot: UsageResponse) -> UsageDisplayStyle {
        let total = snapshot.usage?.total
        if total?.totalTokens != nil || total?.inputTokens != nil || total?.outputTokens != nil || total?.cacheCreationTokens != nil || total?.cacheReadTokens != nil {
            return .tokens
        }
        let unit = snapshot.unit?.lowercased() ?? ""
        if unit.contains("credit") || snapshot.mode == "openrouter" {
            return .credits
        }
        if unit.contains("usd") || unit.contains("dollar") {
            return .dollars
        }
        return .credits
    }

    private func balanceDisplayStyle(for snapshot: UsageResponse) -> UsageDisplayStyle {
        if snapshot.mode?.hasPrefix("deepseek") == true {
            return .credits
        }
        let unit = snapshot.unit?.lowercased() ?? ""
        if unit.contains("credit") || snapshot.mode == "openrouter" {
            return .credits
        }
        if unit.contains("usd") || unit.contains("dollar") {
            return .dollars
        }
        return .dollars
    }

    private func summaryTitle(for kind: SummaryKind, style: UsageDisplayStyle) -> String {
        // Data from balance-only providers is a local ledger, not an official
        // server-side usage report. Keep that distinction visible in the UI.
        if store.snapshot?.mode?.hasSuffix("-local") == true {
            switch kind {
            case .today: return "今日消耗（本机）"
            case .total: return "累计消耗（本机）"
            }
        }
        switch (kind, style) {
        case (.today, .tokens):
            return "今日 token"
        case (.total, .tokens):
            return "累计 token"
        case (.today, .credits):
            return "今日使用"
        case (.total, .credits):
            return "累计使用"
        case (.today, .dollars):
            return "今日花费"
        case (.total, .dollars):
            return "累计花费"
        }
    }

    private func summaryMetricValue(_ entry: UsageCounterEntry?, style: UsageDisplayStyle) -> Double? {
        guard let entry else { return nil }
        switch style {
        case .tokens:
            return entry.totalTokens ?? entry.inputTokens ?? entry.outputTokens ?? entry.requests
        case .credits, .dollars:
            return entry.actualCost ?? entry.cost ?? entry.totalTokens ?? entry.requests
        }
    }

    private func detailLines(for snapshot: UsageResponse, style: UsageDisplayStyle, total: UsageCounterEntry?) -> [(String, Double?)] {
        switch style {
        case .tokens:
            return [
                ("输入 token", total?.inputTokens),
                ("输出 token", total?.outputTokens),
                ("缓存创建", total?.cacheCreationTokens),
                ("缓存读取", total?.cacheReadTokens),
                ("总 token", total?.totalTokens)
            ]
        case .credits, .dollars:
            return [
                ("限额", snapshot.quota?.limit),
                ("已用", snapshot.quota?.used ?? total?.actualCost ?? total?.cost),
                ("剩余", snapshot.quota?.remaining),
                ("今日使用", snapshot.usage?.today?.actualCost ?? snapshot.usage?.today?.cost),
                ("累计使用", total?.actualCost ?? total?.cost)
            ]
        }
    }

    private func displayAmount(_ value: Double?, style: UsageDisplayStyle) -> String {
        guard let value else { return "-" }
        switch style {
        case .tokens:
            return displayTokens(value)
        case .credits:
            return Self.amountFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
        case .dollars:
            let formatted = Self.amountFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
            return "$" + formatted
        }
    }

    private func displayMoney(_ value: Double?) -> String {
        guard let value else { return "-" }
        let formatted = Self.amountFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
        return "$" + formatted
    }

    private func displayTokens(_ value: Double?) -> String {
        guard let value else { return "-" }
        return Self.integerFormatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    private func displayCount(_ value: Double?) -> String {
        guard let value else { return "-" }
        return Self.integerFormatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    private func timeString(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private struct DailyDisplayRow {
        let date: String
        let requests: Double
        let amount: Double
        let cost: Double?
        let inputTokens: Double?
        let outputTokens: Double?
        let hasTokenBreakdown: Bool
    }

    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        formatter.groupingSeparator = ","
        return formatter
    }()

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = ","
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    @State private var baseURLString = ""
    @State private var providerPreset: APIProviderPreset = .auto
    @State private var usagePath = "/v1/usage"
    @State private var newAPIKey = ""
    @State private var platformToken = ""
    @State private var showAPIKey = false
    @State private var refreshInterval = 30.0
    @State private var statusMessage = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API 设置")
                .font(.system(size: 18, weight: .semibold))

            Text("密钥保存在本机 Keychain。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Base URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("https://your-api.example.com", text: $baseURLString)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        pasteBaseURL()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .help("粘贴 Base URL")
                }
                .frame(height: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text("接口类型")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $providerPreset) {
                        ForEach(APIProviderPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Usage Path")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(providerPreset == .deepSeek ? "/user/balance" : "/v1/usage", text: $usagePath)
                        .textFieldStyle(.roundedBorder)
                    .frame(height: 24)
                        .disabled(providerPreset == .openRouter || providerPreset == .deepSeek)
                }

                HStack {
                    Text("API Key")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Label(showAPIKey ? "隐藏" : "显示", systemImage: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                }

                Group {
                    if showAPIKey {
                        TextField("输入或粘贴新的 Key 后保存", text: $newAPIKey)
                    } else {
                        SecureField("输入或粘贴新的 Key 后保存", text: $newAPIKey)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Text("Usage / 官网访问令牌（可选；不同供应商的官网统计可能需要单独登录令牌）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                SecureField("可选：供应商 Usage 或官网访问令牌", text: $platformToken)
                .textFieldStyle(.roundedBorder)

                Button {
                    // Use the URL currently visible in the form, even before
                    // the user presses Save, so switching providers works
                    // without an intermediate save/refresh.
                    store.openDashboardLogin(baseURLString: baseURLString)
                } label: {
                    Label("网页登录并自动获取令牌", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                .help("打开供应商官网，在内置窗口中登录并自动读取官网登录态")
            }

            Stepper(value: $refreshInterval, in: 10...300, step: 5) {
                Text("刷新间隔 \(Int(refreshInterval)) 秒")
                    .font(.callout)
            }

            HStack {
                Button {
                    Task { await save() }
                } label: {
                    Label(isSaving ? "保存中" : "保存并刷新", systemImage: "checkmark.circle")
                }
                .disabled(isSaving)

                Button {
                    Task { await clearKey() }
                } label: {
                    Label("清除密钥", systemImage: "trash")
                }

                Spacer()

                Text(store.hasStoredKey ? "已保存" : "未保存")
                    .font(.caption)
                    .foregroundStyle(store.hasStoredKey ? Color.secondary : Color.orange)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 420, height: 460, alignment: .topLeading)
        .onAppear {
            baseURLString = store.baseURLString
            providerPreset = store.providerPreset
            usagePath = store.usagePath
            platformToken = store.platformToken
            refreshInterval = Double(store.refreshIntervalSeconds)
            statusMessage = store.hasStoredKey ? "密钥已加载" : "请先输入 API Key"
        }
        .onReceive(store.$platformToken) { value in
            if platformToken != value {
                platformToken = value
            }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmedKey = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.updateSettings(
            baseURL: baseURLString,
            refreshIntervalSeconds: Int(refreshInterval),
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            providerPreset: providerPreset,
            usagePath: usagePath,
            platformToken: platformToken
        )
        newAPIKey = ""
        statusMessage = store.errorMessage ?? "已刷新"
    }

    @MainActor
    private func clearKey() async {
        await store.clearStoredKey()
        newAPIKey = ""
        platformToken = ""
        statusMessage = "已清除密钥"
    }

    private func pasteFromClipboard() {
        if let value = NSPasteboard.general.string(forType: .string) {
            applyPastedKey(value)
        } else {
            statusMessage = "剪贴板里没有可粘贴的内容"
        }
    }

    private func pasteBaseURL() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            statusMessage = "剪贴板里没有可粘贴的内容"
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "剪贴板里没有可粘贴的内容"
            return
        }
        baseURLString = trimmed
        statusMessage = "已粘贴 Base URL"
    }

    private func applyPastedKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "剪贴板里没有可粘贴的内容"
            return
        }
        newAPIKey = trimmed
        statusMessage = "已从剪贴板粘贴"
    }
}

struct ClipboardTextField: NSViewRepresentable {
    @Binding var text: String
    var isSecure: Bool
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let field = makeField(context: context)
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.field = field
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let field = context.coordinator.field else { return }
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    private func makeField(context: Context) -> NSTextField {
        let field: NSTextField = isSecure
            ? ClipboardAwareSecureTextField()
            : ClipboardAwareTextField()
        field.stringValue = text
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.isContinuous = true
        field.isAutomaticTextCompletionEnabled = false
        return field
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        weak var field: NSTextField?

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        // macOS sends Command-A / Command-C to the shared field editor
        // (NSTextView), not to the NSTextField subclass. Handle them here so
        // secure and regular fields behave identically.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.selectAll(_:)) {
                textView.selectAll(nil)
                return true
            }
            if commandSelector == #selector(NSText.copy(_:)) {
                textView.copy(nil)
                return true
            }
            return false
        }
    }
}

class ClipboardAwareTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keep shortcuts bound to the focused field editor. Intercepting
        // Command-V here can redirect paste to the first SwiftUI field.
        return super.performKeyEquivalent(with: event)
    }
}

final class ClipboardAwareSecureTextField: NSSecureTextField, NSTextFieldDelegate {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keep shortcuts bound to the focused field editor.
        return super.performKeyEquivalent(with: event)
    }
}
