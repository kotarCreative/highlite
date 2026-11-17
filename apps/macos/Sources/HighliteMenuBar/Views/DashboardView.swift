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
            .navigationSplitViewColumnWidth(
                min: AppWindowLayout.sidebarMinimumWidth,
                ideal: AppWindowLayout.sidebarIdealWidth,
                max: AppWindowLayout.sidebarMaximumWidth
            )
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
        }
        .navigationTitle("Highlite")
    }
}
