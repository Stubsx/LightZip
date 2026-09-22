import Foundation

public enum FinderOperation: String, Sendable { case extract, compress }

public struct FinderSelection: Sendable {
    public let operation: FinderOperation
    public let files: [URL]

    public init(operation: FinderOperation, files: [URL]) throws {
        guard !files.isEmpty else { throw ArchiveFailure.message("请先在访达中选择文件。") }
        guard files.allSatisfy(\.isFileURL) else { throw ArchiveFailure.message("轻压服务仅处理本机文件。") }
        var seen = Set<String>()
        let unique = files.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        if operation == .extract && unique.count != 1 {
            throw ArchiveFailure.message("请一次选择一个压缩包进行解压。多个文件可使用“用轻压压缩”。")
        }
        for file in unique {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory) else {
                throw ArchiveFailure.message("文件已移动或无法访问：\(file.lastPathComponent)")
            }
            if operation == .extract && directory.boolValue { throw ArchiveFailure.message("请选择压缩包文件进行解压。") }
        }
        self.operation = operation
        self.files = unique
    }
}
