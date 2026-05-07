import ContextPanelCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
struct OpenAILimitProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeRootView()
                .frame(minWidth: 1180, minHeight: 760)
        }
    }
}

struct ProbeRootView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                controls
                Divider()
                ObservationList(observations: model.observations)
                NetworkEventList(events: model.networkEvents)
                Spacer()
                safetyFooter
            }
            .frame(width: 360)
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ProbeWebView(model: model)
        }
        .fileExporter(
            isPresented: $model.isExportingReport,
            document: ProbeReportDocument(report: model.reportMarkdown),
            contentType: .plainText,
            defaultFilename: "openai-limit-probe-report.md"
        ) { _ in }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenAI Limit Probe")
                .font(.system(size: 24, weight: .semibold))
            Text("Log in directly with OpenAI, navigate to ChatGPT/model picker, then scan visible text for subscription limit signals.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Open ChatGPT") {
                    model.loadChatGPT()
                }
                Button("Scan Visible Text") {
                    model.scanVisibleText()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }

            HStack {
                Button("Record Manual Observation") {
                    model.recordManualObservation()
                }
                Button("Export Redacted Report") {
                    model.exportReport()
                }
                .keyboardShortcut("e", modifiers: [.command])
            }

            TextField("Manual note, e.g. resets tomorrow 9:00 AM", text: $model.manualObservation)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var safetyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No passwords, cookies, auth headers, or raw response bodies are exported.", systemImage: "lock.shield")
            Label("Network capture stores only method/path/status/body size and matching field names.", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

struct NetworkEventList: View {
    let events: [NetworkProbeEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Network candidates")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(events.count)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if events.isEmpty {
                Text("No candidate response fields yet. Open model menus or settings, then scan/navigate.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events.prefix(12)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(event.method) \(event.pathHint)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2)
                                Text(event.matchedFields.joined(separator: ", "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("status \(event.status.map(String.init) ?? "?") · \(event.bodySize ?? 0)b")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

struct ObservationList: View {
    let observations: [LimitProbeObservation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Observations")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(observations.count)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if observations.isEmpty {
                ContentUnavailableView(
                    "No signals yet",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Open ChatGPT, log in, navigate to the model picker, and scan visible text.")
                )
                .frame(maxHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(observations) { observation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(observation.signalKind.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(observation.sanitizedEvidence)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("\(observation.source.rawValue) · \(observation.confidence.rawValue)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var observations: [LimitProbeObservation] = []
    @Published var networkEvents: [NetworkProbeEvent] = []
    @Published var manualObservation = ""
    @Published var isExportingReport = false

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(ProbeScriptHandler(owner: self), name: "limitProbe")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.networkProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    init() {
        loadChatGPT()
    }

    var reportMarkdown: String {
        LimitProbeReport(
            provider: .openAI,
            capturedAt: Date(),
            observations: observations,
            networkEvents: networkEvents
        ).markdownSummary
    }

    func loadChatGPT() {
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }

    func scanVisibleText() {
        let script = "document.body ? document.body.innerText : ''"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result as? String {
                    let newObservations = LimitProbeScanner.scanVisibleText(text, provider: .openAI)
                    self.merge(newObservations)
                } else if let error {
                    self.merge([
                        LimitProbeObservation(
                            provider: .openAI,
                            observedAt: Date(),
                            source: .visibleText,
                            signalKind: .limitReached,
                            confidence: .unknown,
                            sanitizedEvidence: "Scan failed: \(error.localizedDescription)"
                        )
                    ])
                }
            }
        }
    }

    func recordManualObservation() {
        let trimmed = manualObservation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        merge([
            LimitProbeObservation(
                provider: .openAI,
                observedAt: Date(),
                source: .manualUserEntry,
                signalKind: .resetLanguage,
                confidence: .manual,
                sanitizedEvidence: trimmed
            )
        ])
        manualObservation = ""
    }

    func exportReport() {
        isExportingReport = true
    }

    private func merge(_ newObservations: [LimitProbeObservation]) {
        var keys = Set(observations.map { "\($0.signalKind.rawValue):\($0.sanitizedEvidence.lowercased())" })
        for observation in newObservations {
            let key = "\(observation.signalKind.rawValue):\(observation.sanitizedEvidence.lowercased())"
            guard !keys.contains(key) else { continue }
            keys.insert(key)
            observations.append(observation)
        }
    }

    fileprivate func record(networkEvent event: NetworkProbeEvent) {
        let key = "\(event.method):\(event.pathHint):\(event.matchedFields.joined(separator: ","))"
        let existing = Set(networkEvents.map { "\($0.method):\($0.pathHint):\($0.matchedFields.joined(separator: ","))" })
        guard !existing.contains(key), !event.matchedFields.isEmpty else { return }
        networkEvents.insert(event, at: 0)
    }

    private static let networkProbeScript = #"""
    (() => {
      if (window.__contextPanelLimitProbeInstalled) return;
      window.__contextPanelLimitProbeInstalled = true;
      const candidate = /limit|usage|remaining|reset|quota|message|model|plan|cap/i;

      function pathHint(rawUrl) {
        try { return new URL(rawUrl, window.location.href).pathname; }
        catch (_) { return String(rawUrl || '').split('?')[0].slice(0, 180); }
      }

      function collectFields(value, prefix = '', out = new Set(), depth = 0) {
        if (!value || depth > 3 || out.size > 80) return out;
        if (Array.isArray(value)) {
          value.slice(0, 3).forEach(item => collectFields(item, prefix, out, depth + 1));
          return out;
        }
        if (typeof value !== 'object') return out;
        Object.keys(value).forEach(key => {
          const full = prefix ? `${prefix}.${key}` : key;
          if (candidate.test(full)) out.add(full);
          collectFields(value[key], full, out, depth + 1);
        });
        return out;
      }

      function post(event) {
        try { window.webkit.messageHandlers.limitProbe.postMessage(event); }
        catch (_) {}
      }

      function inspect(method, url, status, contentType, text) {
        const body = String(text || '');
        let fields = [];
        if (/json/i.test(contentType || '') && body.length < 2_000_000) {
          try { fields = Array.from(collectFields(JSON.parse(body))).slice(0, 40); }
          catch (_) { fields = []; }
        }
        if (fields.length === 0) return;
        post({
          method: method || 'GET',
          pathHint: pathHint(url),
          status: status || null,
          contentType: contentType || null,
          bodySize: body.length,
          matchedFields: fields
        });
      }

      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = async function(input, init) {
          const response = await originalFetch.apply(this, arguments);
          try {
            const clone = response.clone();
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            const method = (init && init.method) || (input && input.method) || 'GET';
            const contentType = clone.headers.get('content-type') || '';
            clone.text().then(text => inspect(method, url, clone.status, contentType, text)).catch(() => {});
          } catch (_) {}
          return response;
        };
      }

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__cpMethod = method;
        this.__cpUrl = url;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try {
            const contentType = this.getResponseHeader('content-type') || '';
            inspect(this.__cpMethod || 'GET', this.__cpUrl || '', this.status, contentType, this.responseText || '');
          } catch (_) {}
        });
        return originalSend.apply(this, arguments);
      };
    })();
    """#
}

final class ProbeScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ProbeModel?

    init(owner: ProbeModel) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        let method = payload["method"] as? String ?? "GET"
        let pathHint = payload["pathHint"] as? String ?? ""
        let status = payload["status"] as? Int
        let contentType = payload["contentType"] as? String
        let bodySize = payload["bodySize"] as? Int
        let matchedFields = payload["matchedFields"] as? [String] ?? []
        let event = NetworkProbeEvent(
            observedAt: Date(),
            method: method,
            pathHint: pathHint,
            status: status,
            contentType: contentType,
            bodySize: bodySize,
            matchedFields: matchedFields
        )
        Task { @MainActor [weak owner = self.owner] in
            owner?.record(networkEvent: event)
        }
    }
}

struct ProbeWebView: NSViewRepresentable {
    @ObservedObject var model: ProbeModel

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
