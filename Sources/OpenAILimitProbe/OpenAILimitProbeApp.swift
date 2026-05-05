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
            Label("The probe observes visible text only in this prototype.", systemImage: "eye")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
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
    @Published var manualObservation = ""
    @Published var isExportingReport = false

    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        loadChatGPT()
    }

    var reportMarkdown: String {
        LimitProbeReport(provider: .openAI, capturedAt: Date(), observations: observations).markdownSummary
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
