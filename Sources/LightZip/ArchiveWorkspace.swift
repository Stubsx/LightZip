import SwiftUI
import AppKit
import ArchiveCore

struct ArchiveWorkspace: View {
    @EnvironmentObject var model: AppModel
    @State private var showingOptions = false

    var body: some View {
        VStack(spacing: 0) {
            operations
            if !model.files.isEmpty && (model.busy || model.result != nil || model.notice != nil) { feedback }
            Divider().opacity(0.5)
            if model.files.isEmpty { emptyState }
            else if model.mode == .extract { contents }
            else { selection }
        }
        .font(Theme.body)
        .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 280)
        .contentSurface()
        .sheet(isPresented: $showingOptions) { ArchiveOptions() }
        .contextMenu {
            Button(model.mode == .extract ? "打开压缩包…" : "添加文件…") { model.chooseFiles() }.disabled(model.busy)
            if !model.files.isEmpty {
                Button(model.mode == .extract ? "关闭压缩包" : "清空选择") { model.reset() }.disabled(model.busy)
                if model.mode == .extract, let file = model.files.first {
                    Divider()
                    Button("在访达中显示压缩包") { model.reveal(file) }
                    Button("解压到当前文件夹") { model.destination = file.deletingLastPathComponent(); model.start() }.disabled(model.busy)
                }
            }
        }
    }

    private var operations: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.mode == .extract ? "doc.zipper" : "shippingbox")
                    .font(.system(size: 20)).foregroundStyle(Theme.accent)
                Text(model.mode == .extract ? model.files.first?.lastPathComponent ?? "打开压缩包" : "创建压缩包")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.mode == .extract ? model.files.first?.lastPathComponent ?? "打开压缩包" : "创建压缩包")
            }.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            if model.files.isEmpty || model.mode == .compress {
                Button { model.chooseFiles() } label: {
                    actionLabel(model.mode == .extract ? "打开压缩包" : "添加文件", "plus")
                }.buttonStyle(.glassProminent).tint(Theme.accent).disabled(model.busy).fixedSize()
            }
            if !model.files.isEmpty && model.mode == .extract {
                Button { model.previewSelectedItem() } label: { actionLabel("预览", "eye") }
                    .secondaryActionStyle().fixedSize().disabled(model.busy || model.selectedItem == nil || model.selectedItem?.isDirectory == true)
                    .help(model.workspace?.isSolid == true ? "快速查看（空格）；固实压缩首次读取可能较慢" : "快速查看（空格）").accessibilityLabel("快速查看")
                Button { model.openSelectedItem() } label: { actionLabel("打开", "arrow.up.forward.square") }
                    .secondaryActionStyle().fixedSize().disabled(model.busy || model.selectedItem == nil)
                    .help("打开所选项目（回车）").accessibilityLabel("打开所选项目")
            }
            if !model.files.isEmpty {
                if model.mode == .compress {
                    Button { showingOptions = true } label: { actionLabel("压缩设置", "slider.horizontal.3") }
                        .secondaryActionStyle().fixedSize().disabled(model.busy)
                }
                if model.busy {
                    Button { model.cancel() } label: { actionLabel("取消任务", "xmark") }.secondaryActionStyle().fixedSize()
                } else {
                    Button {
                        if model.mode == .extract { model.extractAll() } else { model.start() }
                    } label: {
                        actionLabel(model.mode == .extract ? "全部解压" : "开始压缩", model.mode == .extract ? "arrow.down.to.line" : "shippingbox")
                    }.buttonStyle(.glassProminent).tint(Theme.accent).fixedSize().disabled(!model.canStart)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Menu {
                    Button(model.mode == .extract ? "打开其他压缩包…" : "添加文件…") { model.chooseFiles() }
                    if model.mode == .extract {
                        Button("输入解压密码…") { model.requestPassword() }
                        Button("找回密码…") { model.requestRecovery() }
                    }
                    if let file = model.files.first { Button("在访达中显示\(model.mode == .extract ? "压缩包" : "源文件")") { model.reveal(file) } }
                    Divider()
                    Button(model.mode == .extract ? "关闭压缩包" : "清空选择") { model.reset() }
                } label: {
                    actionLabel("更多", "ellipsis")
                        .foregroundStyle(model.busy ? Color.secondary : Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(model.busy ? Color.secondary : Theme.accent)
                    .disabled(model.busy).accessibilityLabel("更多操作")
            }
        }
        .font(Theme.emphasis).controlSize(.large)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(Theme.emphasis).frame(height: 24)
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.status).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if model.progress > 0 { Text("\(Int(model.progress * 100))%").monospacedDigit().foregroundStyle(.secondary) }
                }
                if model.progress > 0 { ProgressView(value: model.progress) }
            } else if let result = model.result {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text("\(model.status) · \(result.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("在访达中显示") { model.reveal(result) }.secondaryActionStyle()
                }
            }
            if let notice = model.notice {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(notice).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .secondaryActionStyle().accessibilityLabel("关闭提示")
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: model.mode == .extract ? "archivebox" : "square.stack.3d.up")
                .font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
                .padding(.bottom, 4)
            Text(model.mode == .extract ? "拖入压缩包" : "拖入文件或文件夹")
                .font(.system(size: 20, weight: .medium))
            Text(model.mode == .extract ? "支持 ZIP、7Z、RAR 等常用格式" : "也可点击上方「添加文件」")
                .foregroundStyle(.secondary)
            if let notice = model.notice { Text(notice).foregroundStyle(.orange).multilineTextAlignment(.center) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contents: some View {
        VStack(spacing: 0) {
            if model.workspace == nil {
                VStack(spacing: 18) {
                    Image(systemName: model.busy ? "hourglass" : "archivebox").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text(model.busy ? "正在读取目录…" : model.result != nil ? "文件已解压到保存位置" : "打开压缩包，查看里面的文件")
                        .foregroundStyle(.secondary)
                    if !model.busy {
                        Button("打开内容") { model.openContents() }.secondaryActionStyle()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                directoryBar
                Divider().opacity(0.4)
                if model.filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.search.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 30, weight: .light))
                        Text(model.search.isEmpty ? "文件夹为空" : "没有匹配的项目")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedItemID) {
                        ForEach(model.filteredItems) { item in itemRow(item).tag(item.id) }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { identifiers in
                        if let item = model.items.first(where: { identifiers.contains($0.id) }) {
                            Button(item.isDirectory ? "打开文件夹" : "打开文件") { model.openItem(item) }
                            if !item.isDirectory { Button("快速查看") { model.previewItem(item) } }
                        }
                    } primaryAction: { identifiers in
                        if let item = model.items.first(where: { identifiers.contains($0.id) }) { model.openItem(item) }
                    }
                    .onKeyPress(.return) { model.openSelectedItem(); return .handled }
                    .onKeyPress(.space) { model.previewSelectedItem(); return .handled }
                    .onKeyPress(.rightArrow) {
                        guard let item = model.selectedItem, item.isDirectory else { return .ignored }
                        model.openItem(item); return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        guard !model.directoryComponents.isEmpty else { return .ignored }
                        model.navigate(to: Array(model.directoryComponents.dropLast())); return .handled
                    }
                    .disabled(model.busy)
                }
            }
        }
    }

    private var directoryBar: some View {
        HStack(spacing: 12) {
            Button { model.navigate(to: Array(model.directoryComponents.dropLast())) } label: {
                Image(systemName: "arrow.up").frame(width: 20, height: 24)
            }.secondaryActionStyle().disabled(model.directoryComponents.isEmpty)
                .help("上一级").accessibilityLabel("上一级")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button { model.navigate(to: []) } label: { Label("根目录", systemImage: "archivebox") }
                    ForEach(Array(model.directoryComponents.enumerated()), id: \.offset) { index, name in
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        Button(name) { model.navigate(to: Array(model.directoryComponents.prefix(index + 1))) }
                    }
                }.buttonStyle(.plain).foregroundStyle(model.busy ? Color.secondary : Theme.accent).frame(height: 38)
            }
            Text("\(model.filteredItems.count) 个项目").foregroundStyle(.secondary).monospacedDigit().fixedSize()
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索当前文件夹", text: $model.search).textFieldStyle(.plain)
            }.padding(.horizontal, 12).frame(width: 210, height: 38)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.7))
        }.padding(.horizontal, 18).padding(.vertical, 6).disabled(model.busy)
    }

    private func itemRow(_ item: WorkspaceItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 18)).foregroundStyle(item.isDirectory ? Theme.accent : .secondary).frame(width: 24)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            if item.isEncrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            Text(item.isDirectory ? "文件夹" : item.size.map(bytes) ?? "大小未知").foregroundStyle(.secondary).monospacedDigit()
            if item.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .font(Theme.body).padding(.horizontal, 6).frame(minHeight: 42).contentShape(Rectangle())
        .accessibilityAction(named: "打开") { model.openItem(item) }
    }

    private var selection: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(url.lastPathComponent).font(Theme.emphasis).lineLimit(1)
                            Text(url.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { model.removeFile(url) } label: { Image(systemName: "minus").frame(width: 24, height: 24) }
                            .secondaryActionStyle().help("从列表移除").accessibilityLabel("移除 \(url.lastPathComponent)")
                    }.padding(.horizontal, 22).padding(.vertical, 16)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("在访达中显示") { model.reveal(url) }
                            Button("从列表移除") { model.removeFile(url) }
                        }
                }
            }
        }.disabled(model.busy)
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
