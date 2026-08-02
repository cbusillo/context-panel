import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private struct ValidationGalleryActivityModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isParticipating = false

    #if os(macOS)
    @State private var activityToken: NSObjectProtocol?
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                if scenePhase == .active {
                    start()
                }
            }
            .onDisappear {
                stop()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    start()
                } else {
                    stop()
                }
            }
    }

    private func start() {
        guard !isParticipating else { return }
        isParticipating = true
        #if os(macOS)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Context Panel validation gallery is visible"
        )
        #elseif canImport(UIKit)
        ValidationGalleryIdleTimerCoordinator.start()
        #endif
    }

    private func stop() {
        guard isParticipating else { return }
        isParticipating = false
        #if os(macOS)
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        #elseif canImport(UIKit)
        ValidationGalleryIdleTimerCoordinator.stop()
        #endif
    }
}

#if canImport(UIKit) && !os(macOS)
@MainActor
private enum ValidationGalleryIdleTimerCoordinator {
    private static var participantCount = 0
    private static var previousIdleTimerDisabled: Bool?

    static func start() {
        if participantCount == 0 {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        participantCount += 1
    }

    static func stop() {
        guard participantCount > 0 else { return }
        participantCount -= 1
        guard participantCount == 0 else { return }
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        previousIdleTimerDisabled = nil
    }
}
#endif

extension View {
    func validationGalleryActivity() -> some View {
        modifier(ValidationGalleryActivityModifier())
    }
}
