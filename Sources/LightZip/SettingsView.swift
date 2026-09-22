import SwiftUI
import AppKit
import FinderSync

struct SettingsView: View {
    @State private var finderEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var showingManualPath = false
    @EnvironmentObject private var defaultApplication: DefaultArchiveApplication
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    settingIcon("cursorarrow.click.2")
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            Text("访达右键菜单").font(Theme.emphasis)
                            Label(finderEnabled ? "已启用" : "未启用",
                                  systemImage: finderEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.secondary)
                        }
                        Text("选中文件或文件夹，直接右键压缩或解压。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        FIFinderSyncController.showExtensionManagementInterface()
                    } label: {
                        Text(finderEnabled ? "管理右键菜单" : "启用右键菜单")
                            .frame(minWidth: 112, minHeight: 24)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                    .help("直接打开系统设置中的轻压扩展开关")
                }
                .padding(22)

                Divider().padding(.horizontal, 22)

                HStack(spacing: 20) {
                    settingIcon("arrow.up.forward.app")
                    VStack(alignment: .leading, spacing: 9) {
                        Text("默认打开应用").font(Theme.emphasis)
                        Text("双击 ZIP、7Z、RAR 等压缩包，用轻压查看。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { defaultApplication.setAsDefault() } label: {
                        Text(defaultApplication.isSetting ? "正在设置…" : "设为默认应用")
                            .frame(minWidth: 112, minHeight: 24)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                    .disabled(defaultApplication.isSetting)
                }
                .padding(22)

                if !defaultApplication.resultMessage.isEmpty {
                    Text(defaultApplication.resultMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.bottom, 20)
                }
            }
            .contentSurface(radius: 16)

            HStack(spacing: 18) {
                Text("版本 \(updater.version)")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize()
                UpdateStatusIndicator(updater: updater)
                Spacer(minLength: 8)
                Toggle("自动更新", isOn: Binding(
                    get: { updater.automaticUpdates }, set: { updater.setAutomaticUpdates($0) }
                ))
                .toggleStyle(.switch).tint(Theme.accent).fixedSize()
                .help("运行时每天检查，自动下载并在退出时安装。")
                Button { updater.checkForUpdates() } label: {
                    Text("检查更新").frame(minWidth: 80, minHeight: 24)
                }
                .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                .disabled(!updater.canCheck || model.busy)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .contentSurface(radius: 16)

            DisclosureGroup("手动设置路径", isExpanded: $showingManualPath) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("系统设置 → 通用 → 登录项与扩展")
                    Text("扩展 → 按类别 → 文件提供程序 → 轻压")
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 6)
        }
        .font(Theme.body)
        .onAppear { refreshFinderStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFinderStatus()
        }
    }

    private func settingIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Theme.accent)
            .frame(width: 30)
            .accessibilityHidden(true)
    }

    private func refreshFinderStatus() {
        finderEnabled = FIFinderSyncController.isExtensionEnabled
    }
}
