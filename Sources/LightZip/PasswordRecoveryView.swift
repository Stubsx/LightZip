import AppKit
import SwiftUI
import ArchiveCore

struct PasswordRecoveryView: View {
    @EnvironmentObject var model: AppModel
    @State private var characters: RecoveryCharacters = .digits
    @State private var maximum = 6
    @State private var useDictionary = false
    @State private var dictionary: URL?
    @State private var rules = 0
    @State private var ruleFile: URL?
    @State private var reveal = false
    @State private var showingDetails = false

    private var canStart: Bool { !useDictionary || (dictionary != nil && (rules != 2 || ruleFile != nil)) }
    private var rangeDescription: String {
        useDictionary ? "字典 · \(dictionary?.lastPathComponent ?? "")" : "1–\(maximum) 位 · \(characters.title)"
    }
    private var percentage: String {
        let fraction = model.recoveryProgress.fraction
        if fraction > 0 && fraction < 0.0001 { return "不足 0.01%" }
        let value = fraction >= 1 ? 100 : min(99.99, fraction * 100)
        return value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("找回密码", systemImage: "key").font(Theme.heading)
            Text(model.files.first?.lastPathComponent ?? "压缩包").lineLimit(1).truncationMode(.middle)
            if let password = model.recoveredPassword {
                VStack(alignment: .leading, spacing: 14) {
                    Label("已找到密码", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(Theme.emphasis)
                    HStack {
                        Text(reveal ? password : String(repeating: "•", count: min(password.count, 16)))
                            .font(.system(size: 18, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button(reveal ? "隐藏" : "显示") { reveal.toggle() }.secondaryActionStyle()
                    }.fieldSurface()
                }
            } else if model.recoveryRunning {
                Text(rangeDescription).foregroundStyle(.secondary)
            } else {
                configuration
            }
            if model.recoveryRunning { progress }
            if !model.recoveryRunning, let message = model.recoveryMessage {
                Text(message).foregroundStyle(model.recoveredPassword == nil ? .secondary : Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Spacer()
                if model.recoveryRunning {
                    Button("停止") { model.cancel() }.secondaryActionStyle()
                } else {
                    Button("关闭") { model.showingRecovery = false }.secondaryActionStyle()
                        .keyboardShortcut(.cancelAction)
                    if model.recoveredPassword != nil {
                        Button("使用密码并继续") { model.useRecoveredPassword() }
                            .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large).keyboardShortcut(.defaultAction)
                    } else {
                        Button("开始找回") { start() }.buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                            .disabled(!canStart).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.font(Theme.body).padding(28).frame(width: 530).background(Theme.canvas)
            .interactiveDismissDisabled(model.recoveryRunning)
            .onChange(of: characters) { _, value in maximum = min(maximum, value.maximumLength) }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !useDictionary {
                HStack(spacing: 18) {
                    Text("最多位数").frame(width: 72, alignment: .leading)
                    Menu {
                        ForEach(1...characters.maximumLength, id: \.self) { length in
                            Button("\(length) 位") { maximum = length }
                        }
                    } label: { choiceLabel("\(maximum) 位") }
                        .accessibilityLabel("最多位数：\(maximum) 位")
                }
                HStack(spacing: 18) {
                    Text("密码类型").frame(width: 72, alignment: .leading)
                    Menu {
                        ForEach(RecoveryCharacters.allCases, id: \.self) { option in
                            Button(option.title) { characters = option }
                        }
                    } label: { choiceLabel(characters.title) }
                        .accessibilityLabel("密码类型：\(characters.title)")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("批量尝试所选范围，找到后自动停止。")
                    if characters == .alphanumeric { Text("字母包含大小写英文。") }
                    if characters == .all { Text("包含大小写英文、常见英文标点及空格。") }
                    if characters.candidateCount(maximum: maximum) > 1_000_000_000 {
                        Text("这个范围组合较多，可能需要很长时间。")
                    }
                }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("字典与规则（高级）", isExpanded: $useDictionary) {
                VStack(alignment: .leading, spacing: 16) {
                    fileButton("选择字典…", file: dictionary) { dictionary = chooseFile("选择密码字典") }
                    Picker("变换规则", selection: $rules) {
                        Text("不变换").tag(0)
                        Text("常见变换").tag(1)
                        Text("自定义规则").tag(2)
                    }.controlSize(.large)
                    if rules == 2 { fileButton("选择规则文件…", file: ruleFile) { ruleFile = chooseFile("选择 Hashcat 规则文件") } }
                    Text(rules == 1 ? "每行一个密码；尝试大小写及数字、年份后缀。" : "每行一个密码，推荐英文字符；自定义规则采用 Hashcat 格式。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 14)
            }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.recoveryProgress.total > 0 {
                HStack {
                    Text(model.recoveryRunning ? model.recoveryProgress.message : "本次已检查")
                    Spacer()
                    Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: model.recoveryProgress.fraction)
                Text("进度表示已检查的范围，找到密码后会提前结束。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("运行详情", isExpanded: $showingDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(count(model.recoveryProgress.completed)) / \(count(model.recoveryProgress.total)) 个候选")
                        Text("\(count(model.recoveryProgress.speed)) 次/秒")
                        if !model.recoveryProgress.device.isEmpty { Text(model.recoveryProgress.device) }
                        if model.recoveryProgress.rejected > 0 { Text("已跳过 \(model.recoveryProgress.rejected) 个不支持的候选。") }
                    }.monospacedDigit().foregroundStyle(.secondary).padding(.top, 10)
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.recoveryProgress.message)
                }
            }
        }
    }

    private func choiceLabel(_ title: String) -> some View {
        HStack {
            Text(title).font(Theme.body)
            Spacer()
            Image(systemName: "chevron.down").foregroundStyle(.secondary)
        }.fieldSurface()
    }

    private func fileButton(_ title: String, file: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "doc.text")
                Text(file?.lastPathComponent ?? title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Image(systemName: "folder")
            }.fieldSurface()
        }.buttonStyle(.plain).help(file?.path ?? title)
    }

    private func chooseFile(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title; panel.prompt = "选择"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start() {
        showingDetails = false
        if !useDictionary { model.startRecovery(.mask(characters: characters, min: 1, max: maximum)) }
        else if let dictionary {
            let selectedRules: RecoveryRules = rules == 1 ? .common : rules == 2 ? ruleFile.map(RecoveryRules.custom) ?? .none : .none
            model.startRecovery(.dictionary(dictionary, rules: selectedRules))
        }
    }

    private func count(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
}
