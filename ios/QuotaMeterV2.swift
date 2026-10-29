import CryptoKit
import Security
import SwiftUI
import UIKit

enum APIPlatform: String, Codable, CaseIterable, Identifiable {
    case codex
    case openRouter
    case deepSeek
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "OpenAI / Codex"
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek"
        case .compatible: return "自定义兼容 API"
        }
    }

    var shortTitle: String {
        switch self {
        case .codex: return "Codex"
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek"
        case .compatible: return "自定义"
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "sparkles"
        case .openRouter: return "arrow.triangle.branch"
        case .deepSeek: return "wave.3.right"
        case .compatible: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .codex: return .blue
        case .openRouter: return .orange
        case .deepSeek: return .green
        case .compatible: return .purple
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .codex: return "https://api.openai.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .deepSeek: return "https://api.deepseek.com"
        case .compatible: return "https://your-api.example.com"
        }
    }

    var defaultUsagePath: String {
        switch self {
        case .openRouter: return "/key"
        case .deepSeek: return "/user/balance"
        default: return "/v1/usage"
        }
    }

    var defaultWebsiteURL: String {
        switch self {
        case .codex: return "https://platform.openai.com"
        case .openRouter: return "https://openrouter.ai"
        case .deepSeek: return "https://platform.deepseek.com/usage"
        case .compatible: return ""
        }
    }

    var apiProviderPreset: APIProviderPreset {
        switch self {
        case .codex: return .auto
        case .openRouter: return .openRouter
        case .deepSeek: return .deepSeek
        case .compatible: return .compatible
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct APIBinding: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var platform: APIPlatform
    var baseURL: String
    var usagePath: String
    var websiteURL: String?
    var refreshIntervalSeconds: Int

    init(
        id: UUID = UUID(),
        name: String,
        platform: APIPlatform,
        baseURL: String,
        usagePath: String,
        websiteURL: String? = nil,
        refreshIntervalSeconds: Int = 30
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.baseURL = baseURL
        self.usagePath = usagePath
        self.websiteURL = websiteURL
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }
}

struct LocalAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var username: String
    var displayName: String
    var createdAt: Date
    var bindings: [APIBinding]
    var activeBindingID: UUID?

    init(
        id: UUID = UUID(),
        username: String,
        displayName: String,
        createdAt: Date = Date(),
        bindings: [APIBinding] = [],
        activeBindingID: UUID? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.createdAt = createdAt
        self.bindings = bindings
        self.activeBindingID = activeBindingID
    }

    var initials: String {
        let source = displayName.isEmpty ? username : displayName
        return String(source.prefix(2)).uppercased()
    }
}

struct APIBindingDraft {
    var name: String
    var platform: APIPlatform
    var baseURL: String
    var usagePath: String
    var websiteURL: String
    var refreshIntervalSeconds: Int
    var apiKey: String
    var platformToken: String
}

struct FeedbackEntry: Identifiable, Codable {
    let id: UUID
    let category: String
    let message: String
    let contact: String
    let createdAt: Date
}

private enum LocalAuthError: LocalizedError {
    case emptyUsername
    case shortPassword
    case usernameExists
    case accountNotFound
    case incorrectPassword

    var errorDescription: String? {
        switch self {
        case .emptyUsername: return "请输入账户名称"
        case .shortPassword: return "密码至少需要 6 位"
        case .usernameExists: return "这个账户名称已经被使用"
        case .accountNotFound: return "没有找到这个本地账户"
        case .incorrectPassword: return "密码不正确"
        }
    }
}

private enum LocalPasswordHasher {
    static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return Data(UUID().uuidString.utf8)
        }
        return Data(bytes)
    }

    static func digest(password: String, username: String, salt: Data) -> Data {
        let input = salt + Data("\(username.lowercased()):\(password)".utf8)
        var value = Data(SHA256.hash(data: input))
        for _ in 0..<4_000 {
            value = Data(SHA256.hash(data: value + salt))
        }
        return value
    }
}

