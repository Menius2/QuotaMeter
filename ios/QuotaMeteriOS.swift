import SwiftUI
import WebKit

struct LegacyQuotaMeteriOSApp: App {
    @StateObject private var store = QuotaStore()

    var body: some Scene {
        WindowGroup {
            QuotaDashboardView(store: store)
        }
    }
}

private struct QuotaDashboardView: View {
    @ObservedObject var store: QuotaStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    statusHeader

                    if let message = store.errorMessage {
                        MessageBanner(
                            text: message,
                            symbol: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                    }

                    if !store.hasStoredKey {
                        emptyState
                    } else if let snapshot = store.snapshot {
                        balanceCard(snapshot)
                        metricGrid(snapshot)
                        limitsSection(snapshot)
                        dailyUsageSection(snapshot)
                        detailsSection(snapshot)
                    } else if store.isRefreshing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取额度")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 52)
                    } else {
                        ContentUnavailableView(
                            "暂时没有数据",
                            systemImage: "chart.bar",
                            description: Text("下拉刷新，或检查连接设置。")
                        )
                    }

                    updateFooter
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .refreshable {
                await store.refreshNow()
            }
            .navigationTitle("QuotaMeter")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshNow() }
                    } label: {
                        if store.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isRefreshing || !store.hasStoredKey)
                    .accessibilityLabel("刷新")

                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsViewIOS(store: store)
            }
            .task {
                if store.hasStoredKey && store.snapshot == nil {
                    await store.refreshNow()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, store.hasStoredKey else { return }
                Task { await store.refreshNow() }
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.errorMessage == nil && store.hasStoredKey ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot?.planName ?? (store.hasStoredKey ? "已连接" : "尚未连接"))
                    .font(.subheadline.weight(.semibold))
                Text(store.snapshot?.mode?.uppercased() ?? "API 额度与用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let updated = store.lastUpdated {
                Text(updated, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.blue)
            Text("还没有连接供应商")
                .font(.headline)
            Button("配置 API") {
                isShowingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background(cardBackground)
    }

    private func balanceCard(_ snapshot: UsageResponse) -> some View {
        let style = QuotaDisplay.balanceStyle(for: snapshot)
        return VStack(alignment: .leading, spacing: 8) {
            Text(QuotaDisplay.balanceTitle(for: style))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(QuotaDisplay.amount(snapshot.remaining ?? snapshot.balance, style: style))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(snapshot.isValid == false ? "已停用" : "有效")
                if let unit = snapshot.unit, !unit.isEmpty {
                    Text(unit)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    private func metricGrid(_ snapshot: UsageResponse) -> some View {
        let style = QuotaDisplay.usageStyle(for: snapshot)
        let today = snapshot.usage?.today
        let total = snapshot.usage?.total
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
        return LazyVGrid(columns: columns, spacing: 10) {
            MetricCard(
                title: QuotaDisplay.summaryTitle(.today, style: style, isLocal: snapshot.mode?.hasSuffix("-local") == true),
                value: QuotaDisplay.summaryValue(today, style: style),
                symbol: "calendar"
            )
            MetricCard(
                title: QuotaDisplay.summaryTitle(.total, style: style, isLocal: snapshot.mode?.hasSuffix("-local") == true),
                value: QuotaDisplay.summaryValue(total, style: style),
                symbol: "sum"
            )
            MetricCard(
                title: "今日请求",
                value: QuotaDisplay.count(today?.requests),
                symbol: "arrow.up.arrow.down"
            )
            MetricCard(
                title: "累计请求",
                value: QuotaDisplay.count(total?.requests),
                symbol: "number"
            )
        }
    }

    @ViewBuilder
    private func limitsSection(_ snapshot: UsageResponse) -> some View {
        let limits = snapshot.rateLimits?.filter { $0.window != nil } ?? []
        if !limits.isEmpty {
            let style = QuotaDisplay.usageStyle(for: snapshot)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("限额")
                VStack(spacing: 0) {
                    ForEach(Array(limits.enumerated()), id: \.offset) { index, limit in
                        limitRow(limit, style: style)
                        if index < limits.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(cardBackground)
            }
        }
    }

    private func limitRow(_ item: RateLimitEntry, style: QuotaDisplay.Style) -> some View {
        let used = item.used ?? 0
        let limit = item.limit ?? 0
        let ratio = limit > 0 ? min(max(used / limit, 0), 1) : 0
        return VStack(alignment: .leading, spacing: 8) {
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
                    .lineLimit(1)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func dailyUsageSection(_ snapshot: UsageResponse) -> some View {
        let style = QuotaDisplay.usageStyle(for: snapshot)
        let rows = QuotaDisplay.dailyRows(snapshot)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("最近使用")
            if rows.isEmpty {
                Text("暂无每日记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(cardBackground)
            }
        }
    }

    @ViewBuilder
    private func detailsSection(_ snapshot: UsageResponse) -> some View {
        let style = QuotaDisplay.usageStyle(for: snapshot)
        let lines = QuotaDisplay.detailLines(snapshot, style: style)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading("累计明细")
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        if index < lines.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(cardBackground)
            }
        }
    }

    private var updateFooter: some View {
        HStack {
            Text(store.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "等待首次刷新")
            Spacer()
            if store.hasStoredKey {
                Text("每 \(store.refreshIntervalSeconds) 秒")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

private struct SectionHeading: View {
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

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct MessageBanner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
        )
    }
}

private struct SettingsViewIOS: View {
    @ObservedObject var store: QuotaStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var baseURL = ""
    @State private var providerPreset: APIProviderPreset = .auto
    @State private var usagePath = "/v1/usage"
    @State private var newAPIKey = ""
    @State private var platformToken = ""
    @State private var showAPIKey = false
    @State private var refreshInterval = 30
    @State private var statusMessage = ""
    @State private var isSaving = false
    @State private var isShowingLogin = false
    @State private var isConfirmingClear = false

    private enum Field {
        case baseURL
        case usagePath
        case apiKey
        case platformToken
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    TextField("https://your-api.example.com", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .baseURL)

                    Picker("接口类型", selection: $providerPreset) {
                        ForEach(APIProviderPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    TextField(
                        providerPreset == .deepSeek ? "/user/balance" : "/v1/usage",
                        text: $usagePath
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .usagePath)
                    .disabled(providerPreset == .openRouter || providerPreset == .deepSeek)
                }

                Section {
                    HStack {
                        Group {
                            if showAPIKey {
                                TextField("API Key", text: $newAPIKey)
                            } else {
                                SecureField("API Key", text: $newAPIKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .apiKey)

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showAPIKey ? "隐藏 API Key" : "显示 API Key")
                    }

                    SecureField("Usage / 官网访问令牌（可选）", text: $platformToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .platformToken)

                    Button {
                        focusedField = nil
                        isShowingLogin = true
                    } label: {
                        Label("网页登录获取令牌", systemImage: "safari")
                    }
                } header: {
                    Text("凭据")
                } footer: {
                    Text(store.hasStoredKey ? "API Key 已保存在本机 Keychain。" : "API Key 会保存在本机 Keychain。")
                }

                Section("刷新") {
                    Stepper("每 \(refreshInterval) 秒", value: $refreshInterval, in: 10...300, step: 5)
                }

                Section {
                    Button {
                        focusedField = nil
                        Task { await save() }
                    } label: {
                        HStack {
                            Label(isSaving ? "保存中" : "保存并刷新", systemImage: "checkmark.circle.fill")
                            Spacer()
                            if isSaving {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSaving)

                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("清除密钥", systemImage: "trash")
                    }
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { focusedField = nil }
                }
            }
            .onAppear(perform: loadSettings)
            .onChange(of: store.platformToken) { _, value in
                if platformToken != value {
                    platformToken = value
                }
            }
            .sheet(isPresented: $isShowingLogin) {
                DashboardLoginView(
                    url: loginURL,
                    providerPreset: providerPreset
                ) { token in
                    store.acceptPlatformToken(token)
                    platformToken = token
                    statusMessage = "已获取官网令牌，正在刷新"
                }
            }
            .alert("清除密钥？", isPresented: $isConfirmingClear) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    Task { await clearKey() }
                }
            } message: {
                Text("将删除保存在此设备上的 API Key 和官网令牌。")
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var loginURL: URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerPreset == .deepSeek || raw.localizedCaseInsensitiveContains("deepseek") {
            return URL(string: "https://platform.deepseek.com/usage")!
        }
        if providerPreset == .openRouter || raw.localizedCaseInsensitiveContains("openrouter") {
            return URL(string: "https://openrouter.ai/settings/keys")!
        }
        guard !raw.isEmpty else {
            return URL(string: "https://platform.openai.com")!
        }
        let normalised = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: normalised) ?? URL(string: "https://platform.openai.com")!
    }

    private func loadSettings() {
        baseURL = store.baseURLString
        providerPreset = store.providerPreset
        usagePath = store.usagePath
        platformToken = store.platformToken
        refreshInterval = store.refreshIntervalSeconds
        statusMessage = store.hasStoredKey ? "已加载本机凭据" : ""
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let key = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.updateSettings(
            baseURL: baseURL,
            refreshIntervalSeconds: refreshInterval,
            apiKey: key.isEmpty ? nil : key,
            providerPreset: providerPreset,
            usagePath: usagePath,
            platformToken: platformToken
        )
        newAPIKey = ""
        if let error = store.errorMessage {
            statusMessage = "设置已保存，刷新失败：\(error)"
        } else {
            statusMessage = "设置已保存并刷新"
        }
    }

    @MainActor
    private func clearKey() async {
        await store.clearStoredKey()
        newAPIKey = ""
        platformToken = ""
        statusMessage = "已清除本机密钥"
    }
}

struct DashboardLoginView: View {
    let url: URL
    let providerPreset: APIProviderPreset
    let onToken: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var capturedToken: String?

    var body: some View {
        NavigationStack {
            BrowserView(
                url: url,
                tokenKeys: tokenKeys
            ) { token in
                capturedToken = token
                onToken(token)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("网页登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: capturedToken == nil ? "lock.shield" : "checkmark.circle.fill")
                        .foregroundStyle(capturedToken == nil ? Color.secondary : Color.green)
                    Text(capturedToken == nil ? "登录后会自动读取官网令牌" : "已获取官网令牌，可以关闭此页")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private var tokenKeys: [String] {
        if providerPreset == .deepSeek || url.host?.localizedCaseInsensitiveContains("deepseek") == true {
            return ["userToken"]
        }
        return ["userToken", "access_token", "accessToken", "auth_token", "authToken", "token"]
    }
}

struct BrowserView: UIViewRepresentable {
    let url: URL
    let tokenKeys: [String]
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: BrowserView
        weak var webView: WKWebView?
        private var scanTask: DispatchWorkItem?
        private var didCaptureToken = false

        init(parent: BrowserView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didCaptureToken = false
            scanTask?.cancel()
            scan(attempt: 0)
        }

        private func scan(attempt: Int) {
            guard !didCaptureToken, attempt < 60, let webView else { return }
            let keysData = try? JSONSerialization.data(withJSONObject: parent.tokenKeys)
            let keysJSON = keysData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let script = """
            (() => {
              const keys = \(keysJSON);
              for (const key of keys) {
                const value = localStorage.getItem(key) || sessionStorage.getItem(key);
                if (value) return value;
              }
              return null;
            })()
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                if let token = self.token(from: result) {
                    self.didCaptureToken = true
                    self.parent.onToken(token)
                    return
                }
                let task = DispatchWorkItem { [weak self] in
                    self?.scan(attempt: attempt + 1)
                }
                self.scanTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
            }
        }

        private func token(from result: Any?) -> String? {
            guard let raw = result as? String, !raw.isEmpty else { return nil }
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let wrapped = object["value"] as? String {
                return wrapped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
    }
}

enum QuotaDisplay {
    enum SpendSource {
        case provider
        case quota
        case daily
        case local

        var label: String {
            switch self {
            case .provider: return "接口返回的累计费用"
            case .quota: return "额度已用金额"
            case .daily: return "每日记录汇总"
            case .local: return "本机观测累计"
            }
        }
    }

    struct SpendSummary {
        let formattedValue: String
        let sourceLabel: String
    }

    enum Style {
        case tokens
        case credits
        case dollars
    }

    enum SummaryKind {
        case today
        case total
    }

    struct DailyRow {
        let date: String
        let requests: Double
        let amount: Double
    }

    static func balanceStyle(for snapshot: UsageResponse) -> Style {
        if snapshot.mode?.hasPrefix("deepseek") == true {
            return .credits
        }
        let unit = snapshot.unit?.lowercased() ?? ""
        if unit.contains("credit") || snapshot.mode == "openrouter" {
            return .credits
        }
        return .dollars
    }

    static func usageStyle(for snapshot: UsageResponse) -> Style {
        let total = snapshot.usage?.total
        if total?.totalTokens != nil ||
            total?.inputTokens != nil ||
            total?.outputTokens != nil ||
            total?.cacheCreationTokens != nil ||
            total?.cacheReadTokens != nil {
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

    static func balanceTitle(for style: Style) -> String {
        switch style {
        case .tokens: return "剩余 token"
        case .credits: return "钱包余额"
        case .dollars: return "钱包余额"
        }
    }

    static func summaryTitle(_ kind: SummaryKind, style: Style, isLocal: Bool) -> String {
        if isLocal {
            return kind == .today ? "今日消耗（本机）" : "累计消耗（本机）"
        }
        switch (kind, style) {
        case (.today, .tokens): return "今日 token"
        case (.total, .tokens): return "累计 token"
        case (.today, .credits): return "今日使用"
        case (.total, .credits): return "累计使用"
        case (.today, .dollars): return "今日花费"
        case (.total, .dollars): return "累计花费"
        }
    }

    static func summaryValue(_ entry: UsageCounterEntry?, style: Style) -> String {
        guard let entry else { return "-" }
        switch style {
        case .tokens:
            return amount(entry.totalTokens ?? entry.inputTokens ?? entry.outputTokens ?? entry.requests, style: style)
        case .credits, .dollars:
            return amount(entry.actualCost ?? entry.cost ?? entry.totalTokens ?? entry.requests, style: style)
        }
    }

    static func amount(_ value: Double?, style: Style) -> String {
        guard let value, value.isFinite else { return "-" }
        switch style {
        case .tokens:
            return integerFormatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
        case .credits:
            return decimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        case .dollars:
            let number = decimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
            return "$\(number)"
        }
    }

    static func count(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return integerFormatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    static func spendSummary(for snapshot: UsageResponse) -> SpendSummary? {
        let total = snapshot.usage?.total
        let isLocal = snapshot.mode?.hasSuffix("-local") == true
        let explicitTotal = total?.actualCost ?? total?.cost

        if let explicitTotal {
            return SpendSummary(
                formattedValue: formattedSpend(explicitTotal, unit: snapshot.unit),
                sourceLabel: isLocal ? SpendSource.local.label : SpendSource.provider.label
            )
        }

        if let used = snapshot.quota?.used {
            return SpendSummary(
                formattedValue: formattedSpend(used, unit: snapshot.unit),
                sourceLabel: SpendSource.quota.label
            )
        }

        let dailyCosts = (snapshot.dailyUsage ?? []).compactMap {
            $0.actualCost ?? $0.cost
        }
        if !dailyCosts.isEmpty {
            return SpendSummary(
                formattedValue: formattedSpend(dailyCosts.reduce(0, +), unit: snapshot.unit),
                sourceLabel: SpendSource.daily.label
            )
        }

        return nil
    }

    static func windowTitle(_ window: String?) -> String {
        switch window {
        case "5h": return "5 小时"
        case "1d": return "1 天"
        case "7d": return "7 天"
        case "month", "monthly": return "每月"
        default: return window ?? "-"
        }
    }

    static func progressTint(_ ratio: Double) -> Color {
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .green
    }

    static func dailyRows(_ snapshot: UsageResponse) -> [DailyRow] {
        let style = usageStyle(for: snapshot)
        return Array((snapshot.dailyUsage ?? [])
            .compactMap { row -> DailyRow? in
                guard let date = row.date else { return nil }
                let cost = row.actualCost ?? row.cost
                let amount: Double?
                switch style {
                case .tokens:
                    amount = row.totalTokens ?? cost ?? row.requests
                case .credits, .dollars:
                    amount = cost ?? row.totalTokens ?? row.requests
                }
                guard let amount else { return nil }
                return DailyRow(date: date, requests: row.requests ?? 0, amount: amount)
            }
            .sorted { $0.date > $1.date }
            .prefix(10))
    }

    static func detailLines(_ snapshot: UsageResponse, style: Style) -> [(String, String)] {
        let total = snapshot.usage?.total
        switch style {
        case .tokens:
            return [
                ("输入 token", amount(total?.inputTokens, style: style)),
                ("输出 token", amount(total?.outputTokens, style: style)),
                ("缓存创建", amount(total?.cacheCreationTokens, style: style)),
                ("缓存读取", amount(total?.cacheReadTokens, style: style)),
                ("总 token", amount(total?.totalTokens, style: style))
            ]
        case .credits, .dollars:
            return [
                ("限额", amount(snapshot.quota?.limit, style: style)),
                ("已用", amount(snapshot.quota?.used ?? total?.actualCost ?? total?.cost, style: style)),
                ("剩余", amount(snapshot.quota?.remaining, style: style)),
                ("今日使用", amount(snapshot.usage?.today?.actualCost ?? snapshot.usage?.today?.cost, style: style)),
                ("累计使用", amount(total?.actualCost ?? total?.cost, style: style))
            ]
        }
    }

    private static func formattedSpend(_ value: Double, unit: String?) -> String {
        let number = decimalFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", value)
        let normalisedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch normalisedUnit {
        case "usd", "dollar", "dollars":
            return "$\(number)"
        case "cny", "rmb", "yuan":
            return "¥\(number)"
        case "credit", "credits":
            return "\(number) credits"
        case "":
            return number
        default:
            return "\(number) \(unit ?? "")"
        }
    }

    private static let decimalFormatter: NumberFormatter = {
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
}
