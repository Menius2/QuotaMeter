import AppKit
import Combine
import Security
import SwiftUI

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
        controller = StatusBarController()
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
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

enum APIProviderPreset: String, CaseIterable, Identifiable {
    case auto
    case compatible
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "自动"
        case .compatible:
            return "兼容接口"
        case .openRouter:
            return "OpenRouter"
        }
    }
}

struct AppConfiguration: Decodable {
    let baseURL: String?
    let apiKey: String?
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
    @Published var usagePath: String = "/usage"

    private var apiKey: String?
    private var pollingTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let configuration = AppConfiguration.load()
    private var hasPersistedBaseURL = false
    private var hasPersistedRefreshInterval = false
    private var hasPersistedProviderPreset = false
    private var hasPersistedUsagePath = false

    private enum DefaultsKey {
        static let baseURL = "QuotaMeter.baseURL"
        static let refreshInterval = "QuotaMeter.refreshInterval"
        static let providerPreset = "QuotaMeter.providerPreset"
        static let usagePath = "QuotaMeter.usagePath"
    }

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

    func refreshNow() async {
        guard !isRefreshing else { return }
        guard let key = apiKey, !key.isEmpty else {
            errorMessage = "请先在设置里输入 API Key"
            snapshot = nil
            return
        }
        guard let baseURL = normalisedBaseURL(baseURLString) else {
            errorMessage = "Base URL 无效"
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let data = try await UsageClient.fetchUsage(
                apiKey: key,
                baseURL: baseURL,
                providerPreset: providerPreset,
                usagePath: usagePath,
                daysBack: 3650
            )
            snapshot = data
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
        usagePath: String
    ) async {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsagePath = normalisedUsagePath(usagePath)
        defaults.set(trimmedBaseURL, forKey: DefaultsKey.baseURL)
        defaults.set(refreshIntervalSeconds, forKey: DefaultsKey.refreshInterval)
        defaults.set(providerPreset.rawValue, forKey: DefaultsKey.providerPreset)
        defaults.set(trimmedUsagePath, forKey: DefaultsKey.usagePath)
        self.baseURLString = trimmedBaseURL
        self.refreshIntervalSeconds = max(10, refreshIntervalSeconds)
        self.providerPreset = providerPreset
        self.usagePath = trimmedUsagePath

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
        KeychainHelper.delete(service: KeychainHelper.service, account: KeychainHelper.account)
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
            baseURLString = storedBaseURL
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
    }

    private func applyConfigurationFallbacks() {
        guard let configuration else { return }

        if !hasPersistedBaseURL, let baseURL = configuration.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !baseURL.isEmpty {
            baseURLString = baseURL
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
    }

    private func normalisedBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            return URL(string: trimmed)
        }
        if let url = URL(string: trimmed), url.host?.localizedCaseInsensitiveContains("openrouter.ai") == true {
            if trimmed.hasSuffix("/api") {
                return URL(string: trimmed + "/v1")
            }
            if url.path.isEmpty {
                return URL(string: trimmed + "/api/v1")
            }
        }
        return URL(string: trimmed + "/v1")
    }

    private func normalisedUsagePath(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "/usage"
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

enum UsageClientError: LocalizedError {
    case invalidURL
    case unauthorized(String)
    case server(Int, String)
    case decoding(String)

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
        }
    }
}