@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var accounts: [LocalAccount] = []
    @Published private(set) var currentAccount: LocalAccount?
    @Published private(set) var activeBindingID: UUID?
    @Published var authMessage: String?

    private let defaults = UserDefaults.standard
    private let accountsKey = "QuotaMeter.localAccounts.v2"
    private let sessionKey = "QuotaMeter.localSession.v2"
    private let passwordService = "com.codex.quotameter.local-auth"
    private var bindingStores: [UUID: QuotaStore] = [:]

    init() {
        loadAccounts()

#if DEBUG
        if ProcessInfo.processInfo.environment["QUOTAMETER_DEMO"] == "1" {
            activateDemo()
            return
        }
#endif

        if let sessionID = defaults.string(forKey: sessionKey),
           let account = accounts.first(where: { $0.id.uuidString == sessionID }) {
            activate(account)
        }
    }

    var activeBinding: APIBinding? {
        guard let currentAccount else { return nil }
        return currentAccount.bindings.first { $0.id == activeBindingID }
    }

    var activeStore: QuotaStore? {
        guard let activeBindingID else { return nil }
        return bindingStores[activeBindingID]
    }

    func store(for bindingID: UUID) -> QuotaStore? {
        bindingStores[bindingID]
    }

    @discardableResult
    func signIn(username: String, password: String) -> Bool {
        let normalisedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalisedUsername.isEmpty else {
            authMessage = LocalAuthError.emptyUsername.localizedDescription
            return false
        }
        guard let account = accounts.first(where: {
            $0.username.localizedCaseInsensitiveCompare(normalisedUsername) == .orderedSame
        }) else {
            authMessage = LocalAuthError.accountNotFound.localizedDescription
            return false
        }
        guard verifyPassword(password, for: account) else {
            authMessage = LocalAuthError.incorrectPassword.localizedDescription
            return false
        }
        authMessage = nil
        defaults.set(account.id.uuidString, forKey: sessionKey)
        activate(account)
        return true
    }

    @discardableResult
    func register(username: String, displayName: String, password: String) -> Bool {
        let normalisedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalisedUsername.isEmpty else {
            authMessage = LocalAuthError.emptyUsername.localizedDescription
            return false
        }
        guard password.count >= 6 else {
            authMessage = LocalAuthError.shortPassword.localizedDescription
            return false
        }
        guard !accounts.contains(where: {
            $0.username.localizedCaseInsensitiveCompare(normalisedUsername) == .orderedSame
        }) else {
            authMessage = LocalAuthError.usernameExists.localizedDescription
            return false
        }

        let account = LocalAccount(
            username: normalisedUsername,
            displayName: normalisedDisplayName.isEmpty ? normalisedUsername : normalisedDisplayName
        )
        savePassword(password, for: account)
        accounts.append(account)
        persistAccounts()
        defaults.set(account.id.uuidString, forKey: sessionKey)
        authMessage = nil
        activate(account)
        return true
    }

    func signOut() {
        defaults.removeObject(forKey: sessionKey)
        currentAccount = nil
        activeBindingID = nil
        bindingStores.removeAll()
        authMessage = nil
    }

    func selectBinding(_ bindingID: UUID) {
        guard var account = currentAccount,
              account.bindings.contains(where: { $0.id == bindingID }) else { return }
        account.activeBindingID = bindingID
        replaceCurrentAccount(account)
        activeBindingID = bindingID
    }

    @discardableResult
    func addBinding(_ draft: APIBindingDraft) async -> Bool {
        guard var account = currentAccount else { return false }
        guard !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            authMessage = "请填写 API Key"
            return false
        }

        let binding = APIBinding(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            platform: draft.platform,
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            usagePath: draft.usagePath.trimmingCharacters(in: .whitespacesAndNewlines),
            websiteURL: draft.websiteURL.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshIntervalSeconds: draft.refreshIntervalSeconds
        )
        account.bindings.append(binding)
        account.activeBindingID = binding.id
        replaceCurrentAccount(account)
        activeBindingID = binding.id

        let store = makeStore(for: binding, accountID: account.id)
        bindingStores[binding.id] = store
        await store.updateSettings(
            baseURL: binding.baseURL,
            refreshIntervalSeconds: binding.refreshIntervalSeconds,
            apiKey: draft.apiKey,
            providerPreset: binding.platform.apiProviderPreset,
            usagePath: binding.usagePath,
            platformToken: draft.platformToken
        )
        authMessage = nil
        return true
    }

    @discardableResult
    func updateBinding(id: UUID, draft: APIBindingDraft) async -> Bool {
        guard var account = currentAccount,
              let index = account.bindings.firstIndex(where: { $0.id == id }) else { return false }

        var binding = account.bindings[index]
        binding.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.platform = draft.platform
        binding.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.usagePath = draft.usagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.websiteURL = draft.websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.refreshIntervalSeconds = draft.refreshIntervalSeconds
        account.bindings[index] = binding
        replaceCurrentAccount(account)

        let store = bindingStores[id] ?? makeStore(for: binding, accountID: account.id)
        bindingStores[id] = store
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.updateSettings(
            baseURL: binding.baseURL,
            refreshIntervalSeconds: binding.refreshIntervalSeconds,
            apiKey: key.isEmpty ? nil : key,
            providerPreset: binding.platform.apiProviderPreset,
            usagePath: binding.usagePath,
            platformToken: draft.platformToken
        )
        authMessage = nil
        return true
    }

    func deleteBinding(_ bindingID: UUID) {
        guard var account = currentAccount else { return }
        bindingStores[bindingID]?.deletePersistedData()
        bindingStores.removeValue(forKey: bindingID)
        account.bindings.removeAll { $0.id == bindingID }

        if account.activeBindingID == bindingID {
            account.activeBindingID = account.bindings.first?.id
            activeBindingID = account.activeBindingID
        }
        replaceCurrentAccount(account)
    }

    func refreshAllBindings() async {
        for store in bindingStores.values {
            await store.refreshNow()
        }
    }

    func saveFeedback(category: String, message: String, contact: String) {
        guard let account = currentAccount else { return }
        var entries = feedbackEntries
        entries.insert(
            FeedbackEntry(
                id: UUID(),
                category: category,
                message: message,
                contact: contact,
                createdAt: Date()
            ),
            at: 0
        )
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: feedbackKey(for: account.id))
        }
    }

    var feedbackEntries: [FeedbackEntry] {
        guard let account = currentAccount,
              let data = defaults.data(forKey: feedbackKey(for: account.id)),
              let entries = try? JSONDecoder().decode([FeedbackEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func activate(_ account: LocalAccount) {
        var account = account
        if account.activeBindingID == nil {
            account.activeBindingID = account.bindings.first?.id
        }
        currentAccount = account
        activeBindingID = account.activeBindingID
        bindingStores.removeAll()
        for binding in account.bindings {
            bindingStores[binding.id] = makeStore(for: binding, accountID: account.id)
        }
    }

    private func makeStore(for binding: APIBinding, accountID: UUID) -> QuotaStore {
        let scope = "account-\(accountID.uuidString.lowercased()).binding-\(binding.id.uuidString.lowercased())"
        return QuotaStore(storageScope: scope)
    }

    private func replaceCurrentAccount(_ account: LocalAccount) {
        currentAccount = account
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persistAccounts()
    }

    private func loadAccounts() {
        guard let data = defaults.data(forKey: accountsKey),
              let savedAccounts = try? JSONDecoder().decode([LocalAccount].self, from: data) else {
            return
        }
        accounts = savedAccounts
    }

    private func persistAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: accountsKey)
    }

    private func passwordAccount(for accountID: UUID) -> String {
        "account-\(accountID.uuidString.lowercased())-password"
    }

    private func savePassword(_ password: String, for account: LocalAccount) {
        let salt = LocalPasswordHasher.makeSalt()
        let hash = LocalPasswordHasher.digest(
            password: password,
            username: account.username,
            salt: salt
        )
        let value = "\(salt.base64EncodedString()):\(hash.base64EncodedString())"
        KeychainHelper.save(
            apiKey: value,
            service: passwordService,
            account: passwordAccount(for: account.id)
        )
    }

    private func verifyPassword(_ password: String, for account: LocalAccount) -> Bool {
        guard let value = KeychainHelper.read(
            apiKeyFor: passwordAccount(for: account.id),
            service: passwordService
        ) else {
            return false
        }
        let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              let salt = Data(base64Encoded: pieces[0]),
              let expected = Data(base64Encoded: pieces[1]) else {
            return false
        }
        let actual = LocalPasswordHasher.digest(
            password: password,
            username: account.username,
            salt: salt
        )
        return actual == expected
    }

    private func feedbackKey(for accountID: UUID) -> String {
        "QuotaMeter.v2.account.\(accountID.uuidString.lowercased()).feedback"
    }

#if DEBUG
    private func activateDemo() {
        let bindings = [
            APIBinding(
                name: "DeepSeek",
                platform: .deepSeek,
                baseURL: "https://api.deepseek.com",
                usagePath: "/user/balance",
                websiteURL: "https://platform.deepseek.com/usage"
            ),
            APIBinding(
                name: "中转站",
                platform: .compatible,
                baseURL: "https://relay.example.com",
                usagePath: "/v1/usage",
                websiteURL: "https://relay.example.com"
            ),
            APIBinding(
                name: "OpenRouter",
                platform: .openRouter,
                baseURL: "https://openrouter.ai/api",
                usagePath: "/key",
                websiteURL: "https://openrouter.ai"
            )
        ]
        let account = LocalAccount(
            username: "menius",
            displayName: "Menius",
            bindings: bindings,
            activeBindingID: bindings[0].id
        )
        accounts = [account]
        currentAccount = account
        activeBindingID = bindings[0].id

        for binding in bindings {
            let store = makeStore(for: binding, accountID: account.id)
            bindingStores[binding.id] = store
            store.configureDemo(binding: binding, snapshot: DemoData.snapshot(for: binding.platform))
        }
    }
#endif
}

@main
struct QuotaMeterV2App: App {
    @StateObject private var accountManager = AccountManager()

    var body: some Scene {
        WindowGroup {
            AppearanceRootView(accountManager: accountManager)
        }
    }
}

private struct AppearanceRootView: View {
    @ObservedObject var accountManager: AccountManager
    @AppStorage("QuotaMeter.interfaceAppearance.v1")
    private var appearanceRawValue = AppAppearance.system.rawValue

    @ViewBuilder
    var body: some View {
        let appearance = AppAppearance(rawValue: appearanceRawValue) ?? .system
        if let colorScheme = appearance.colorScheme {
            QuotaMeterV2Root(accountManager: accountManager)
                .preferredColorScheme(colorScheme)
        } else {
            QuotaMeterV2Root(accountManager: accountManager)
        }
    }
}

private enum RootTab: Hashable {
    case dashboard
    case platforms
    case profile
}

private struct LaunchCompletedKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var launchCompleted: Bool {
        get { self[LaunchCompletedKey.self] }
        set { self[LaunchCompletedKey.self] = newValue }
    }
}

private struct QuotaMeterV2Root: View {
    @ObservedObject var accountManager: AccountManager

    var body: some View {
        LaunchExperienceView {
            if accountManager.currentAccount == nil {
                AuthenticationView(accountManager: accountManager)
            } else {
                AuthenticatedShell(accountManager: accountManager)
                .id(accountManager.currentAccount?.id)
            }
        }
    }
}

private struct AuthenticatedShell: View {
    @ObservedObject var accountManager: AccountManager
    @State private var selectedTab: RootTab

    init(accountManager: AccountManager) {
        self.accountManager = accountManager
        switch ProcessInfo.processInfo.environment["QUOTAMETER_DEMO_TAB"] {
        case "profile":
            _selectedTab = State(initialValue: .profile)
        case "platforms":
            _selectedTab = State(initialValue: .platforms)
        default:
            _selectedTab = State(initialValue: .dashboard)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                DashboardTab(accountManager: accountManager)
                    .opacity(selectedTab == .dashboard ? 1 : 0)
                    .offset(x: selectedTab == .dashboard ? 0 : -10)
                    .allowsHitTesting(selectedTab == .dashboard)
                    .accessibilityHidden(selectedTab != .dashboard)

                PlatformTab(accountManager: accountManager)
                    .opacity(selectedTab == .platforms ? 1 : 0)
                    .offset(x: selectedTab == .platforms ? 0 : 10)
                    .allowsHitTesting(selectedTab == .platforms)
                    .accessibilityHidden(selectedTab != .platforms)

                ProfileTab(accountManager: accountManager)
                    .opacity(selectedTab == .profile ? 1 : 0)
                    .offset(x: selectedTab == .profile ? 0 : 10)
                    .allowsHitTesting(selectedTab == .profile)
                    .accessibilityHidden(selectedTab != .profile)
            }
            .padding(.bottom, 76)
            .animation(
                .spring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.12),
                value: selectedTab
            )

