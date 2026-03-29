import SwiftUI
import Charts

struct DetailView: View {
    let group: Group
    let endpoint: EndpointItem
    @EnvironmentObject var store: GroupStore
    @EnvironmentObject var healthEngine: HealthCheckEngine
    @State private var isRefreshing = false

    // Pull live endpoint from store
    private var live: EndpointItem {
        store.group(for: group.id)?.endpoints.first(where: { $0.id == endpoint.id }) ?? endpoint
    }

    private var liveGroup: Group {
        store.group(for: group.id) ?? group
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // Hero status card
                StatusHeroCard(endpoint: live, group: liveGroup, isRefreshing: $isRefreshing) {
                    Task {
                        isRefreshing = true
                        await healthEngine.check(endpointId: live.id, groupId: liveGroup.id)
                        isRefreshing = false
                    }
                }

                // Stats row
                StatsRowView(endpoint: live)

                // Uptime chart (last 24 checks)
                if !live.history.isEmpty {
                    UptimeChartCard(history: live.history)
                    HistoryListCard(history: live.history)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(live.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await healthEngine.check(endpointId: live.id, groupId: liveGroup.id)
        }
    }
}

// MARK: - Hero Status Card
struct StatusHeroCard: View {
    let endpoint: EndpointItem
    let group: Group
    @Binding var isRefreshing: Bool
    let onRefresh: () -> Void

    var statusColor: Color {
        switch endpoint.currentStatus {
        case .up: return .green
        case .down: return .red
        case .pending: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.caption).foregroundStyle(.secondary)
                    Text(endpoint.url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 14, height: 14)
                            .shadow(color: statusColor.opacity(0.6), radius: 6)
                        Text(endpoint.currentStatus.label)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(statusColor)
                    }
                    if let lastChecked = endpoint.lastChecked {
                        Text("Last checked \(lastChecked.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Cadence badge
                VStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Every \(endpoint.cadence.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(statusColor.opacity(0.3), lineWidth: 1.5)
        )
    }
}

// MARK: - Stats Row
struct StatsRowView: View {
    let endpoint: EndpointItem

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Uptime",
                value: String(format: "%.1f%%", endpoint.uptimePercent),
                icon: "checkmark.shield",
                color: endpoint.uptimePercent > 95 ? .green : endpoint.uptimePercent > 80 ? .orange : .red
            )
            if let avg = endpoint.averageResponseMs {
                StatCard(
                    title: "Avg Response",
                    value: String(format: "%.0fms", avg),
                    icon: "bolt",
                    color: avg < 200 ? .green : avg < 500 ? .orange : .red
                )
            }
            StatCard(
                title: "Checks",
                value: "\(endpoint.history.count)",
                icon: "list.bullet",
                color: .blue
            )
        }
    }
}

struct StatCard: View {
    let title: String, value: String, icon: String, color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Uptime Chart
struct UptimeChartCard: View {
    let history: [HealthRecord]

    private var recent: [HealthRecord] {
        Array(history.suffix(48))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uptime · Last \(recent.count) checks")
                .font(.subheadline.weight(.semibold))

            Chart(recent) { record in
                BarMark(
                    x: .value("Time", record.timestamp),
                    y: .value("Status", record.status == .up ? 1 : 0),
                    width: .fixed(6)
                )
                .foregroundStyle(record.status == .up ? Color.green : Color.red)
                .cornerRadius(3)
            }
            .frame(height: 60)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { val in
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - History List
struct HistoryListCard: View {
    let history: [HealthRecord]
    @State private var showAll = false

    private var displayed: [HealthRecord] {
        let sorted = history.sorted { $0.timestamp > $1.timestamp }
        return showAll ? sorted : Array(sorted.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(Array(displayed.enumerated()), id: \.element.id) { idx, record in
                HistoryRow(record: record)
                if idx < displayed.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }

            if history.count > 10 {
                Button(action: { withAnimation { showAll.toggle() } }) {
                    Text(showAll ? "Show less" : "Show all \(history.count) records")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundStyle(.tint)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct HistoryRow: View {
    let record: HealthRecord

    var statusColor: Color {
        record.status == .up ? .green : .red
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                Text(record.timestamp.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if let code = record.statusCode {
                    Text("HTTP \(code)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let ms = record.responseTimeMs {
                    Text(String(format: "%.0fms", ms))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let err = record.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 10)
    }
}