enum UsageClient {
    static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        providerPreset: APIProviderPreset,
        usagePath: String,
        daysBack: Int
    ) async throws -> UsageResponse {
        switch providerPreset {
        case .openRouter:
            return try await fetchOpenRouterUsage(apiKey: apiKey, baseURL: baseURL)
        case .compatible:
            return try await fetchCompatibleUsage(
                apiKey: apiKey,
                baseURL: baseURL,
                usagePath: usagePath,
                daysBack: daysBack
            )
        case .auto:
            do {
                return try await fetchCompatibleUsage(
                    apiKey: apiKey,
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
        baseURL: URL,
        usagePath: String,
        daysBack: Int
    ) async throws -> UsageResponse {
        guard let url = usageURL(baseURL: baseURL, usagePath: usagePath, daysBack: daysBack) else {
            throw UsageClientError.invalidURL
        }
        let (data, response) = try await sendRequest(url: url, apiKey: apiKey)
        return try decodeUsageResponse(from: data, response: response)
    }

    private static func fetchOpenRouterUsage(apiKey: String, baseURL: URL) async throws -> UsageResponse {
        guard let url = openRouterURL(baseURL: baseURL) else {
            throw UsageClientError.invalidURL
        }
        let (data, response) = try await sendRequest(url: url, apiKey: apiKey)
        return try decodeOpenRouterResponse(from: data, response: response)
    }

    private static func sendRequest(url: URL, apiKey: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request)
    }

    private static func usageURL(baseURL: URL, usagePath: String, daysBack: Int) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        let endpoint = normalisedRelativePath(usagePath)
        components?.path = joinPaths(path, endpoint)

        let end = QuotaDateFormatter.ymd(Date())
        let start = QuotaDateFormatter.ymd(Calendar.current.date(byAdding: .day, value: -max(1, daysBack), to: Date()) ?? Date())
        components?.queryItems = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier)
        ]
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
            path = "/usage"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func joinPaths(_ base: String, _ addition: String) -> String {
        let left = base.hasSuffix("/") ? String(base.dropLast()) : base
        let right = addition.hasPrefix("/") ? addition : "/" + addition
        if left.isEmpty {
            return right
        }
        return left + right
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
        if let response = try? decoder.decode(UsageResponse.self, from: data) {
            return response
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let nested = json["data"] as? [String: Any], looksLikeUsageResponse(nested) {
                let nestedData = try JSONSerialization.data(withJSONObject: nested)
                if let response = try? decoder.decode(UsageResponse.self, from: nestedData) {
                    return response
                }
            }
            if let nested = json["result"] as? [String: Any], looksLikeUsageResponse(nested) {
                let nestedData = try JSONSerialization.data(withJSONObject: nested)
                if let response = try? decoder.decode(UsageResponse.self, from: nestedData) {
                    return response
                }
            }
        }

        throw UsageClientError.decoding("无法识别接口返回格式")
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
        if object["balance"] != nil || object["remaining"] != nil {
            return true
        }
        if object["quota"] != nil || object["rateLimits"] != nil || object["subscription"] != nil {
            return true
        }
        if object["usage"] is [String: Any] || object["dailyUsage"] is [[String: Any]] || object["modelStats"] is [[String: Any]] {
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
    @State private var usagePath = "/usage"
    @State private var newAPIKey = ""
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
                TextField("https://your-api.example.com", text: $baseURLString)
                    .textFieldStyle(.roundedBorder)

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
                    TextField("/usage", text: $usagePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(providerPreset == .openRouter)
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
                    APIKeyInputField(
                        text: $newAPIKey,
                        isSecure: !showAPIKey,
                        placeholder: "输入或粘贴新的 Key 后保存"
                    )
                    .id(showAPIKey)
                }
                .textFieldStyle(.roundedBorder)
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
        .frame(width: 420, height: 380, alignment: .topLeading)
        .onAppear {
            baseURLString = store.baseURLString
            providerPreset = store.providerPreset
            usagePath = store.usagePath
            refreshInterval = Double(store.refreshIntervalSeconds)
            statusMessage = store.hasStoredKey ? "密钥已加载" : "请先输入 API Key"
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
            usagePath: usagePath
        )
        newAPIKey = ""
        statusMessage = store.errorMessage ?? "已刷新"
    }

    @MainActor
    private func clearKey() async {
        await store.clearStoredKey()
        newAPIKey = ""
        statusMessage = "已清除密钥"
    }

    private func pasteFromClipboard() {
        if let value = NSPasteboard.general.string(forType: .string) {
            applyPastedKey(value)
        } else {
            statusMessage = "剪贴板里没有可粘贴的内容"
        }
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

struct APIKeyInputField: NSViewRepresentable {
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
        let field: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
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
    }
}