            LiquidGlassTabBar(selection: $selectedTab)
                .padding(.horizontal, 18)
                .padding(.bottom, 7)
        }
        .background(
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        )
    }
}

private struct LaunchExperienceView<Content: View>: View {
    let content: Content
    @State private var logoScale: CGFloat = 0.9
    @State private var revealProgress: CGFloat = 0
    @State private var splashOpacity: Double = 1
    @State private var isFinished = false
    @State private var launchCompleted = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let holeDiameter = max(102, maskDiameter(in: proxy.size) * revealProgress)

            ZStack {
                Color(red: 0.025, green: 0.045, blue: 0.075)
                    .ignoresSafeArea()

                if !isFinished {
                    splashBackdrop
                        .opacity(splashOpacity)
                        .allowsHitTesting(false)
                }

                content
                    .environment(\.launchCompleted, launchCompleted)
                    .mask {
                        if isFinished {
                            Rectangle()
                        } else {
                            Circle()
                                .frame(width: holeDiameter)
                                .position(center)
                        }
                    }

                if !isFinished {
                    launchLogo
                        .scaleEffect(logoScale)
                        .opacity(Double(max(CGFloat(0), 1 - (revealProgress * 1.8))))
                        .position(center)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(red: 0.025, green: 0.045, blue: 0.075))
        }
        .ignoresSafeArea()
        .task {
            await runLaunchSequence()
        }
    }

    private var splashBackdrop: some View {
        Color(red: 0.025, green: 0.045, blue: 0.075)
            .ignoresSafeArea()
    }

    private var launchLogo: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 112, height: 112)
                .blur(radius: 12)
            Circle()
                .fill(Color(red: 0.08, green: 0.26, blue: 0.54))
                .frame(width: 94, height: 94)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 18, y: 10)
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)

            VStack(spacing: 4) {
                Text("QuotaMeter")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text("by Menius")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.44))
            }
            .offset(y: 92)
        }
    }

    @MainActor
    private func runLaunchSequence() async {
#if DEBUG
        let preview = ProcessInfo.processInfo.environment["QUOTAMETER_LAUNCH_PREVIEW"]
        if preview == "logo" {
            logoScale = 1
            return
        }
        if preview == "reveal" {
            logoScale = 1
            launchCompleted = true
            revealProgress = 0.42
            return
        }
#endif

        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.easeInOut(duration: 0.3)) {
            logoScale = 1.045
        }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeInOut(duration: 0.3)) {
            logoScale = 1
        }
        try? await Task.sleep(for: .milliseconds(300))
        launchCompleted = true
        withAnimation(.timingCurve(0.22, 0.02, 0.12, 1, duration: 0.7)) {
            revealProgress = 1
        }
        try? await Task.sleep(for: .milliseconds(680))
        withAnimation(.easeOut(duration: 0.12)) {
            splashOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(100))
        isFinished = true
    }

    private func maskDiameter(in size: CGSize) -> CGFloat {
        sqrt(size.width * size.width + size.height * size.height) * 1.5
    }
}

private struct LiquidGlassTabBar: View {
    @Binding var selection: RootTab
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragX: CGFloat?
    @State private var isDragging = false
    @State private var hoveredTarget: RootTab?
    @State private var selectionFeedback = 0

    private let tabs: [(RootTab, String, String)] = [
        (.dashboard, "额度", "chart.bar.fill"),
        (.platforms, "平台", "safari.fill"),
        (.profile, "我的", "person.crop.circle")
    ]

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 7
            let itemWidth = (proxy.size.width - inset * 2) / CGFloat(tabs.count)
            let selectedIndex = tabs.firstIndex { $0.0 == selection } ?? 0
            let restingX = inset + CGFloat(selectedIndex) * itemWidth
            let rawX = dragX ?? restingX
            let stretch = isDragging ? min(abs(rawX - restingX) * 0.16, 14) : 0
            let thumbWidth = itemWidth - 2 + stretch
            let thumbX = min(
                max(inset, rawX - stretch / 2),
                proxy.size.width - inset - thumbWidth
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isDragging ? 0.2 : 0.13), radius: 26, y: 11)

                Capsule()
                    .fill(.white.opacity(colorScheme == .dark ? 0.04 : 0.08))
                    .overlay {
                        Capsule()
                            .stroke(
                                .white.opacity(colorScheme == .dark ? 0.1 : 0.58),
                                lineWidth: 0.8
                            )
                    }

                Capsule()
                    .fill(.thinMaterial)
                    .overlay {
                        Capsule()
                            .fill(.white.opacity(colorScheme == .dark ? 0.07 : 0.18))
                            .overlay {
                                Capsule()
                                    .stroke(
                                        .white.opacity(colorScheme == .dark ? 0.08 : 0.7),
                                        lineWidth: 0.8
                                    )
                            }
                    }
                    .frame(width: thumbWidth, height: proxy.size.height - 14)
                    .offset(x: thumbX)
                    .scaleEffect(x: 1, y: isDragging ? 1.035 : 1)
                    .shadow(color: .black.opacity(0.08), radius: 7, y: 3)
                    .shadow(
                        color: .white.opacity(colorScheme == .dark ? 0.02 : 0.08),
                        radius: 1,
                        y: -1
                    )
                    .animation(
                        .spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.08),
                        value: isDragging
                    )

                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        VStack(spacing: 3) {
                            Image(systemName: tab.2)
                                .font(.system(size: 18, weight: .semibold))
                            Text(tab.1)
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(
                            selection == tab.0
                                ? Color.primary
                                : Color.secondary
                        )
                        .scaleEffect(selection == tab.0 && isDragging ? 0.94 : 1)
                        .frame(width: itemWidth, height: proxy.size.height)
                        .allowsHitTesting(false)
                        .animation(
                            .spring(response: 0.24, dampingFraction: 0.86),
                            value: isDragging
                        )
                    }
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let distance = hypot(
                            value.translation.width,
                            value.translation.height
                        )
                        guard distance >= 7 else { return }
                        if !isDragging {
                            isDragging = true
                            selectionFeedback += 1
                        }
                        let rawX = restingX + value.translation.width
                        dragX = min(max(inset, rawX), proxy.size.width - inset - itemWidth)
                        let candidate = nearestTab(
                            atX: rawX,
                            itemWidth: itemWidth,
                            inset: inset
                        )
                        if hoveredTarget != candidate {
                            hoveredTarget = candidate
                            if candidate != selection {
                                selectionFeedback += 1
                            }
                        }
                    }
                    .onEnded { value in
                        let distance = hypot(
                            value.translation.width,
                            value.translation.height
                        )
                        let didDrag = isDragging || distance >= 7
                        let target: RootTab?
                        if didDrag {
                            let currentX = dragX ?? restingX
                            let projectedX = currentX + value.predictedEndTranslation.width * 0.28
                            target = nearestTab(
                                atX: projectedX,
                                itemWidth: itemWidth,
                                inset: inset
                            )
                        } else {
                            target = tabIfHit(
                                atX: value.location.x,
                                itemWidth: itemWidth,
                                inset: inset
                            )
                        }
                        if let target, target != selection {
                            selectionFeedback += 1
                        }
                        withAnimation(
                            .spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0.14)
                        ) {
                            if let target {
                                selection = target
                            }
                            dragX = nil
                            isDragging = false
                            hoveredTarget = nil
                        }
                    }
            )
            .sensoryFeedback(.selection, trigger: selectionFeedback)
            .accessibilityRepresentation {
                Slider(
                    value: Binding(
                        get: { Double(tabs.firstIndex { $0.0 == selection } ?? 0) },
                        set: { value in
                            let index = min(
                                max(Int(value.rounded()), 0),
                                tabs.count - 1
                            )
                            withAnimation(
                                .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0.12)
                            ) {
                                selection = tabs[index].0
                            }
                        }
                    ),
                    in: 0...Double(tabs.count - 1),
                    step: 1
                ) {
                    Text("页面切换")
                }
                .accessibilityIdentifier("liquid-tab-bar")
            }
        }
        .frame(height: 64)
    }

    private func nearestTab(atX x: CGFloat, itemWidth: CGFloat, inset: CGFloat) -> RootTab {
        let rawIndex = Int(round((x - inset) / itemWidth))
        let index = min(max(rawIndex, 0), tabs.count - 1)
        return tabs[index].0
    }

    private func tabIfHit(atX x: CGFloat, itemWidth: CGFloat, inset: CGFloat) -> RootTab? {
        let rawIndex = Int(floor((x - inset) / itemWidth))
        let index = min(max(rawIndex, 0), tabs.count - 1)
        let center = inset + (CGFloat(index) + 0.5) * itemWidth
        let hitHalfWidth = min(44, itemWidth * 0.4)
        guard abs(x - center) <= hitHalfWidth else { return nil }
        return tabs[index].0
    }
}

