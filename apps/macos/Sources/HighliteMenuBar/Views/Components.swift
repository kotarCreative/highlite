import AppKit
import Foundation
import SwiftUI
import HighliteMenuBarCore

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case sessions
    case activity
    case providers
    case jira
    case openCode
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .sessions: return "Sessions"
        case .activity: return "Activity"
        case .providers: return "Providers"
        case .jira: return "Jira recipe"
        case .openCode: return "OpenCode recipe"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .sessions: return "rectangle.stack"
        case .activity: return "clock.arrow.circlepath"
        case .providers: return "sparkles"
        case .jira: return "ticket"
        case .openCode: return "terminal"
        case .settings: return "gearshape"
        }
    }
}

struct BannerView: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.blue)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(12)
        .background((isError ? Color.red : Color.blue).opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct CopyButton: View {
    let title: String
    let value: String?
    var help: String? = nil

    @State private var feedback: Feedback?
    @State private var resetTask: Task<Void, Never>?

    private enum Feedback {
        case copied
        case failed
    }

    var body: some View {
        Button {
            copy()
        } label: {
            Label(label, systemImage: icon)
        }
        .disabled(value?.isEmpty != false)
        .frame(minWidth: DashboardStyle.copyButtonMinimumWidth)
        .help(helpText)
        .accessibilityHint(Text(helpText))
        .onDisappear {
            resetTask?.cancel()
            feedback = nil
        }
    }

    private var label: String {
        switch feedback {
        case .copied: return "Copied"
        case .failed: return "Copy failed"
        case nil: return title
        }
    }

    private var icon: String {
        switch feedback {
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case nil: return "doc.on.doc"
        }
    }

    private var helpText: String {
        switch feedback {
        case .copied: return "\(title) copied to the clipboard."
        case .failed: return "\(title) could not be copied to the clipboard."
        case nil: return help ?? title
        }
    }

    private func copy() {
        guard let value, !value.isEmpty else { return }
        resetTask?.cancel()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let succeeded = pasteboard.setString(value, forType: .string)
        feedback = succeeded ? .copied : .failed
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct Card<Content: View>: View {
    let title: String?
    let icon: String?
    let content: Content

    init(
        _ title: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardStyle.controlSpacing) {
            if let title {
                HStack(spacing: 7) {
                    if let icon {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.headline)
                }
            }
            content
        }
        .padding(DashboardStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}

struct CodeBlock: View {
    let text: String
    var scrolls = false
    var minHeight: CGFloat? = nil
    var maxHeight: CGFloat? = nil

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    code
                }
            } else {
                code
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: minHeight,
            maxHeight: maxHeight,
            alignment: .topLeading
        )
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: DashboardStyle.codeCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DashboardStyle.codeCornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    private var code: some View {
        Text(text)
            .font(.system(size: DashboardStyle.codeFontSize, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}

struct EmptyHint: View {
    let title: String
    let detail: String
    var systemImage = "sparkles"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: DashboardStyle.emptyStateMinimumHeight)
    }
}

enum Display {
    static func date(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "—" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relative(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "—" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }
}

extension SessionStatus {
    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .ready: return .green
        case .failed: return .red
        }
    }
}

extension RelayPhase {
    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .running: return .green
        case .checking, .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

extension JiraRunStatus {
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing"
        case .draft: return "Draft ready"
        case .failed: return "Failed"
        case .publishing: return "Publishing"
        case .published: return "Published"
        case .publishUnknown: return "Publish unknown"
        }
    }

    var color: Color {
        switch self {
        case .draft, .published: return .green
        case .failed, .publishUnknown: return .red
        case .queued, .analyzing, .publishing: return .orange
        }
    }
}

extension OpenCodeRunStatus {
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing"
        case .suggested: return "Suggested"
        case .failed: return "Failed"
        case .submitting: return "Submitting"
        case .submitted: return "Submitted"
        case .submitUnknown: return "Submit unknown"
        }
    }

    var color: Color {
        switch self {
        case .suggested, .submitted: return .green
        case .failed, .submitUnknown: return .red
        case .queued, .analyzing, .submitting: return .orange
        }
    }
}

extension ActivityItem {
    var statusColor: Color {
        if status.contains("fail") || status.contains("unknown") { return .red }
        if status.contains("publish") || status.contains("submit") || status.contains("suggest") {
            return .green
        }
        return .orange
    }
}
