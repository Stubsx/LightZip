import AppKit

NSUpdateDynamicServices()
for name in ["用轻压解压", "用轻压压缩…"] {
    let result = NSSetShowsServicesMenuItem(name, true)
    print("\(name)：\(result)")
}
