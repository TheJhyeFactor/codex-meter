import Charts
import CodexMeterCore
import SwiftUI

struct MeterView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("usageWindowsExpanded") private var usageWindowsExpanded = true
    @AppStorage("localActivityExpanded") private var localActivityExpanded = true
    @AppStorage("settingsExpanded") private var settingsExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                settings
            }
            if let celebration = store.celebration {
                CelebrationBanner(celebration: celebration)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.celebration)
        .frame(width: 348)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.42), lineWidth: 0.75)
        }
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
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: store.isRefreshing)
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
            DisclosureGroup(isExpanded: $usageWindowsExpanded) {
                quotaContent
            } label: {
                SectionLabel(title: "Usage windows", detail: store.activeAccountName)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.3), lineWidth: 0.6)
            }
            if let activity = store.activity {
                Divider()
                DisclosureGroup(isExpanded: $localActivityExpanded) {
                    LocalActivityView(activity: activity, rates: store.costRates, currency: store.currency, totalSavings: store.totalSavings)
                        .padding(.horizontal, -16)
                } label: {
                    SectionLabel(title: "Local activity", detail: "\(compactTokens(activity.total.totalTokens)) tokens")
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.3), lineWidth: 0.6)
                }
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

    private var settings: some View {
        DisclosureGroup(isExpanded: $settingsExpanded) {
            footer
        } label: {
            SectionLabel(title: "Settings", detail: "Display, alerts and accounts")
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.3), lineWidth: 0.6)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Account")
                    .font(.system(size: 12))
                Spacer()
                Picker("Account", selection: Binding(
                    get: { store.activeAccountID },
                    set: { store.switchAccount(to: $0) }
                )) {
                    ForEach(store.accounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                Button {
                    store.addAccount()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add Codex account")
                .accessibilityLabel("Add Codex account")
            }
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
                Text("Currency")
                    .font(.system(size: 12))
                Spacer()
                Picker("Currency", selection: $store.currency) {
                    ForEach(DisplayCurrency.allCases) { currency in
                        Text(currency.code).tag(currency)
                    }
                }
                .labelsHidden()
                .frame(width: 72)
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
            DisclosureGroup("Fallback USD price for unknown models") {
                VStack(spacing: 7) {
                    CostRateField(label: "Input", value: $store.inputRate)
                    CostRateField(label: "Cached input", value: $store.cachedInputRate)
                    CostRateField(label: "Output", value: $store.outputRate)
                    Text("Only used when a model has no bundled official price. USD per million tokens.")
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

    private func compactTokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct SectionLabel: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct CelebrationBanner: View {
    let celebration: Celebration

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: celebration.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(celebration.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(celebration.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentColor.opacity(0.35)))
        .padding(.horizontal, 12)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

private struct LocalActivityView: View {
    let activity: LocalActivitySnapshot
    let rates: LocalCostRates
    let currency: DisplayCurrency
    let totalSavings: Double

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

            if !activity.models.isEmpty {
                VStack(spacing: 6) {
                    ForEach(activity.models) { item in
                        HStack(spacing: 8) {
                            Text(item.model)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(modelShare(item))
                                .foregroundStyle(.secondary)
                            Text(modelCost(item))
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                        .font(.system(size: 10))
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            HStack {
                Text("Today \(compactTokens(activity.today.totalTokens))")
                Spacer()
                Text("API-equivalent ≈ \(formatted(automaticEstimate))")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            Text("API prices checked 15 Jul 2026 · estimate only")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if totalSavings > 0 {
                Text("Estimated savings vs GPT-5.6 Sol: \(formatted(totalSavings))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(16)
    }

    private var automaticEstimate: Double {
        let usd = activity.models.reduce(0) { total, item in
            if let price = OpenAIPriceCatalog.price(for: item.model) { return total + price.estimate(item.usage) }
            return total + (rates.isConfigured ? rates.estimate(item.usage) : 0)
        }
        return currency.convertFromUSD(usd)
    }

    private func modelCost(_ item: ModelTokenUsage) -> String {
        if let price = OpenAIPriceCatalog.price(for: item.model) {
            return formatted(currency.convertFromUSD(price.estimate(item.usage)))
        }
        if rates.isConfigured { return formatted(currency.convertFromUSD(rates.estimate(item.usage))) + "*" }
        return "Unpriced"
    }

    private func modelShare(_ item: ModelTokenUsage) -> String {
        guard activity.total.totalTokens > 0 else { return "0%" }
        return "\(Int((Double(item.usage.totalTokens) / Double(activity.total.totalTokens) * 100).rounded()))% · \(compactTokens(item.usage.totalTokens))"
    }

    private func formatted(_ amount: Double) -> String {
        "\(currency.symbol)\(amount.formatted(.number.precision(.fractionLength(2))))"
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
                .animation(.easeInOut(duration: 0.45), value: window.remainingPercent)
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
