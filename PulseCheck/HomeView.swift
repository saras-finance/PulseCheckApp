import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: GroupStore
    @EnvironmentObject var healthEngine: HealthCheckEngine

    var allUp: Int { store.groups.flatMap(\.endpoints).filter { $0.currentStatus == .up }.count }
    var allDown: Int { store.groups.flatMap(\.endpoints).filter { $0.currentStatus == .down }.count }
    var total: Int { store.groups.flatMap(\.endpoints).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Summary banner
                    SummaryBanner(up: allUp, down: allDown, total: total)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    if store.groups.isEmpty {
                        EmptyStateView()
                            .padding(.top, 60)
                    } else {
                        LazyVStack(spacing: 12, pinnedViews: []) {
                            ForEach(store.groups) { group in
                                GroupCardView(group: group)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    
                    BrandingFooter()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("PulseCheck")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await healthEngine.runAllChecksOnce() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
            }
        }
    }
}

struct BrandingFooter: View {
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("Made with")
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("by Saras AI Team")
            }
            .font(.system(size: 12, weight: .medium))
            
            Text("© 2026 sarasfinance.com")
                .font(.system(size: 10))
        }
        .foregroundStyle(.tertiary)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Summary Banner
struct SummaryBanner: View {
    let up: Int, down: Int, total: Int

    var body: some View {
        HStack(spacing: 12) {
            StatPill(value: "\(up)/\(total)", label: "Healthy", color: .green)
            if down > 0 {
                StatPill(value: "\(down)", label: "Down", color: .red)
            }
            Spacer()
            if total > 0 {
                let pct = total > 0 ? Int(Double(up)/Double(total)*100) : 100
                Text("\(pct)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(down > 0 ? .red : .green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(down > 0 ? Color.red.opacity(0.3) : Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}

struct StatPill: View {
    let value: String, label: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Group Card
struct GroupCardView: View {
    let group: Group
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Group header
            Button(action: { withAnimation(.spring(response: 0.35)) { expanded.toggle() } }) {
                HStack {
                    StatusDot(status: group.overallStatus, size: 10)
                    Text(group.name)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(group.endpoints.count) endpoint\(group.endpoints.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if expanded && !group.endpoints.isEmpty {
                Divider().padding(.horizontal, 16)
                ForEach(Array(group.endpoints.enumerated()), id: \.element.id) { idx, endpoint in
                    NavigationLink(destination: DetailView(group: group, endpoint: endpoint)) {
                        EndpointRowView(endpoint: endpoint)
                    }
                    .buttonStyle(.plain)
                    if idx < group.endpoints.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

// MARK: - Endpoint Row
struct EndpointRowView: View {
    let endpoint: EndpointItem

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: endpoint.currentStatus, size: 8)
                .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Text(endpoint.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                StatusBadge(status: endpoint.currentStatus)
                if let ms = endpoint.averageResponseMs {
                    Text(String(format: "%.0fms", ms))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared Components
struct StatusDot: View {
    let status: HealthStatus
    let size: CGFloat

    var color: Color {
        switch status {
        case .up: return .green
        case .down: return .red
        case .pending: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle().fill(color.opacity(0.3)).frame(width: size + 4, height: size + 4)
                    .opacity(status == .down ? 1 : 0)
            )
    }
}

struct StatusBadge: View {
    let status: HealthStatus

    var color: Color {
        switch status {
        case .up: return .green
        case .down: return .red
        case .pending: return .orange
        case .unknown: return .gray
        }
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No endpoints yet")
                .font(.title3.weight(.semibold))
            Text("Go to Configure to add your first\nhealth check group.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
