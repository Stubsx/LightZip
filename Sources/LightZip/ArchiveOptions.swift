import SwiftUI

struct ArchiveOptions: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var levelName: String { model.level == 1 ? "快速压缩" : model.level == 9 ? "更小体积" : "标准压缩" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("压缩设置").font(Theme.heading)
            field("压缩包名称") {
                HStack {
                    TextField("输入名称", text: $model.archiveName).textFieldStyle(.plain).accessibilityLabel("压缩包名称")
                    Text(".\(model.format)").foregroundStyle(.secondary)
                }.fieldSurface()
            }
            HStack(spacing: 18) {
                field("格式") {
                    Menu {
                        Button("ZIP · 通用") { model.format = "zip" }
                        Button("7Z · 更小") { model.format = "7z" }
                    } label: {
                        HStack {
                            Text(model.format == "zip" ? "ZIP · 通用" : "7Z · 更小").font(Theme.body)
                            Spacer()
                            Image(systemName: "chevron.down")
                        }.fieldSurface()
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("格式：\(model.format.uppercased())")
                }
                field("压缩程度") {
                    Menu {
                        Button("快速压缩") { model.level = 1 }
                        Button("标准压缩") { model.level = 5 }
                        Button("更小体积") { model.level = 9 }
                    } label: {
                        HStack {
                            Text(levelName).font(Theme.body)
                            Spacer()
                            Image(systemName: "chevron.down")
                        }.fieldSurface()
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("压缩程度：\(levelName)")
                }
            }
            field("保存位置") {
                Button { model.chooseDestination() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        Text(model.destination.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").foregroundStyle(.secondary)
                    }.fieldSurface()
                }.buttonStyle(.plain).help(model.destination.path).accessibilityLabel("选择保存位置")
            }
            field("加密密码（可选）") {
                SecureField("留空则不加密", text: $model.password).textFieldStyle(.plain).fieldSurface().accessibilityLabel("加密密码")
            }
            Text(model.format == "zip" ? "ZIP 密码使用英文字符；中文密码请选择 7Z。" : "设置密码后，同时隐藏压缩包内的文件名。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }.font(Theme.body).padding(28).frame(width: 530).background(Theme.canvas)
            .onExitCommand { dismiss() }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(Theme.emphasis).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ArchivePasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("输入解压密码", systemImage: "lock").font(Theme.heading)
            Text(model.files.first?.lastPathComponent ?? "压缩包").lineLimit(1).truncationMode(.middle)
            Text(model.passwordMessage).foregroundStyle(.secondary)
            SecureField("密码", text: $model.password)
                .textFieldStyle(.plain).fieldSurface().focused($passwordFocused)
                .onSubmit { if !model.password.isEmpty { model.confirmPassword() } }
            HStack(spacing: 12) {
                Button("找回密码…") { model.requestRecovery() }.secondaryActionStyle()
                Spacer()
                Button("取消") { model.showingPassword = false }.secondaryActionStyle()
                    .keyboardShortcut(.cancelAction)
                Button("继续") { model.confirmPassword() }.buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                    .disabled(model.password.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.font(Theme.body).padding(28).frame(width: 440).background(Theme.canvas)
            .onAppear { passwordFocused = true }
    }
}