private struct StaggeredEntrance<Content: View>: View {
    @Environment(\.launchCompleted) private var launchCompleted
    let index: Int
    let content: Content
    @State private var visible = false

    init(index: Int, @ViewBuilder content: () -> Content) {
        self.index = index
        self.content = content()
    }

    var body: some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 22)
            .onAppear {
                revealIfNeeded()
            }
            .onChange(of: launchCompleted) { _, _ in
                revealIfNeeded()
            }
    }

    private func revealIfNeeded() {
        guard launchCompleted, !visible else { return }
        withAnimation(
            .easeOut(duration: 0.42)
                .delay(0.55 + Double(index) * 0.06)
        ) {
            visible = true
        }
    }
}

private struct AuthenticationView: View {
    @ObservedObject var accountManager: AccountManager
    @State private var mode = AuthMode.signIn
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var showsPassword = false
    @FocusState private var focusedField: AuthField?

    private enum AuthMode: String, CaseIterable, Identifiable {
        case signIn = "登录"
        case register = "创建账户"
        var id: String { rawValue }
    }

    private enum AuthField {
        case username
        case displayName
        case password
        case confirmation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    brandHeader

                    VStack(spacing: 16) {
                        Picker("账户操作", selection: $mode) {
                            ForEach(AuthMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: mode) { _, _ in
                            accountManager.authMessage = nil
                        }

                        if mode == .register {
                            TextField("显示名称", text: $displayName)
                                .textContentType(.name)
                                .focused($focusedField, equals: .displayName)
                                .authFieldStyle()
                        }

                        TextField("账户名称", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .focused($focusedField, equals: .username)
                            .authFieldStyle()

                        HStack(spacing: 8) {
                            Group {
                                if showsPassword {
                                    TextField("密码", text: $password)
                                } else {
                                    SecureField("密码", text: $password)
                                }
                            }
                            .textContentType(mode == .register ? .newPassword : .password)
                            .focused($focusedField, equals: .password)

                            Button {
                                showsPassword.toggle()
                            } label: {
                                Image(systemName: showsPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showsPassword ? "隐藏密码" : "显示密码")
                        }
                        .authFieldStyle()

                        if mode == .register {
                            SecureField("再次输入密码", text: $confirmation)
                                .textContentType(.newPassword)
                                .focused($focusedField, equals: .confirmation)
                                .authFieldStyle()
                        }

                        if let message = accountManager.authMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            focusedField = nil
                            submit()
                        } label: {
                            Text(mode == .signIn ? "登录" : "创建并登录")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSubmit)
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )

                    VStack(spacing: 10) {
                        Label("账户与 API 凭据仅保存在本机", systemImage: "lock.shield.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link(
                            "GitHub · Menius2/QuotaMeter",
                            destination: URL(string: "https://github.com/Menius2/QuotaMeter")!
                        )
                        .font(.footnote.weight(.medium))
                    }

                    Text("Author: Menius")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.blue)
                    .frame(width: 66, height: 66)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("QuotaMeter")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("多平台 API 额度管理")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var canSubmit: Bool {
        let hasAccount = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = password.count >= 6
        let passwordsMatch = mode == .signIn || password == confirmation
        return hasAccount && hasPassword && passwordsMatch
    }

    private func submit() {
        if mode == .signIn {
            _ = accountManager.signIn(username: username, password: password)
        } else {
            guard password == confirmation else {
                accountManager.authMessage = "两次输入的密码不一致"
                return
            }
            _ = accountManager.register(
                username: username,
                displayName: displayName,
                password: password
            )
        }
    }
}

private extension View {
    func authFieldStyle() -> some View {
        padding(.horizontal, 13)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )
    }
}

private struct DashboardTab: View {
    @ObservedObject var accountManager: AccountManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingBindingEditor = false
    @State private var editingBinding: APIBinding?
    @State private var isShowingFeedback = false
    @State private var isManualRefreshing = false
    @State private var showRefreshSuccess = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        StaggeredEntrance(index: 0) {
                            accountBar
                        }
                        StaggeredEntrance(index: 1) {
                            bindingSwitcher
                        }

                        if let binding = accountManager.activeBinding,
                           let store = accountManager.activeStore {
                            StaggeredEntrance(index: 2) {
                                BindingDashboardContent(
                                    binding: binding,
                                    store: store,
                                    onEditBinding: {
                                        editingBinding = binding
                                        isShowingBindingEditor = true
                                    },
                                    onFeedback: {
                                        isShowingFeedback = true
                                    }
                                )
                                .id(binding.id)
                            }
                        } else {
                            StaggeredEntrance(index: 2) {
                                noBindingState
                            }
                        }

