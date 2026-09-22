import SwiftUI
import AppKit
import QuickLook

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var defaultApplication = DefaultArchiveApplication()
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            navigation
            VStack(alignment: .leading, spacing: 12) {
                if let page = model.informationPage {
                    Text(page.rawValue).font(Theme.heading).foregroundStyle(Theme.ink).frame(height: 44)
                    ScrollView {
                        Group {
                            if page == .settings {
                                SettingsView().environmentObject(defaultApplication)
                            } else {
                                HelpView()
                            }
                        }
                        .frame(maxWidth: 780, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.mode == .history {
                    Text("最近任务").font(Theme.heading).foregroundStyle(Theme.ink).frame(height: 44)
                    history
                }
                else { ArchiveWorkspace() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.trailing, 24)
        }
        .font(Theme.body)
        .padding(.leading, 12).padding(.vertical, 8)
        .background(Theme.canvas.ignoresSafeArea())
        .background(IntegratedTitleBar())
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.mode)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.busy else { return false }
            model.receive(urls); return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.accent, lineWidth: 2).padding(5).allowsHitTesting(false) }
        }
        .sheet(isPresented: $model.showingPassword, onDismiss: model.passwordSheetDidDismiss) { ArchivePasswordSheet() }
        .sheet(isPresented: $model.showingRecovery, onDismiss: model.recoverySheetDidDismiss) { PasswordRecoveryView() }
        .quickLookPreview($model.previewURL)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshDirectory()
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").font(.system(size: 27, weight: .medium)).foregroundStyle(Theme.accent)
                Text("轻压").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink)
            }.padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 34)
            VStack(spacing: 6) {
                ForEach(WorkspaceMode.allCases, id: \.self) { mode in
                    navigationButton(mode.rawValue, symbol: mode.symbol,
                                     selected: model.informationPage == nil && model.mode == mode) {
                        model.switchMode(mode)
                    }
                }
            }
            .padding(.horizontal, 10)
            Spacer()
            Divider().padding(.horizontal, 24).padding(.bottom, 14)
            VStack(spacing: 8) {
                navigationButton("设置", symbol: "gearshape", selected: model.informationPage == .settings) {
                    model.showInformationPage(.settings)
                }
                .help("配置访达右键菜单和默认打开应用")
                navigationButton("使用说明", symbol: "questionmark.circle", selected: model.informationPage == .help) {
                    model.showInformationPage(.help)
                }
            }
            .padding(.horizontal, 10)
            Text("轻压 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
        }.frame(width: 190).frame(maxHeight: .infinity)
            .glassEffect(.regular.tint(.blue.opacity(0.025)), in: RoundedRectangle(cornerRadius: 22))
    }

    private func navigationButton(_ title: String, symbol: String, selected: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.accent)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(selected ? Theme.emphasis : Theme.body)
            .padding(.horizontal, 14).frame(height: 46)
            .foregroundStyle(selected ? Theme.accent : Theme.ink.opacity(0.85))
            .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.busy).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var history: some View {
        Group {
            if model.records.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
                    Text("还没有任务记录").font(.system(size: 18, weight: .medium))
                    Text("完成压缩或解压后，结果会显示在这里。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentSurface()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.records) { record in
                            HStack(spacing: 14) {
                                Image(systemName: record.output == nil ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 22)).foregroundStyle(record.output == nil ? .orange : Theme.accent)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(record.name).font(Theme.emphasis).lineLimit(1)
                                    Text("\(record.operation) · \(record.date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_Hans_CN")))) · \(record.detail)")
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if let url = record.output {
                                    Button("显示文件") { model.reveal(url) }.secondaryActionStyle()
                                }
                            }.padding(20).contentSurface(radius: 16)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
