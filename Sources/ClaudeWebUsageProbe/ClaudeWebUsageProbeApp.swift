import ContextPanelCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
struct ClaudeWebUsageProbeApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ClaudeUsageProbeRootView()
                .frame(minWidth: 1180, minHeight: 760)
        }
    }
}

struct ClaudeUsageProbeRootView: View {
    @StateObject private var model = ClaudeUsageProbeModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 390)
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ClaudeProbeWebView(model: model)
        }
        .fileExporter(
            isPresented: $model.isExportingReport,
            document: ProbeReportDocument(report: model.reportMarkdown),
            contentType: .plainText,
            defaultFilename: "claude-web-usage-probe-report.md"
        ) { _ in }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            status
            Divider()
            capturedLimits
            sanitizedFields
            Spacer()
            safetyFooter
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Usage Probe")
                .font(.system(size: 24, weight: .semibold))
            Text("Log in to Claude in this window, open Usage, then capture official subscription windows from the authenticated page context.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Open Usage") { model.openUsagePage() }
                Button("Reload") { model.reload() }
                Button("Export") { model.exportReport() }
            }

            HStack {
                Button("Save Snapshot") { model.saveSnapshot() }
                    .disabled(model.limits.isEmpty)
                Button("Clear") { model.clear() }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.statusText, systemImage: model.statusIcon)
                .font(.system(size: 12, weight: .medium))
            Text(model.currentURLText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .foregroundStyle(model.hasCapturedUsage ? .primary : .secondary)
    }

    private var capturedLimits: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Captured windows")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.limits.count)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if model.limits.isEmpty {
                ContentUnavailableView(
                    "No usage windows yet",
                    systemImage: "gauge.with.dots.needle.67percent",
                    description: Text("Complete Claude login or verification, then wait for the Usage page to load.")
                )
                .frame(maxHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.limits) { limit in
                            ClaudeUsageLimitRow(limit: limit)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var sanitizedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sanitized fields")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.fieldPaths.count)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if model.fieldPaths.isEmpty {
                Text("No Claude usage response fields captured yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.fieldPaths.prefix(18), id: \.self) { field in
                            Text(field)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private var safetyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Login stays inside the visible web session.", systemImage: "person.crop.circle.badge.checkmark")
            Label("Only percent windows, reset times, and field paths leave the page.", systemImage: "lock.shield")
            Label("No cookies, auth headers, tokens, local storage, emails, org IDs, or raw bodies are stored.", systemImage: "eye.slash")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

struct ClaudeUsageLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(limit.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                    Text(limit.contextLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(percentText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }

            ProgressView(value: limit.usageRatio ?? 0)
                .tint(tint)

            Text(resetText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var percentText: String {
        guard let ratio = limit.usageRatio else { return "?" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private var resetText: String {
        guard let resetsAt = limit.resetsAt else { return "reset unknown" }
        return "resets " + resetsAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var tint: Color {
        switch limit.status {
        case .limited:
            .red
        case .close:
            .orange
        case .healthy:
            .green
        default:
            .secondary
        }
    }
}

@MainActor
final class ClaudeUsageProbeModel: ObservableObject {
    @Published var limits: [UsageLimit] = []
    @Published var fieldPaths: [String] = []
    @Published var statusText = "Waiting for Claude usage response"
    @Published var statusIcon = "clock"
    @Published var currentURLText = ""
    @Published var isExportingReport = false

    private let snapshotStore = JSONSnapshotStore(rootDirectory: ContextPanelLocations.snapshotDirectory())

    private lazy var navigationDelegate = ClaudeUsageNavigationDelegate(owner: self)

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(ClaudeUsageScriptHandler(owner: self), name: "claudeUsageProbe")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.networkProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = navigationDelegate
        return view
    }()

    init() {
        openUsagePage()
    }

    var hasCapturedUsage: Bool { !limits.isEmpty }

    var reportMarkdown: String {
        var lines = [
            "# Claude Web Usage Probe Report",
            "",
            "- Captured: \(Date().ISO8601Format())",
            "- Windows: \(limits.count)",
            "- Sanitized fields: \(fieldPaths.count)",
            "",
            "## Captured Windows",
        ]

        if limits.isEmpty {
            lines.append("- No usage windows captured.")
        } else {
            for limit in limits {
                let percent = limit.used.map { "\($0)%" } ?? "unknown"
                let reset = limit.resetsAt?.ISO8601Format() ?? "unknown reset"
                lines.append("- \(limit.displayLabel) / \(limit.contextLabel): \(percent), resets \(reset)")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Sanitized Fields",
        ])

        if fieldPaths.isEmpty {
            lines.append("- No field paths captured.")
        } else {
            lines.append(contentsOf: fieldPaths.map { "- `\($0)`" })
        }

        lines.append(contentsOf: [
            "",
            "## Redactions",
            "- cookies",
            "- authorization headers",
            "- bearer tokens",
            "- Keychain credentials",
            "- OAuth tokens",
            "- local storage",
            "- account and organization identifiers",
            "- emails",
            "- raw response bodies",
            "- transcripts and prompt/response content",
        ])

        return lines.joined(separator: "\n")
    }

    func openUsagePage() {
        load("https://claude.ai/settings/usage")
    }

    func reload() {
        statusText = "Reloading Claude usage page"
        statusIcon = "arrow.clockwise"
        webView.reload()
    }

    func clear() {
        limits = []
        fieldPaths = []
        statusText = "Waiting for Claude usage response"
        statusIcon = "clock"
    }

    func exportReport() {
        isExportingReport = true
    }

    func saveSnapshot() {
        guard !limits.isEmpty else { return }
        do {
            try saveCurrentSnapshot()
            statusText = "Saved sanitized Claude usage snapshot"
            statusIcon = "checkmark.circle"
        } catch {
            statusText = "Save failed: \(error.localizedDescription)"
            statusIcon = "exclamationmark.triangle"
        }
    }

    fileprivate func record(payload: [String: Any]) {
        let windows = payload["windows"] as? [String: Any] ?? [:]
        let fields = payload["fields"] as? [String] ?? []
        let wrapped = ["rate_limits": windows]

        do {
            let data = try JSONSerialization.data(withJSONObject: wrapped)
            let parsedLimits = try ClaudeWebUsageParser.usageLimits(
                from: data,
                accountID: "claude-web",
                accountName: "Claude Web",
                observedAt: Date()
            )
            guard !parsedLimits.isEmpty else {
                statusText = "Usage response found, but no percent windows were present"
                statusIcon = "questionmark.circle"
                return
            }

            limits = parsedLimits
            fieldPaths = Array(Set(fields)).sorted()
            saveSnapshotAfterCapture()
        } catch {
            statusText = "Capture failed: \(error.localizedDescription)"
            statusIcon = "exclamationmark.triangle"
        }
    }

    private func saveSnapshotAfterCapture() {
        do {
            try saveCurrentSnapshot()
            statusText = "Captured and saved Claude subscription usage"
            statusIcon = "checkmark.circle.fill"
        } catch {
            statusText = "Captured Claude usage; save failed: \(error.localizedDescription)"
            statusIcon = "exclamationmark.triangle"
        }
    }

    private func saveCurrentSnapshot() throws {
        let report = ProviderConnectorReport(
            provider: .anthropic,
            accountID: "claude-web",
            accountName: "Claude Web",
            generatedAt: Date(),
            limits: limits,
            status: .healthy
        )
        try snapshotStore.saveMerged(
            refreshResult: ConnectorRefreshResult(generatedAt: Date(), reports: [report]),
            savedAt: Date()
        )
    }

    fileprivate func updateCurrentURL(_ url: URL?) {
        currentURLText = url?.absoluteString ?? ""
        if let host = url?.host, host.contains("claude.ai"), limits.isEmpty {
            statusText = "Claude page loaded; waiting for usage API"
            statusIcon = "network"
        }
    }

    private func load(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        statusText = "Opening Claude usage page"
        statusIcon = "safari"
        webView.load(URLRequest(url: url))
    }

    private static let networkProbeScript = #"""
    (() => {
      if (window.__contextPanelClaudeUsageProbeInstalled) return;
      window.__contextPanelClaudeUsageProbeInstalled = true;

      const windowKeys = new Set([
        'five_hour',
        'seven_day',
        'seven_day_opus',
        'seven_day_sonnet',
        'seven_day_oauth_apps'
      ]);
      const fieldKeys = new Set([
        'used_percentage',
        'remaining_percentage',
        'utilization',
        'resets_at',
        'reset_at'
      ]);

      function isUsageURL(rawUrl) {
        try {
          const url = new URL(rawUrl, window.location.href);
          return /^\/api\/organizations\/[^/]+\/usage$/.test(url.pathname);
        } catch (_) {
          return false;
        }
      }

      function sanitizeWindow(value) {
        if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
        const sanitized = {};
        for (const key of fieldKeys) {
          const raw = value[key];
          if (typeof raw === 'number' || typeof raw === 'string') sanitized[key] = raw;
        }
        return Object.keys(sanitized).length ? sanitized : null;
      }

      function collectWindows(value, out = {}) {
        if (!value || typeof value !== 'object') return out;
        if (Array.isArray(value)) {
          value.slice(0, 3).forEach(item => collectWindows(item, out));
          return out;
        }
        for (const [key, child] of Object.entries(value)) {
          if (windowKeys.has(key)) {
            const sanitized = sanitizeWindow(child);
            if (sanitized) out[key] = sanitized;
          }
          collectWindows(child, out);
        }
        return out;
      }

      function collectFields(value, prefix = '', out = new Set()) {
        if (!value || typeof value !== 'object' || out.size > 80) return out;
        if (Array.isArray(value)) {
          value.slice(0, 3).forEach(item => collectFields(item, prefix, out));
          return out;
        }
        for (const [key, child] of Object.entries(value)) {
          const path = prefix ? `${prefix}.${key}` : key;
          if (windowKeys.has(key) || fieldKeys.has(key) || key === 'rate_limits' || key === 'usage') out.add(path);
          collectFields(child, path, out);
        }
        return out;
      }

      function post(payload) {
        try { window.webkit.messageHandlers.claudeUsageProbe.postMessage(payload); }
        catch (_) {}
      }

      function inspect(url, contentType, text) {
        if (!isUsageURL(url) || !/json/i.test(contentType || '')) return;
        try {
          const parsed = JSON.parse(String(text || ''));
          const windows = collectWindows(parsed);
          if (!Object.keys(windows).length) return;
          post({ windows, fields: Array.from(collectFields(parsed)).slice(0, 80) });
        } catch (_) {}
      }

      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = async function(input, init) {
          const response = await originalFetch.apply(this, arguments);
          try {
            const clone = response.clone();
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            clone.text().then(text => inspect(url, clone.headers.get('content-type') || '', text)).catch(() => {});
          } catch (_) {}
          return response;
        };
      }

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__cpClaudeUsageUrl = url;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try { inspect(this.__cpClaudeUsageUrl || '', this.getResponseHeader('content-type') || '', this.responseText || ''); }
          catch (_) {}
        });
        return originalSend.apply(this, arguments);
      };
    })();
    """#
}

final class ClaudeUsageScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ClaudeUsageProbeModel?

    init(owner: ClaudeUsageProbeModel) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        Task { @MainActor [weak owner = self.owner] in
            owner?.record(payload: payload)
        }
    }
}

final class ClaudeUsageNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var owner: ClaudeUsageProbeModel?

    init(owner: ClaudeUsageProbeModel) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak webView, weak owner] in
            owner?.updateCurrentURL(webView?.url)
        }
    }
}

struct ClaudeProbeWebView: NSViewRepresentable {
    @ObservedObject var model: ClaudeUsageProbeModel

    func makeNSView(context: Context) -> WKWebView {
        model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ProbeReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var report: String

    init(report: String) {
        self.report = report
    }

    init(configuration: ReadConfiguration) throws {
        report = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(report.utf8))
    }
}