                        StaggeredEntrance(index: 3) {
                            AppAttributionFooter()
                        }
                    }
                    .id("dashboardTop")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .refreshable {
                    guard let store = accountManager.activeStore else { return }
                    await store.pullToRefresh()
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo("dashboardTop", anchor: .top)
                    }
                }
                .navigationTitle("额度")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            triggerManualRefresh()
                        } label: {
                            ZStack {
                                if isManualRefreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.blue)
                                } else if showRefreshSuccess {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .frame(width: 22, height: 22)
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .disabled(accountManager.activeStore?.hasStoredKey != true)
                        .accessibilityLabel(
                            isManualRefreshing
                                ? "正在刷新"
                                : "刷新当前 API"
                        )

                        Button {
                            editingBinding = nil
                            isShowingBindingEditor = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("添加 API")
                    }
                }
            }
            .sheet(isPresented: $isShowingBindingEditor) {
                BindingEditorView(
                    accountManager: accountManager,
                    binding: editingBinding
                )
            }
            .sheet(isPresented: $isShowingFeedback) {
                FeedbackView(
                    accountManager: accountManager,
                    initialMessage: accountManager.activeStore?.errorMessage ?? ""
                )
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active,
                      accountManager.activeStore?.hasStoredKey == true else { return }
                Task { await accountManager.activeStore?.refreshNow() }
            }
        }
    }

    private func triggerManualRefresh() {
        guard let store = accountManager.activeStore,
              !store.isManualRefreshing,
              !isManualRefreshing else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isManualRefreshing = true
        Task {
            await store.manualRefresh()
            isManualRefreshing = false
            guard store.errorMessage == nil else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeOut(duration: 0.15)) {
                showRefreshSuccess = true
            }
            try? await Task.sleep(nanoseconds: 850_000_000)
            withAnimation(.easeOut(duration: 0.18)) {
                showRefreshSuccess = false
            }
        }
    }

    private var accountBar: some View {
        HStack(spacing: 11) {
            AvatarView(account: accountManager.currentAccount, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountManager.currentAccount?.displayName ?? "账户")
                    .font(.subheadline.weight(.semibold))
                Text("\(accountManager.currentAccount?.bindings.count ?? 0) 个 API · 本机账户隔离")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("数据仅保存在本机账户")
        }
    }

    @ViewBuilder
    private var bindingSwitcher: some View {
        let bindings = accountManager.currentAccount?.bindings ?? []
        if !bindings.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bindings) { binding in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            accountManager.selectBinding(binding.id)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: binding.platform.symbol)
                                    .foregroundStyle(binding.platform.tint)
                                Text(binding.name)
                                    .lineLimit(1)
                                if binding.id == accountManager.activeBindingID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(binding.platform.tint)
                                }
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(
                                Capsule()
                                    .fill(
                                        binding.id == accountManager.activeBindingID
                                            ? binding.platform.tint.opacity(0.14)
                                            : Color(uiColor: .secondarySystemGroupedBackground)
                                    )
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        binding.id == accountManager.activeBindingID
                                            ? binding.platform.tint.opacity(0.35)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var noBindingState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.blue)
            Text("还没有绑定 API")
                .font(.headline)
            Text("每个平台独立保存密钥、余额和刷新设置。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editingBinding = nil
                isShowingBindingEditor = true
            } label: {
                Label("添加第一个 API", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct BindingDashboardContent: View {
    let binding: APIBinding
    @ObservedObject var store: QuotaStore
    let onEditBinding: () -> Void
    let onFeedback: () -> Void
    @State private var mode = DashboardMode.overview

    private enum DashboardMode: String, CaseIterable, Identifiable {
        case overview = "概览"
        case usage = "用量"
        case limits = "限额"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StaggeredEntrance(index: 3) {
                bindingHeader
            }

            StaggeredEntrance(index: 4) {
                Picker("显示内容", selection: $mode) {
                    ForEach(DashboardMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }

            if let message = store.errorMessage {
                StaggeredEntrance(index: 5) {
                    DashboardFeedbackBanner(text: message, onFeedback: onFeedback)
                }
            }

            StaggeredEntrance(index: 5) {
                if !store.hasStoredKey {
                    missingKeyState
                } else if let snapshot = store.snapshot {
                    switch mode {
                    case .overview:
                        overview(snapshot)
                    case .usage:
                        usageView(snapshot)
                    case .limits:
                        limitsView(snapshot)
                    }
                } else if store.isRefreshing {
                    loadingState
                } else {
                    unavailableState
                }
            }

            StaggeredEntrance(index: 6) {
                refreshFooter
            }
        }
    }

    private var bindingHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(binding.platform.tint.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: binding.platform.symbol)
                    .foregroundStyle(binding.platform.tint)
                    .font(.system(size: 18, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(binding.name)
                    .font(.headline)
                Text(binding.platform.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onEditBinding) {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑当前 API")
        }
    }

    @ViewBuilder
    private func overview(_ snapshot: UsageResponse) -> some View {
        BalanceCard(snapshot: snapshot, platform: binding.platform)
        TotalSpendCard(snapshot: snapshot)
        MetricGrid(snapshot: snapshot)
        HealthCard(snapshot: snapshot)
    }

    @ViewBuilder
    private func usageView(_ snapshot: UsageResponse) -> some View {
        let rows = QuotaDisplay.dailyRows(snapshot)
        let style = QuotaDisplay.usageStyle(for: snapshot)
        V2SectionHeader("最近 10 天")
        MiniUsageChart(rows: rows, style: style)
        V2SectionHeader("每日明细")
        DailyUsageCard(rows: rows, style: style)
        V2SectionHeader("累计明细")
        DetailLinesCard(snapshot: snapshot, style: style)
    }

    @ViewBuilder
    private func limitsView(_ snapshot: UsageResponse) -> some View {
        let limits = snapshot.rateLimits?.filter { $0.window != nil } ?? []
        if limits.isEmpty {
            EmptyPanel(
                symbol: "gauge.with.dots.needle.33percent",
                title: "当前平台没有限额数据",
                detail: "额度接口返回后会显示在这里。"
            )
        } else {
            let style = QuotaDisplay.usageStyle(for: snapshot)
            VStack(spacing: 0) {
                ForEach(Array(limits.enumerated()), id: \.offset) { index, item in
                    LimitRow(item: item, style: style)
                    if index < limits.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(V2CardBackground())
        }
    }

    private var missingKeyState: some View {
        EmptyPanel(
            symbol: "key.slash",
            title: "这个 API 还没有密钥",
            detail: "打开编辑页填写 API Key，或切换到其他已绑定的平台。"
        )
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在同步 \(binding.name)")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .background(V2CardBackground())
    }

    private var unavailableState: some View {
        EmptyPanel(
            symbol: "wifi.exclamationmark",
            title: "暂时没有数据",
            detail: "下拉刷新，或检查这个 API 的连接设置。"
        )
    }

    private var refreshFooter: some View {
        HStack {
            Text(store.lastUpdated.map {
                "更新于 \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "等待首次同步")
            Spacer()
            if store.hasStoredKey {
                Label("\(store.refreshIntervalSeconds) 秒", systemImage: "timer")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

private struct BalanceCard: View {
    let snapshot: UsageResponse
    let platform: APIPlatform

    var body: some View {
        let style = QuotaDisplay.balanceStyle(for: snapshot)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(QuotaDisplay.balanceTitle(for: style))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(snapshot.isValid == false ? "已停用" : "连接正常",
                      systemImage: snapshot.isValid == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(snapshot.isValid == false ? Color.red : Color.green)
            }
            Text(QuotaDisplay.amount(snapshot.remaining ?? snapshot.balance, style: style))
                .font(.system(size: 39, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .monospacedDigit()
            HStack(spacing: 8) {
                Text(snapshot.mode?.uppercased() ?? platform.shortTitle.uppercased())
                if let unit = snapshot.unit, !unit.isEmpty {
                    Text(unit)
                }
                if snapshot.remaining == nil && snapshot.balance != nil {
                    Text("账户余额")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(platform.tint)
                .frame(width: 4)
                .padding(.vertical, 14)
        }
    }
}

private struct MetricGrid: View {
    let snapshot: UsageResponse

    var body: some View {
        let style = QuotaDisplay.usageStyle(for: snapshot)
        let today = snapshot.usage?.today
        let total = snapshot.usage?.total
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
        LazyVGrid(columns: columns, spacing: 10) {
            DashboardMetricCard(
                title: QuotaDisplay.summaryTitle(.today, style: style, isLocal: snapshot.mode?.hasSuffix("-local") == true),
                value: QuotaDisplay.summaryValue(today, style: style),
                symbol: "calendar"
            )
            DashboardMetricCard(
                title: QuotaDisplay.summaryTitle(.total, style: style, isLocal: snapshot.mode?.hasSuffix("-local") == true),
                value: QuotaDisplay.summaryValue(total, style: style),
                symbol: "sum"
            )
            DashboardMetricCard(
                title: "今日请求",
                value: QuotaDisplay.count(today?.requests),
                symbol: "arrow.up.arrow.down"
            )
            DashboardMetricCard(
                title: "累计请求",
                value: QuotaDisplay.count(total?.requests),
                symbol: "number"
            )
        }
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(14)
        .background(V2CardBackground())
    }
}

private struct TotalSpendCard: View {
    let snapshot: UsageResponse

    var body: some View {
        if let spend = QuotaDisplay.spendSummary(for: snapshot) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.orange.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: "yensign.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("累计花费")
                        .font(.subheadline.weight(.semibold))
                    Text(spend.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(spend.formattedValue)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(14)
            .background(V2CardBackground())
        } else {
            HStack(spacing: 13) {
                Image(systemName: "yensign.circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("累计花费")
                        .font(.subheadline.weight(.semibold))
                    Text("平台暂未返回费用数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("--")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(V2CardBackground())
        }
    }
}

private struct HealthCard: View {
    let snapshot: UsageResponse

    var body: some View {
        let limits = snapshot.rateLimits ?? []
        let highest = limits.compactMap { item -> Double? in
            guard let limit = item.limit, limit > 0 else { return nil }
            return min((item.used ?? 0) / limit, 1)
        }.max() ?? 0
        let tint: Color = highest >= 0.9 ? .red : (highest >= 0.7 ? .orange : .green)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("额度状态", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(highest >= 0.9 ? "接近用尽" : (highest >= 0.7 ? "需要留意" : "状态良好"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            ProgressView(value: highest)
                .tint(tint)
            Text(limits.isEmpty ? "这个平台暂未返回限额窗口。" : "最高已用 \(Int(highest * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(V2CardBackground())
    }
}

private struct MiniUsageChart: View {
    let rows: [QuotaDisplay.DailyRow]
    let style: QuotaDisplay.Style
    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                Text("暂无趋势数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92)
            } else {
                let maxValue = max(rows.map(\.amount).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(rows.reversed().enumerated()), id: \.offset) { index, row in
                        let actualIndex = rows.count - 1 - index
                        Button {
                            selectedIndex = selectedIndex == actualIndex ? nil : actualIndex
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(selectedIndex == actualIndex ? Color.blue : Color.blue.opacity(0.35))
                                    .frame(height: max(8, 68 * row.amount / maxValue))
                                Text(row.date.suffix(5))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 90, alignment: .bottom)

                let index = selectedIndex ?? 0
                if rows.indices.contains(index) {
                    HStack {
                        Text(rows[index].date)
                        Spacer()
                        Text(QuotaDisplay.amount(rows[index].amount, style: style))
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(V2CardBackground())
    }
}

private struct DailyUsageCard: View {
    let rows: [QuotaDisplay.DailyRow]
    let style: QuotaDisplay.Style

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("暂无每日记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.date)
                                .font(.subheadline.weight(.medium))
                            Text("\(QuotaDisplay.count(row.requests)) 次请求")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(QuotaDisplay.amount(row.amount, style: style))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .background(V2CardBackground())
    }
}

private struct DetailLinesCard: View {
    let snapshot: UsageResponse
    let style: QuotaDisplay.Style

    var body: some View {
        let lines = QuotaDisplay.detailLines(snapshot, style: style)
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item.0)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.1)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                if index < lines.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(V2CardBackground())
    }
}

private struct LimitRow: View {
    let item: RateLimitEntry
    let style: QuotaDisplay.Style

    var body: some View {
        let used = item.used ?? 0
        let limit = item.limit ?? 0
        let ratio = limit > 0 ? min(max(used / limit, 0), 1) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(QuotaDisplay.windowTitle(item.window))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(QuotaDisplay.amount(used, style: style)) / \(QuotaDisplay.amount(limit, style: style))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: ratio)
                .tint(QuotaDisplay.progressTint(ratio))
            if let resetAt = item.resetAt, !resetAt.isEmpty {
                Text("重置于 \(resetAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

private struct PlatformTab: View {
    @ObservedObject var accountManager: AccountManager
    @State private var editingBinding: APIBinding?
    @State private var isShowingEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    StaggeredEntrance(index: 0) {
                        platformHeader
                    }

                    let bindings = accountManager.currentAccount?.bindings ?? []
                    if bindings.isEmpty {
                        StaggeredEntrance(index: 1) {
                            EmptyPanel(
                                symbol: "safari",
                                title: "还没有平台入口",
                                detail: "添加 API 后，可以在这里配置并打开对应平台网址。"
                            )
                        }
                    } else {
                        ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                            StaggeredEntrance(index: index + 1) {
                                PlatformLinkCard(
                                    binding: binding,
                                    isActive: binding.id == accountManager.activeBindingID,
                                    destination: destinationURL(for: binding),
                                    onEdit: {
                                        editingBinding = binding
                                        isShowingEditor = true
                                    }
                                )
                            }
                        }
                    }

                    StaggeredEntrance(index: 8) {
                        AppAttributionFooter()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("平台")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingBinding = nil
                        isShowingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加平台")
                }
            }
            .sheet(isPresented: $isShowingEditor) {
                BindingEditorView(
                    accountManager: accountManager,
                    binding: editingBinding
                )
            }
        }
    }

    private var platformHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: "safari.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("平台跳转")
                    .font(.title3.weight(.bold))
                Text("点击下方平台，用系统浏览器打开对应网站。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(V2CardBackground())
    }

    private func destinationURL(for binding: APIBinding) -> URL? {
        let configured = binding.websiteURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = binding.platform.defaultWebsiteURL
        let raw = configured.isEmpty ? (fallback.isEmpty ? binding.baseURL : fallback) : configured
        guard !raw.isEmpty else { return nil }
        let normalised = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: normalised)
    }
}

private struct PlatformLinkCard: View {
    let binding: APIBinding
    let isActive: Bool
    let destination: URL?
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(binding.platform.tint.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: binding.platform.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(binding.platform.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(binding.name)
                            .font(.headline)
                        if isActive {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(binding.platform.tint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(binding.platform.tint.opacity(0.12))
                                )
                        }
                    }
                    Text(binding.platform.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑 \(binding.name)")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("平台网址")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(destination?.absoluteString ?? "尚未配置有效网址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let destination {
                Link(destination: destination) {
                    HStack {
                        Image(systemName: "safari")
                        Text("在 Safari 中打开")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(binding.platform.tint)
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(binding.platform.tint.opacity(0.11))
                    )
                }
            } else {
                Button(action: onEdit) {
                    Label("设置平台网址", systemImage: "link.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.11))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(V2CardBackground())
    }
}

private struct ProfileTab: View {
    @ObservedObject var accountManager: AccountManager
    @AppStorage("QuotaMeter.interfaceAppearance.v1")
    private var appearanceRawValue = AppAppearance.system.rawValue
    @State private var isShowingEditor = false
    @State private var editingBinding: APIBinding?
    @State private var isShowingFeedback = false
    @State private var isConfirmingLogout = false
    @State private var isRefreshingAll = false

    private let githubURL = URL(string: "https://github.com/Menius2/QuotaMeter")!

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    profileHeader
                    accountIsolationCard
                    appearanceSection
                    bindingsSection
                    supportSection
                    aboutSection
                    signOutButton
                    AppAttributionFooter()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isShowingEditor) {
                BindingEditorView(
                    accountManager: accountManager,
                    binding: editingBinding
                )
            }
            .sheet(isPresented: $isShowingFeedback) {
                FeedbackView(accountManager: accountManager, initialMessage: "")
            }
            .alert("退出当前账户？", isPresented: $isConfirmingLogout) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    accountManager.signOut()
                }
            } message: {
                Text("退出不会删除保存在这个账户下的 API 与设置。")
            }
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            AvatarView(account: accountManager.currentAccount, size: 62)
            VStack(alignment: .leading, spacing: 4) {
                Text(accountManager.currentAccount?.displayName ?? "Menius")
                    .font(.title3.weight(.bold))
                Text("@\(accountManager.currentAccount?.username ?? "menius")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label("本地账户", systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Spacer()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var accountIsolationCard: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("账户数据隔离")
                    .font(.subheadline.weight(.semibold))
                Text("API Key、平台令牌、刷新设置和反馈内容只保存在当前账户，并在本机 Keychain 中加密。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.green.opacity(0.09))
        )
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2SectionHeader("界面")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("外观模式")
                            .font(.subheadline.weight(.semibold))
                        Text("切换后会立即生效并保存在本机")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("外观模式", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(14)
            .background(V2CardBackground())
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .system },
            set: { appearance in
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(.easeInOut(duration: 0.28)) {
                    appearanceRawValue = appearance.rawValue
                }
            }
        )
    }

    private var bindingsSection: some View {
        let bindings = accountManager.currentAccount?.bindings ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                V2SectionHeader("已绑定 API")
                Spacer()
                Button {
                    editingBinding = nil
                    isShowingEditor = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
            }

            VStack(spacing: 0) {
                if bindings.isEmpty {
                    Text("还没有绑定 API")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                } else {
                    ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                        HStack(spacing: 12) {
                            Button {
                                accountManager.selectBinding(binding.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: binding.platform.symbol)
                                        .foregroundStyle(binding.platform.tint)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(binding.name)
                                            .foregroundStyle(.primary)
                                        Text(binding.platform.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if binding.id == accountManager.activeBindingID {
                                        Text("当前")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(binding.platform.tint)
                                    } else {
                                        Text("切换")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                editingBinding = binding
                                isShowingEditor = true
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        if index < bindings.count - 1 {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
            .background(V2CardBackground())

            Button {
                isRefreshingAll = true
                Task {
                    await accountManager.refreshAllBindings()
                    isRefreshingAll = false
                }
            } label: {
                HStack {
                    Label(isRefreshingAll ? "正在刷新" : "刷新全部 API", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isRefreshingAll {
                        ProgressView()
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(V2CardBackground())
            }
            .buttonStyle(.plain)
            .disabled(bindings.isEmpty || isRefreshingAll)
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2SectionHeader("帮助与反馈")
            VStack(spacing: 0) {
                Button {
                    isShowingFeedback = true
                } label: {
                    ProfileRow(
                        symbol: "bubble.left.and.exclamationmark.bubble.right",
                        tint: .orange,
                        title: "问题反馈",
                        detail: accountManager.feedbackEntries.isEmpty ? "提交问题或建议" : "\(accountManager.feedbackEntries.count) 条记录"
                    )
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 50)

                Link(destination: URL(string: "https://github.com/Menius2/QuotaMeter/issues")!) {
                    ProfileRow(
                        symbol: "exclamationmark.bubble",
                        tint: .red,
                        title: "GitHub Issues",
                        detail: "查看公开问题"
                    )
                }
                .buttonStyle(.plain)
            }
            .background(V2CardBackground())
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2SectionHeader("关于")
            VStack(spacing: 0) {
                Link(destination: githubURL) {
                    ProfileRow(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        tint: .blue,
                        title: "GitHub 开源主页",
                        detail: "Menius2 / QuotaMeter"
                    )
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 50)
                ProfileRow(
                    symbol: "person.crop.circle",
                    tint: .indigo,
                    title: "作者",
                    detail: "Menius"
                )
                Divider().padding(.leading, 50)
                ProfileRow(
                    symbol: "number",
                    tint: .gray,
                    title: "版本",
                    detail: "1.2.5"
                )
            }
            .background(V2CardBackground())
        }
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            isConfirmingLogout = true
        } label: {
            Text("退出登录")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(V2CardBackground())
        }
    }
}

private struct ProfileRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

private struct BindingEditorView: View {
    @ObservedObject var accountManager: AccountManager
    let binding: APIBinding?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: EditorField?

    @State private var name: String
    @State private var platform: APIPlatform
    @State private var baseURL: String
    @State private var usagePath: String
    @State private var websiteURL: String
    @State private var interval: Int
    @State private var apiKey = ""
    @State private var platformToken = ""
    @State private var showsKey = false
    @State private var isSaving = false
    @State private var isShowingWebLogin = false
    @State private var isConfirmingDelete = false

    private enum EditorField {
        case name
        case baseURL
        case usagePath
        case apiKey
        case platformToken
    }

    init(accountManager: AccountManager, binding: APIBinding?) {
        self.accountManager = accountManager
        self.binding = binding
        let initialPlatform = binding?.platform ?? .codex
        _name = State(initialValue: binding?.name ?? initialPlatform.shortTitle)
        _platform = State(initialValue: initialPlatform)
        _baseURL = State(initialValue: binding?.baseURL ?? initialPlatform.defaultBaseURL)
        _usagePath = State(initialValue: binding?.usagePath ?? initialPlatform.defaultUsagePath)
        _websiteURL = State(
            initialValue: binding?.websiteURL?.isEmpty == false
                ? binding!.websiteURL!
                : initialPlatform.defaultWebsiteURL
        )
        _interval = State(initialValue: binding?.refreshIntervalSeconds ?? 30)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("API 信息") {
                    TextField("名称，例如工作账号", text: $name)
                        .focused($focusedField, equals: .name)
                    Picker("平台", selection: $platform) {
                        ForEach(APIPlatform.allCases) { platform in
                            Label(platform.title, systemImage: platform.symbol)
                                .tag(platform)
                        }
                    }
                    .onChange(of: platform) { _, newPlatform in
                        if baseURL.isEmpty || APIPlatform.allCases.contains(where: {
                            $0.defaultBaseURL == baseURL
                        }) {
                            baseURL = newPlatform.defaultBaseURL
                        }
                        usagePath = newPlatform.defaultUsagePath
                        if websiteURL.isEmpty || APIPlatform.allCases.contains(where: {
                            $0.defaultWebsiteURL == websiteURL
                        }) {
                            websiteURL = newPlatform.defaultWebsiteURL
                        }
                        if name.isEmpty || APIPlatform.allCases.contains(where: {
                            $0.shortTitle == name
                        }) {
                            name = newPlatform.shortTitle
                        }
                    }
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .baseURL)
                    TextField("Usage Path", text: $usagePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .usagePath)
                    TextField("平台网址", text: $websiteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    HStack {
                        Group {
                            if showsKey {
                                TextField(binding == nil ? "API Key" : "留空则保留现有 Key", text: $apiKey)
                            } else {
                                SecureField(binding == nil ? "API Key" : "留空则保留现有 Key", text: $apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .apiKey)
                        Button {
                            showsKey.toggle()
                        } label: {
                            Image(systemName: showsKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    SecureField("Usage / 官网访问令牌（可选）", text: $platformToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .platformToken)

                    Button {
                        focusedField = nil
                        isShowingWebLogin = true
                    } label: {
                        Label("网页登录获取令牌", systemImage: "safari")
                    }
                } header: {
                    Text("凭据")
                } footer: {
                    Text("密钥仅保存在当前账户的 Keychain 项中，不会写入开源项目仓库。")
                }

                Section("同步") {
                    Stepper("每 \(interval) 秒刷新", value: $interval, in: 10...300, step: 5)
                }

                Section {
                    Button {
                        focusedField = nil
                        Task { await save() }
                    } label: {
                        HStack {
                            Label(isSaving ? "保存中" : "保存 API", systemImage: "checkmark.circle.fill")
                            Spacer()
                            if isSaving {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let binding {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label("删除这个 API", systemImage: "trash")
                        }
                        .disabled(binding.id == accountManager.activeBindingID && accountManager.currentAccount?.bindings.count == 1)
                    }
                }
            }
            .navigationTitle(binding == nil ? "添加 API" : "编辑 API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { focusedField = nil }
                }
            }
            .sheet(isPresented: $isShowingWebLogin) {
                DashboardLoginView(
                    url: loginURL,
                    providerPreset: platform.apiProviderPreset
                ) { token in
                    platformToken = token
                }
            }
            .alert("删除 API？", isPresented: $isConfirmingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let binding {
                        accountManager.deleteBinding(binding.id)
                        dismiss()
                    }
                }
            } message: {
                Text("这个 API 的 Key、令牌、缓存和余额记录会从当前账户删除。")
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var loginURL: URL {
        if platform == .deepSeek {
            return URL(string: "https://platform.deepseek.com/usage")!
        }
        if platform == .openRouter {
            return URL(string: "https://openrouter.ai/settings/keys")!
        }
        return URL(string: baseURL.contains("://") ? baseURL : "https://\(baseURL)")
            ?? URL(string: "https://platform.openai.com")!
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let draft = APIBindingDraft(
            name: name,
            platform: platform,
            baseURL: baseURL,
            usagePath: usagePath,
            websiteURL: websiteURL,
            refreshIntervalSeconds: interval,
            apiKey: apiKey,
            platformToken: platformToken
        )
        let saved: Bool
        if let binding {
            saved = await accountManager.updateBinding(id: binding.id, draft: draft)
        } else {
            saved = await accountManager.addBinding(draft)
        }
        if saved {
            dismiss()
        }
    }
}

private struct FeedbackView: View {
    @ObservedObject var accountManager: AccountManager
    @Environment(\.dismiss) private var dismiss
    @State private var category = "问题"
    @State private var message: String
    @State private var contact = ""
    @State private var didSave = false

    private let categories = ["问题", "建议", "界面", "其他"]

    init(accountManager: AccountManager, initialMessage: String) {
        self.accountManager = accountManager
        _message = State(initialValue: initialMessage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("反馈类型") {
                    Picker("类型", selection: $category) {
                        ForEach(categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("问题或建议") {
                    TextEditor(text: $message)
                        .frame(minHeight: 150)
                }

                Section {
                    TextField("联系方式（可选）", text: $contact)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("反馈先保存在当前本地账户。需要公开跟进时，可复制内容并前往 GitHub Issues。")
                }

                Section {
                    Button {
                        accountManager.saveFeedback(
                            category: category,
                            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                            contact: contact.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        didSave = true
                    } label: {
                        Label("保存反馈", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Link(destination: githubIssueURL) {
                        Label("在 GitHub 提交", systemImage: "arrow.up.right.square")
                    }
                }

                if didSave {
                    Section {
                        Label("反馈已保存在当前账户", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("问题反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var githubIssueURL: URL {
        var components = URLComponents(string: "https://github.com/Menius2/QuotaMeter/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[\(category)] QuotaMeter iOS"),
            URLQueryItem(
                name: "body",
                value: """
                \(message)

                账户：\(accountManager.currentAccount?.username ?? "-")
                联系方式：\(contact)
                版本：1.2.5
                """
            )
        ]
        return components.url ?? URL(string: "https://github.com/Menius2/QuotaMeter/issues")!
    }
}

private struct AvatarView: View {
    let account: LocalAccount?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.14))
            Text(account?.initials ?? "M")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("账户头像")
    }
}

private struct DashboardFeedbackBanner: View {
    let text: String
    let onFeedback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button("反馈问题", action: onFeedback)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.opacity(0.11))
        )
    }
}

private struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 18)
        .background(V2CardBackground())
    }
}

private struct V2SectionHeader: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct V2CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

private struct AppAttributionFooter: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Author: Menius")
                .font(.caption.weight(.medium))
            Link(
                "github.com/Menius2/QuotaMeter",
                destination: URL(string: "https://github.com/Menius2/QuotaMeter")!
            )
            .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private enum DemoData {
    static func snapshot(for platform: APIPlatform) -> UsageResponse {
        let dates = ["2026-10-21", "2026-10-20", "2026-10-19", "2026-10-18", "2026-10-17", "2026-10-16", "2026-10-15"]
        switch platform {
        case .codex:
            return UsageResponse(
                balance: 38.72,
                dailyUsage: [
                    DailyUsageEntry(date: dates[0], requests: 126, inputTokens: 182_400, outputTokens: 64_200, cacheReadTokens: 24_000, cacheWriteTokens: nil, actualCost: 1.84, cost: 1.84, totalTokens: 246_600),
                    DailyUsageEntry(date: dates[1], requests: 98, inputTokens: 147_800, outputTokens: 51_600, cacheReadTokens: 18_400, cacheWriteTokens: nil, actualCost: 1.41, cost: 1.41, totalTokens: 199_400),
                    DailyUsageEntry(date: dates[2], requests: 143, inputTokens: 201_300, outputTokens: 77_900, cacheReadTokens: 31_000, cacheWriteTokens: nil, actualCost: 2.17, cost: 2.17, totalTokens: 279_200),
                    DailyUsageEntry(date: dates[3], requests: 74, inputTokens: 102_400, outputTokens: 36_800, cacheReadTokens: 9_800, cacheWriteTokens: nil, actualCost: 0.96, cost: 0.96, totalTokens: 139_200),
                    DailyUsageEntry(date: dates[4], requests: 119, inputTokens: 171_900, outputTokens: 60_500, cacheReadTokens: 22_700, cacheWriteTokens: nil, actualCost: 1.73, cost: 1.73, totalTokens: 232_400),
                    DailyUsageEntry(date: dates[5], requests: 88, inputTokens: 131_200, outputTokens: 47_100, cacheReadTokens: 16_000, cacheWriteTokens: nil, actualCost: 1.29, cost: 1.29, totalTokens: 178_300),
                    DailyUsageEntry(date: dates[6], requests: 132, inputTokens: 190_700, outputTokens: 69_100, cacheReadTokens: 27_400, cacheWriteTokens: nil, actualCost: 1.98, cost: 1.98, totalTokens: 259_800)
                ],
                isValid: true,
                mode: "compatible",
                planName: "Codex Pro",
                remaining: 38.72,
                unit: "USD",
                usage: UsageSummary(
                    averageDurationMs: 820,
                    rpm: 18,
                    tpm: 9_400,
                    today: UsageCounterEntry(actualCost: 1.84, cacheCreationTokens: nil, cacheReadTokens: 24_000, cost: 1.84, inputTokens: 182_400, outputTokens: 64_200, requests: 126, totalTokens: 246_600, cacheWriteTokens: nil),
                    total: UsageCounterEntry(actualCost: 112.40, cacheCreationTokens: nil, cacheReadTokens: 728_000, cost: 112.40, inputTokens: 5_284_000, outputTokens: 1_916_000, requests: 8_431, totalTokens: 7_200_000, cacheWriteTokens: nil)
                ),
                quota: QuotaSummary(limit: 150, used: 111.28, remaining: 38.72),
                rateLimits: [
                    RateLimitEntry(window: "5h", limit: 100, used: 72, resetAt: "今天 16:20"),
                    RateLimitEntry(window: "7d", limit: 1_000, used: 520, resetAt: "10月27日")
                ],
                subscription: nil,
                expiresAt: nil,
                daysUntilExpiry: nil,
                modelStats: nil
            )
        case .openRouter:
            return UsageResponse(
                balance: 12.40,
                dailyUsage: [
                    DailyUsageEntry(date: dates[0], requests: 34, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, actualCost: 2.10, cost: 2.10, totalTokens: nil),
                    DailyUsageEntry(date: dates[1], requests: 22, inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, actualCost: 1.36, cost: 1.36, totalTokens: nil)
                ],
                isValid: true,
                mode: "openrouter",
                planName: "OpenRouter Credits",
                remaining: 12.40,
                unit: "credits",
                usage: UsageSummary(
                    averageDurationMs: nil,
                    rpm: nil,
                    tpm: nil,
                    today: UsageCounterEntry(actualCost: 2.10, cacheCreationTokens: nil, cacheReadTokens: nil, cost: 2.10, inputTokens: nil, outputTokens: nil, requests: 34, totalTokens: nil, cacheWriteTokens: nil),
                    total: UsageCounterEntry(actualCost: 37.60, cacheCreationTokens: nil, cacheReadTokens: nil, cost: 37.60, inputTokens: nil, outputTokens: nil, requests: 611, totalTokens: nil, cacheWriteTokens: nil)
                ),
                quota: QuotaSummary(limit: 50, used: 37.60, remaining: 12.40),
                rateLimits: [RateLimitEntry(window: "month", limit: 50, used: 37.60, resetAt: "11月1日")],
                subscription: nil,
                expiresAt: nil,
                daysUntilExpiry: nil,
                modelStats: nil
            )
        case .deepSeek:
            return UsageResponse(
                balance: 86.21,
                dailyUsage: [
                    DailyUsageEntry(date: dates[0], requests: 51, inputTokens: 76_500, outputTokens: 22_400, cacheReadTokens: 11_200, cacheWriteTokens: nil, actualCost: 3.48, cost: 3.48, totalTokens: 98_900),
                    DailyUsageEntry(date: dates[1], requests: 39, inputTokens: 58_200, outputTokens: 17_900, cacheReadTokens: 8_100, cacheWriteTokens: nil, actualCost: 2.61, cost: 2.61, totalTokens: 76_100)
                ],
                isValid: true,
                mode: "deepseek-platform",
                planName: "DeepSeek 官网同步",
                remaining: 86.21,
                unit: "CNY",
                usage: UsageSummary(
                    averageDurationMs: nil,
                    rpm: nil,
                    tpm: nil,
                    today: UsageCounterEntry(actualCost: 3.48, cacheCreationTokens: nil, cacheReadTokens: 11_200, cost: 3.48, inputTokens: 76_500, outputTokens: 22_400, requests: 51, totalTokens: 98_900, cacheWriteTokens: nil),
                    total: UsageCounterEntry(actualCost: 28.73, cacheCreationTokens: nil, cacheReadTokens: 86_400, cost: 28.73, inputTokens: 582_600, outputTokens: 168_200, requests: 402, totalTokens: 750_800, cacheWriteTokens: nil)
                ),
                quota: nil,
                rateLimits: [],
                subscription: nil,
                expiresAt: nil,
                daysUntilExpiry: nil,
                modelStats: nil
            )
        case .compatible:
            return snapshot(for: .codex)
        }
    }
}
