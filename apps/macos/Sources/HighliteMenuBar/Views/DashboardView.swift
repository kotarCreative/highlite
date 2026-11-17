import SwiftUI
import HighliteMenuBarCore

struct DashboardView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<DashboardSection?> {
        Binding(
            get: { Optional(model.dashboardSection) },
            set: { value in
                if let value {
                    model.dashboardSection = value
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(DashboardTheme.canvas)
            .navigationSplitViewColumnWidth(
                min: AppWindowLayout.sidebarMinimumWidth,
                ideal: AppWindowLayout.sidebarIdealWidth,
                max: AppWindowLayout.sidebarMaximumWidth
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarRelayStatus(model: model)
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    BannerView(message: error, isError: true) {
                        model.clearError()
                    }
                } else if let notice = model.notice {
                    BannerView(message: notice, isError: false) {
                        model.setNotice(nil)
                    }
                }

                switch model.dashboardSection {
                case .overview:
                    OverviewView(model: model)
                case .sessions:
                    SessionsView(model: model)
                case .activity:
                    ActivityView(model: model)
                case .providers:
                    ProvidersView(model: model)
                case .jira:
                    JiraRecipeView(model: model)
                case .openCode:
                    OpenCodeRecipeView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .frame(
                minWidth: AppWindowLayout.detailMinimumWidth,
                maxWidth: .infinity,
                minHeight: AppWindowLayout.detailMinimumHeight,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background(DashboardTheme.canvas)
        }
        .navigationTitle("Highlite")
        // The sidebar is a fixed part of the dashboard; keep its column visible
        // instead of offering the default toolbar hide/show control.
        .toolbar(removing: .sidebarToggle)
        .tint(DashboardTheme.primary)
    }
}

private struct SidebarRelayStatus: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.relay.phase.color)
                .frame(width: 7, height: 7)
            Text(model.relay.phase.label)
                .font(.caption.weight(.medium))
            Spacer(minLength: 4)
            if let version = model.relay.relayVersion {
                Text("v\(version)")
                    .font(.caption2)
                    .foregroundStyle(DashboardTheme.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(DashboardTheme.canvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DashboardTheme.line)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Relay \(model.relay.phase.label)")
    }
}
