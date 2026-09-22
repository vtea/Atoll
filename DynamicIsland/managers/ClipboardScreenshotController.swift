/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import Foundation

/// Hides Atoll chrome, runs `screencapture` into the pasteboard, then restores the UI.
///
/// The image is not written a second time: `-c` already put it on `NSPasteboard.general`,
/// and `ClipboardManager` records it from `changeCount`.
@MainActor
final class ClipboardScreenshotController {
    static let shared = ClipboardScreenshotController()

    private var isBusy = false

    private init() {}

    func capture(_ type: ScreenshotSnippingTool.ScreenshotType) {
        guard Defaults[.enableClipboardManager] else { return }
        guard !isBusy, !ScreenshotSnippingTool.shared.isSnipping else { return }

        isBusy = true

        if !ClipboardManager.shared.isMonitoring {
            ClipboardManager.shared.startMonitoring()
        }

        let restorePanel = ClipboardPanelManager.shared.isPanelVisible
        ClipboardPanelManager.shared.hideClipboardPanel()

        DynamicIslandViewCoordinator.shared.suppressHoverOpen(for: 120)
        AppDelegate.shared?.hideNotchWindowsForScreenshot()

        Task { @MainActor [restorePanel] in
            try? await Task.sleep(for: .milliseconds(200))
            guard self.isBusy else { return }
            ScreenshotSnippingTool.shared.captureToPasteboard(type: type) { _ in
                Task { @MainActor in
                    self.restoreChrome(restorePanel: restorePanel)
                }
            }
        }
    }

    private func restoreChrome(restorePanel: Bool) {
        DynamicIslandViewCoordinator.shared.suppressHoverOpen(for: 0.35)
        AppDelegate.shared?.restoreNotchWindowsAfterScreenshot()
        if restorePanel {
            ClipboardPanelManager.shared.showClipboardPanel()
        }
        isBusy = false
    }
}
