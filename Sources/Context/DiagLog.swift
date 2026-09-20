import AppKit

/// 排查日志：追加写 ~/Library/Logs/AppWindow.log。全主线程调用，无需加锁。
/// 默认关闭，菜单栏「诊断日志」开关控制，状态持久化到 UserDefaults；
/// 开启时用户复现问题，开发直接读文件定位。文件过大时会话首次写入前清空。
enum DiagLog {

    private static let path = NSString(string: "~/Library/Logs/AppWindow.log").expandingTildeInPath
    private static let rotateThreshold = 5_000_000
    private static let enabledKey = "diagLogEnabled"

    /// UserDefaults 未设置时 bool 返回 false，即发布版默认不写日志
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                log("diag", "enabled, pid=\(ProcessInfo.processInfo.processIdentifier)")
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static var rotated = false

    static func log(_ tag: String, _ message: String) {
        guard isEnabled else { return }
        rotateIfNeeded()
        let line = "\(timeFormatter.string(from: Date())) [\(tag)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 会话内首次写入前检查大小，超限清空（测试期日志量有限，不做归档轮转）
    private static func rotateIfNeeded() {
        guard !rotated else { return }
        rotated = true
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
           size > rotateThreshold {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
