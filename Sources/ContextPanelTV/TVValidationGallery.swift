import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import SwiftUI
import UIKit

private enum TVValidationSurface: String, CaseIterable, Identifiable {
    case runway
    case provider
    case topShelf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .runway: "Runway"
        case .provider: "Provider detail"
        case .topShelf: "Top Shelf"
        }
    }
}

@MainActor
struct TVValidationGalleryView: View {
    @State private var surface = TVValidationSurface.runway
    @State private var state = TVValidationState.healthy
    @State private var presentationModeRawValue = TVPresentationMode.fullDetail.rawValue
    @State private var providerRawValue = Provider.openAI.rawValue
    @State private var topShelfScale = 1

    private let adapter = TVValidationFixtureAdapter()

    init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let rawSurface = environment["CONTEXT_PANEL_TV_VALIDATION_SURFACE"],
           let surface = TVValidationSurface(rawValue: rawSurface) {
            _surface = State(initialValue: surface)
        }
        if let rawState = environment["CONTEXT_PANEL_TV_VALIDATION_STATE"],
           let state = TVValidationState(rawValue: rawState) {
            _state = State(initialValue: state)
        }
        if let rawMode = environment["CONTEXT_PANEL_TV_VALIDATION_MODE"],
           TVPresentationMode(rawValue: rawMode) != nil {
            _presentationModeRawValue = State(initialValue: rawMode)
        }
        if let providerRawValue = environment["CONTEXT_PANEL_TV_VALIDATION_PROVIDER"],
           Provider(rawValue: providerRawValue) != nil {
            _providerRawValue = State(initialValue: providerRawValue)
        }
        if let rawScale = environment["CONTEXT_PANEL_TV_VALIDATION_SCALE"],
           let scale = Int(rawScale),
           scale == 1 || scale == 2 {
            _topShelfScale = State(initialValue: scale)
        }
        #endif
    }

    private var context: TVValidationFixtureContext {
        adapter.context(state: state)
    }

    private var presentationMode: TVPresentationMode {
        TVPresentationMode(rawValue: presentationModeRawValue) ?? .fullDetail
    }

    private var presentation: TVRunwayPresentation {
        TVRunwayPresentation(
            snapshot: context.snapshot,
            preferences: context.displayPreferences,
            mode: presentationMode,
            isRefreshing: state == .loading,
            now: context.presentationDate
        )
    }

    private var forecast: KeepWorkingForecast? {
        guard context.snapshot.state == .ready else { return nil }
        let forecast = context.snapshot.keepWorkingForecast(
            presentationDate: context.presentationDate
        )
        return forecast.remainingPercent == nil ? nil : forecast
    }

    private var selectedProviderSection: TVProviderRunwaySection? {
        presentation.sections.first { $0.provider.rawValue == providerRawValue }
            ?? presentation.sections.first
    }

    var body: some View {
        VStack(spacing: 0) {
            sampleBanner
            controls
            Divider().opacity(0.25)
            preview
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Validation Gallery")
        .onChange(of: presentation.sections.map(\.provider.rawValue), initial: true) { _, providers in
            if !providers.contains(providerRawValue), let first = providers.first {
                providerRawValue = first
            }
        }
    }

    private var sampleBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "testtube.2")
            Text("SAMPLE DATA")
                .tracking(1.2)
            Spacer()
            Text("READ ONLY")
        }
        .font(.headline.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 44)
        .padding(.vertical, 15)
        .background(Color.orange.opacity(0.13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample data. Read only shared-view proof.")
    }

    private var controls: some View {
        HStack(spacing: 24) {
            validationMenu(title: "Surface", value: surface.displayName) {
                Picker("Surface", selection: $surface) {
                    ForEach(TVValidationSurface.allCases) { surface in
                        Text(surface.displayName).tag(surface)
                    }
                }
            }

            validationMenu(title: "State", value: state.displayName) {
                Picker("State", selection: $state) {
                    ForEach(TVValidationState.allCases) { state in
                        Text(state.displayName).tag(state)
                    }
                }
            }

            validationMenu(title: "Presentation", value: presentationMode.displayName) {
                Picker("Presentation", selection: $presentationModeRawValue) {
                    ForEach(TVPresentationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            }

            if surface == .provider, !presentation.sections.isEmpty {
                validationMenu(
                    title: "Provider",
                    value: selectedProviderSection?.provider.displayName ?? "Unavailable"
                ) {
                    Picker("Provider", selection: $providerRawValue) {
                        ForEach(presentation.sections) { section in
                            Text(section.provider.displayName).tag(section.provider.rawValue)
                        }
                    }
                }
            }

            if surface == .topShelf {
                validationMenu(title: "Scale", value: "\(topShelfScale)×") {
                    Picker("Scale", selection: $topShelfScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                    }
                }
            }

            Spacer()
            Text("Shared-view proof · real Top Shelf placement is separate")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var preview: some View {
        switch surface {
        case .runway:
            TVRunwayContent(
                presentation: presentation,
                receivedAt: context.receivedAt,
                keepWorkingForecast: forecast,
                isRefreshing: state == .loading,
                presentationModeRawValue: $presentationModeRawValue,
                noticeMessage: context.result.errorMessage,
                presentationDate: context.presentationDate,
                detailActionMode: .readOnly,
                onRefresh: {}
            )
            .accessibilityElement(children: .contain)

        case .provider:
            if let section = selectedProviderSection {
                TVProviderDetailView(
                    section: section,
                    mode: presentationMode,
                    snapshotState: presentation.state,
                    generatedAt: presentation.generatedAt,
                    presentationDate: context.presentationDate,
                    detailActionMode: .readOnly
                )
                .accessibilityElement(children: .contain)
            } else {
                unavailablePreview("No provider detail is available for this sample state.")
            }

        case .topShelf:
            TVTopShelfValidationPreview(
                snapshot: context.snapshot,
                preferences: context.displayPreferences,
                mode: presentationMode,
                presentationDate: context.presentationDate,
                scale: CGFloat(topShelfScale)
            )
        }
    }

    private func validationMenu<Content: View>(
        title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
            .frame(minWidth: 150, alignment: .leading)
        }
    }

    private func unavailablePreview(_ message: String) -> some View {
        ContentUnavailableView(
            "Sample unavailable",
            systemImage: "rectangle.slash",
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct TVTopShelfValidationPreview: View {
    let snapshot: WidgetSnapshot
    let preferences: WidgetDisplayPreferences
    let mode: TVPresentationMode
    let presentationDate: Date
    let scale: CGFloat

    @State private var renderedImage: UIImage?
    @State private var accessibilityLabel = "Top Shelf sample preview"
    @State private var isRendering = true

    private struct RenderID: Equatable {
        let document: TVTopShelfDocument
        let scale: CGFloat
    }

    private struct RenderOutput: Sendable {
        let imageData: Data?
        let accessibilityLabel: String
    }

    private var document: TVTopShelfDocument {
        TVTopShelfDocument(
            snapshot: snapshot,
            preferences: preferences,
            mode: mode,
            now: presentationDate
        )
    }

    private var renderID: RenderID {
        RenderID(
            document: document,
            scale: scale
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(accessibilityLabel)
            } else if isRendering {
                ProgressView("Rendering production preview")
                    .font(.headline)
            } else {
                ContentUnavailableView(
                    "Top Shelf preview unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The production renderer could not create this sample image.")
                )
            }

            Text("Production renderer · in-memory sample · no cache or TVServices publication")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.018, green: 0.028, blue: 0.052))
        .allowsHitTesting(false)
        .focusable(false)
        .task(id: renderID) {
            await renderPreview()
        }
    }

    private func renderPreview() async {
        isRendering = true
        renderedImage = nil
        let document = document
        let presentationDate = presentationDate
        let scale = scale
        let renderTask = Task.detached(priority: .userInitiated) { () -> RenderOutput? in
            guard !Task.isCancelled else { return nil }
            let renderer = TVTopShelfRenderer()
            let imageData = try? renderer.imageData(
                    document: document,
                    now: presentationDate,
                    scale: scale
                )
            guard !Task.isCancelled else { return nil }
            return RenderOutput(
                imageData: imageData,
                accessibilityLabel: renderer.semanticTitle(
                    document: document,
                    cards: document.renderedCards,
                    now: presentationDate
                )
            )
        }
        let output = await withTaskCancellationHandler(
            operation: { await renderTask.value },
            onCancel: { renderTask.cancel() }
        )
        guard !Task.isCancelled, let output else { return }
        renderedImage = output.imageData.flatMap(UIImage.init(data:))
        accessibilityLabel = output.accessibilityLabel
        isRendering = false
    }
}
