import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: AboutInfo.icon)
                .resizable()
                .frame(width: 88, height: 88)

            Text("AutoDucking")
                .font(.title2.weight(.semibold))

            Text("版本 \(AboutInfo.version)（构建 \(AboutInfo.buildDisplay)）")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("作者：Zhang Yonglei")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("麦克风被占用时自动降低系统音量，结束后平滑恢复。不录音，不读取音频内容。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            ChangelogView(text: AboutInfo.changelog)

            HStack {
                Text("© 2026 Zhang Yonglei")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("好") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 520)
    }
}

private struct ChangelogView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("## ") {
                        Text(String(line.dropFirst(3)))
                            .font(.headline)
                            .padding(.top, 4)
                    } else if line.hasPrefix("- ") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(String(line.dropFirst(2)))
                        }
                        .font(.callout)
                    } else if line.hasPrefix("# ") {
                        EmptyView()
                    } else if !line.isEmpty {
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lines: [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private enum AboutInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    static var buildDisplay: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        guard build.count == 12, build.allSatisfy(\.isNumber) else { return build }

        let year = build.prefix(4)
        let month = build.dropFirst(4).prefix(2)
        let day = build.dropFirst(6).prefix(2)
        let hour = build.dropFirst(8).prefix(2)
        let minute = build.dropFirst(10).prefix(2)
        return "\(year).\(month).\(day) \(hour):\(minute)"
    }

    static var icon: NSImage {
        if let icon = NSApp.applicationIconImage {
            return icon
        }
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        return NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) ?? NSImage()
    }

    static var changelog: String {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }

        let devURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("CHANGELOG.md")
        if let content = try? String(contentsOf: devURL, encoding: .utf8) {
            return content
        }

        return "暂无版本说明"
    }
}
