import AppKit
import Combine
import CodexMeterCore
import SwiftUI

@main
struct CodexMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private lazy var store = UsageStore(previewMode: ProcessInfo.processInfo.arguments.contains("--preview"))
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let previewMode = ProcessInfo.processInfo.arguments.contains("--preview")
        NSApp.setActivationPolicy(previewMode ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Codex usage")
            button.imagePosition = .imageLeading
            button.title = "—"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MeterView(store: store))

        if previewMode {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 348, height: 680),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex Meter"
            window.contentViewController = NSHostingController(rootView: MeterView(store: store))
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }

        store.start()
        Publishers.CombineLatest4(store.$payload, store.$errorMessage, store.$displayMode, store.$activity)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        store.$currency
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        updateStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Codex Meter", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func refresh() { Task { await store.refresh() } }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if let window = store.menuBarWindow {
            let remaining = window.remainingPercent
            switch store.displayMode {
            case .iconAndPercentage:
                button.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Codex usage")
                button.imagePosition = .imageLeading
                button.title = "\(remaining)%"
            case .resetAndPercentage:
                let countdown = ResetCountdownFormatter.format(until: window.resetsAt)
                button.image = weeklyBadgeImage(countdown: countdown, remaining: remaining, pace: WeeklyPace(window: window))
                button.imagePosition = .imageOnly
                button.title = ""
            case .percentage:
                button.image = nil
                button.title = "\(remaining)%"
            case .icon:
                button.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "Codex usage")
                button.imagePosition = .imageOnly
                button.title = ""
            case .activity:
                let days = store.activity?.days ?? []
                button.image = days.isEmpty
                    ? NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Codex activity")
                    : activityImage(from: days)
                button.imagePosition = .imageOnly
                button.title = ""
            }
            let countdown = ResetCountdownFormatter.format(until: window.resetsAt)
            let exactReset = window.resetsAt.map {
                " Resets \($0.formatted(date: .abbreviated, time: .shortened))."
            } ?? ""
            let paceText = WeeklyPace(window: window).map { " Weekly pace: \($0.summaryText)." } ?? ""
            button.toolTip = "\(window.displayName): \(remaining)% remaining. \(countdown.accessibilityText).\(exactReset)\(paceText)"
        } else {
            button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Codex usage unavailable")
            button.title = "—"
            if let error = store.errorMessage {
                button.toolTip = "Codex usage unavailable: \(error)"
            } else if store.isStale, let updated = store.payload?.fetchedAt {
                button.toolTip = "Codex usage is out of date. Last updated \(updated.formatted(date: .omitted, time: .shortened))."
            } else {
                button.toolTip = "Checking Codex usage"
            }
        }
        button.setAccessibilityLabel(button.toolTip ?? "Codex usage")
    }

    private func weeklyBadgeImage(countdown: ResetCountdown, remaining: Int, pace: WeeklyPace?) -> NSImage {
        let size = NSSize(width: 58, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let numberAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            let suffixAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
                .baselineOffset: 0.4
            ]

            self.countdownLine(countdown.daysText, numberAttributes: numberAttributes, suffixAttributes: suffixAttributes)
                .draw(in: NSRect(x: 3, y: 8.5, width: 17, height: 9.5))
            self.countdownLine(countdown.hoursText, numberAttributes: numberAttributes, suffixAttributes: suffixAttributes)
                .draw(in: NSRect(x: 3, y: -0.5, width: 17, height: 9.5))

            let percentParagraph = NSMutableParagraphStyle()
            percentParagraph.alignment = .center
            let percentAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.75, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: percentParagraph
            ]
            NSAttributedString(string: "\(remaining)%", attributes: percentAttributes)
                .draw(in: NSRect(x: 21, y: 7.75, width: 34, height: 10.25))

            let rail = NSRect(x: 25, y: 2.5, width: 27, height: 3)
            NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
            let centerLineWidth: CGFloat = 0.5
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(rect: NSRect(x: rail.midX - centerLineWidth / 2, y: rail.minY, width: centerLineWidth, height: rail.height)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(rect: NSRect(x: rail.midX - centerLineWidth / 2, y: rail.maxY, width: centerLineWidth, height: 1.25)).fill()
            NSBezierPath(rect: NSRect(x: rail.midX - centerLineWidth / 2, y: rail.minY - 1.25, width: centerLineWidth, height: 1.25)).fill()
            NSColor.black.setFill()
            if let pace {
                let markerX = rail.midX + CGFloat(pace.markerPosition) * (rail.width / 2 - 2)
                NSBezierPath(ovalIn: NSRect(x: markerX - 3, y: rail.midY - 3, width: 6, height: 6)).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: NSRect(x: markerX - 1.5, y: rail.midY - 1.5, width: 3, height: 3)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(remaining) percent remaining, \(countdown.accessibilityText)\(pace.map { ", weekly pace \($0.summaryText)" } ?? "")"
        return image
    }

    private func countdownLine(
        _ text: String,
        numberAttributes: [NSAttributedString.Key: Any],
        suffixAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard let suffix = text.last, suffix == "d" || suffix == "h" else {
            return NSAttributedString(string: text, attributes: numberAttributes)
        }
        let line = NSMutableAttributedString(string: String(text.dropLast()), attributes: numberAttributes)
        line.append(NSAttributedString(string: "\u{2009}\(suffix)", attributes: suffixAttributes))
        return line
    }

    private func activityImage(from days: [DailyTokenUsage]) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 14))
        image.lockFocus()
        defer { image.unlockFocus() }
        let values = days.suffix(7).map { Double($0.usage.totalTokens) }
        let maximum = max(values.max() ?? 1, 1)
        NSColor.labelColor.setFill()
        for (index, value) in values.enumerated() {
            let height = max(2, 12 * value / maximum)
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * 3.1, y: 1, width: 2.2, height: CGFloat(height)), xRadius: 0.7, yRadius: 0.7).fill()
        }
        image.isTemplate = true
        image.accessibilityDescription = "Seven-day Codex activity"
        return image
    }
}
