import SwiftUI

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 22) {
                helpRow("浏览", "双击压缩包或拖入窗口，双击文件夹进入。")
                helpRow("预览与打开", "选中文件按空格预览，双击用对应应用打开。")
                helpRow("解压与保存", "点「全部解压」保留文件；修改临时文件后请另存。")
                helpRow("找回密码", "在「更多」中选择「找回密码」。")
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                helpRow("解压格式", "ZIP、7Z、RAR、TAR、GZ、BZ2、XZ")
                helpRow("压缩格式", "ZIP（通用）或 7Z（更小）")
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("按需解压，关闭压缩包后清理临时文件。")
                Text("分卷放在同一文件夹，打开首卷；TAR.GZ 等需要再解一层。")
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).contentSurface(radius: 16)
    }

    private func helpRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Text(title).font(Theme.emphasis).frame(width: 84, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
