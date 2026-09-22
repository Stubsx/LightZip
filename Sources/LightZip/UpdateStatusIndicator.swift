import SwiftUI

struct UpdateStatusIndicator: View {
    @ObservedObject var updater: AppUpdater

    private var color: Color {
        switch updater.phase {
        case .unchecked, .noUpdate: return .secondary
        case .current, .ready: return .green
        case .failed, .incompatible: return .orange
        default: return Theme.accent
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(updater.shortStatus).foregroundStyle(.secondary)
        }
        .lineLimit(1).fixedSize()
        .help(updater.statusHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("更新状态：\(updater.shortStatus)")
        .accessibilityValue(updater.status)
    }
}
