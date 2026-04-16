import AppKit
import Foundation

@MainActor
final class VPhoneClipboardAutoSync {
    private let control: VPhoneControl
    private var timer: Timer?
    private var lastObservedChangeCount: Int?
    private var lastSyncedText: String?
    private var syncTask: Task<Void, Never>?
    private var pendingText: String?

    init(control: VPhoneControl) {
        self.control = control
    }

    func start() {
        stop()
        lastObservedChangeCount = NSPasteboard.general.changeCount
        syncCurrentClipboardIfNeeded(force: true)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.syncCurrentClipboardIfNeeded(force: false)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncTask?.cancel()
        syncTask = nil
        pendingText = nil
    }

    private func syncCurrentClipboardIfNeeded(force: Bool) {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        if !force, let lastObservedChangeCount, changeCount == lastObservedChangeCount {
            return
        }
        lastObservedChangeCount = changeCount

        guard let text = pasteboard.string(forType: .string) else {
            return
        }
        if !force, text == lastSyncedText {
            return
        }

        enqueueSync(text: text)
    }

    private func enqueueSync(text: String) {
        pendingText = text
        guard syncTask == nil else { return }

        syncTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled, let nextText = self.pendingText {
                self.pendingText = nil

                do {
                    try await self.control.clipboardSet(text: nextText)
                    self.lastSyncedText = nextText
                } catch {
                    print("[clipboard-sync] host -> guest sync failed: \(error)")
                }
            }

            self.syncTask = nil

            if !Task.isCancelled, self.pendingText != nil {
                self.enqueueSync(text: self.pendingText!)
            }
        }
    }
}
