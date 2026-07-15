import Charts
import CodexMeterCore
import SwiftUI

struct MeterView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 348)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.14))
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Meter")
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task {
                    await store.refresh()
                    await store.refreshActivity()
                }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("Refresh usage")
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh Codex usage")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            quotaContent
            if let activity = store.activity {
                Divider()
                LocalActivityView(activity: activity, rates: store.costRates)
            } else if let activityError = store.activityError {
                Divider()
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local activity unavailable")
                            .font(.system(size: 11, weight: .medium))
                        Text(activityError)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if store.payload == nil && store.isRefreshing {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Codex usage…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 148)
        } else if store.windows.isEmpty {
            EmptyState(message: store.errorMessage ?? "Usage data is unavailable.") {
                Task { await store.refresh() }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.windows.enumerated()), id: \.offset) { index, window in
                    UsageRow(window: window)
                    if index < store.windows.count - 1 { Divider().padding(.leading, 16) }
                }
                if let error = store.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Menu bar")
                    .font(.system(size: 12))
                Spacer()
                Picker("Menu bar display", selection: $store.displayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            HStack {
                Text("Low-usage alert")
                    .font(.system(size: 12))
                Spacer()
                Picker("Low-usage alert", selection: $store.alertThreshold) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                }
                .labelsHidden()
                .frame(width: 72)
            }
            DisclosureGroup("Custom cost estimate") {
                VStack(spacing: 7) {
                    CostRateField(label: "Input", value: $store.inputRate)
                    CostRateField(label: "Cached input", value: $store.cachedInputRate)
                    CostRateField(label: "Output", value: $store.outputRate)
                    Text("Your rates in USD per million tokens. Estimates are API-equivalent, not subscription spend.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))
            HStack {
                Button("Open Codex") { store.openCodex() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        if store.isStale { return "Last update is stale" }
        if let date = store.payload?.fetchedAt {
            return "Updated \(date.formatted(date: .omitted, time: .shortened))\(store.planLabel.map { " · \($0)" } ?? "")"
        }
        return "Signed in through the Codex app"
    }
}

private struct LocalActivityView: View {
    let activity: LocalActivitySnapshot
    let rates: LocalCostRates

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local activity")
                        .font(.system(size: 12, weight: .medium))
                    Text("Seven days · read from local session logs")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(compactTokens(activity.total.totalTokens))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Chart(activity.days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Tokens", day.usage.totalTokens)
                )
                .foregroundStyle(Color.accentColor)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 62)
            .accessibilityLabel("Seven-day local token activity")
            .accessibilityValue(accessibilitySummary)

            HStack {
                Text("Today \(compactTokens(activity.today.totalTokens))")
                Spacer()
                if rates.isConfigured {
                    Text(String(format: "API-equivalent ≈ $%.2f", rates.estimate(activity.total)))
                } else {
                    Text("Cost estimate off")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func compactTokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private var accessibilitySummary: String {
        activity.days.map { day in
            "\(day.date.formatted(.dateTime.weekday(.wide))): \(day.usage.totalTokens) tokens"
        }.joined(separator: ", ")
    }
}

private struct CostRateField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: $value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            Text("$/M")
                .foregroundStyle(.secondary)
        }
    }
}

private struct UsageRow: View {
    let window: RateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(window.displayName)
                            .font(.system(size: 12, weight: .medium))
                        if let warningText {
                            Text(warningText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(meterColor)
                        }
                    }
                    Text(ResetTimeFormatter.relativeText(for: window.resetsAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(ResetTimeFormatter.absoluteText(for: window.resetsAt) ?? "")
                }
                Spacer()
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("\(window.remainingPercent) percent remaining")
            }

            ProgressView(value: Double(window.remainingPercent), total: 100)
                .progressViewStyle(.linear)
                .tint(meterColor)
                .accessibilityLabel(window.displayName)
                .accessibilityValue("\(window.remainingPercent) percent remaining. \(ResetTimeFormatter.relativeText(for: window.resetsAt))")
        }
        .padding(16)
    }

    private var meterColor: Color {
        if window.remainingPercent <= 10 { return .red }
        if window.remainingPercent <= 25 { return .orange }
        return .accentColor
    }

    private var warningText: String? {
        if window.remainingPercent <= 10 { return "Nearly exhausted" }
        if window.remainingPercent <= 25 { return "Running low" }
        return nil
    }
}

private struct EmptyState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Usage unavailable")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button("Try again", action: retry)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 166)
        .padding(.horizontal, 20)
    }
}
