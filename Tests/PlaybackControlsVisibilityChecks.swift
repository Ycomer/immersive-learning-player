import SwiftUI
import Foundation

@main struct PlaybackControlsVisibilityChecks {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw StudyError.message(message) }
        }
        let visibility = PlaybackControlsVisibility(delayNanoseconds: 60_000_000)
        // Playback state is deliberately irrelevant: paused video must also hide.
        visibility.reveal(canHide: true)
        try await Task.sleep(nanoseconds: 110_000_000)
        try check(!visibility.visible, "Controls stayed visible without mouse activity")
        visibility.reveal(canHide: true)
        try check(visibility.visible, "Mouse entry did not immediately reveal controls")
        try await Task.sleep(nanoseconds: 35_000_000)
        visibility.reveal(canHide: true)
        try await Task.sleep(nanoseconds: 35_000_000)
        try check(visibility.visible, "An obsolete timer hid controls after fresh mouse movement")
        visibility.reveal(canHide: false)
        try await Task.sleep(nanoseconds: 110_000_000)
        try check(visibility.visible, "Hover/slider/drag/popup pin did not cancel hide")
        visibility.scheduleHide(allowed: true)
        try await Task.sleep(nanoseconds: 110_000_000)
        try check(!visibility.visible, "Leaving controls did not restore auto hide")
        visibility.reveal(canHide: true);visibility.cancel()
        try await Task.sleep(nanoseconds: 110_000_000)
        try check(visibility.visible, "Cancelled/disappeared view fired a stale timer")
        print("PASS: idle hides independently of playback; mouse entry reveals; mouse motion resets deadline; interaction pins; cancellation prevents stale hide")
    }
}
