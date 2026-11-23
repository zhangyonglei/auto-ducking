import Combine
import Foundation

public struct DuckingPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let duckLevel: Double
    public let attackDuration: Double
    public let releaseDuration: Double
    public let releaseDelay: Double

    public init(
        id: String,
        name: String,
        summary: String,
        duckLevel: Double,
        attackDuration: Double,
        releaseDuration: Double,
        releaseDelay: Double
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.duckLevel = duckLevel
        self.attackDuration = attackDuration
        self.releaseDuration = releaseDuration
        self.releaseDelay = releaseDelay
    }

    public static let voice = DuckingPreset(
        id: "voice",
        name: "语音输入",
        summary: "听写、语音输入场景，快速压低背景音乐不打断语感",
        duckLevel: 0.15,
        attackDuration: 0.10,
        releaseDuration: 0.35,
        releaseDelay: 0.20
    )

    public static let standard = DuckingPreset(
        id: "standard",
        name: "标准",
        summary: "日常默认档位，平衡闪避深度与恢复速度",
        duckLevel: 0.30,
        attackDuration: 0.20,
        releaseDuration: 0.50,
        releaseDelay: 0.80
    )

    public static let meeting = DuckingPreset(
        id: "meeting",
        name: "会议通话",
        summary: "视频会议与通话，音乐让位更明显，恢复稍慢",
        duckLevel: 0.20,
        attackDuration: 0.15,
        releaseDuration: 0.40,
        releaseDelay: 0.50
    )

    public static let focus = DuckingPreset(
        id: "focus",
        name: "深度录音",
        summary: "录音、播客录制，背景声几乎完全让出",
        duckLevel: 0.08,
        attackDuration: 0.30,
        releaseDuration: 0.60,
        releaseDelay: 1.50
    )

    public static let gentle = DuckingPreset(
        id: "gentle",
        name: "轻柔",
        summary: "低音量背景声，只做轻微让位",
        duckLevel: 0.55,
        attackDuration: 0.35,
        releaseDuration: 0.80,
        releaseDelay: 1.20
    )

    public static let all: [DuckingPreset] = [.voice, .standard, .meeting, .focus, .gentle]
}

/// 单个应用的闪避规则。两个可选项为 nil 时表示跟随「通用」页的全局设置。
public struct AppDuckingRule: Identifiable, Codable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var presetID: String?
    public var bypassOriginalVolume: Bool?

    public var id: String { bundleID }

    public init(
        bundleID: String,
        name: String,
        presetID: String? = nil,
        bypassOriginalVolume: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.presetID = presetID
        self.bypassOriginalVolume = bypassOriginalVolume
    }

    public var preset: DuckingPreset? {
        guard let presetID else { return nil }
        return DuckingPreset.all.first { $0.id == presetID }
    }

    /// 规则的应用 bundle 与音频进程的 bundle（含 helper 子进程）是否属于同一应用。
    public func matches(bundleIDs: [String]) -> Bool {
        bundleIDs.contains { candidate in
            guard !candidate.isEmpty else { return false }
            return candidate == bundleID
                || candidate.hasPrefix(bundleID + ".")
                || bundleID.hasPrefix(candidate + ".")
        }
    }
}

public struct DuckingParameters: Equatable, Sendable {
    public var duckLevel: Double
    public var attackDuration: Double
    public var releaseDuration: Double
    public var releaseDelay: Double
    public var bypassOriginalVolume: Bool

    public init(
        duckLevel: Double,
        attackDuration: Double,
        releaseDuration: Double,
        releaseDelay: Double,
        bypassOriginalVolume: Bool
    ) {
        self.duckLevel = duckLevel
        self.attackDuration = attackDuration
        self.releaseDuration = releaseDuration
        self.releaseDelay = releaseDelay
        self.bypassOriginalVolume = bypassOriginalVolume
    }
}

public final class SettingsStore: ObservableObject {
    public static let duckLevelRange: ClosedRange<Double> = 0.05...0.90
    public static let attackRange: ClosedRange<Double> = 0...1.5
    public static let releaseRange: ClosedRange<Double> = 0...2.0
    public static let releaseDelayRange: ClosedRange<Double> = 0...5.0

    private enum Key {
        static let enabled = "autoDucking.enabled"
        static let duckLevel = "autoDucking.duckLevel"
        static let attack = "autoDucking.attackDuration"
        static let release = "autoDucking.releaseDuration"
        static let releaseDelay = "autoDucking.releaseDelay"
        static let bypassConference = "autoDucking.bypassConferenceAudio"
        static let appRules = "autoDucking.appRules"
    }

    private let defaults: UserDefaults
    private var isBatchingUpdates = false

    public var onSettingsChange: (() -> Void)?

    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            notifyChange()
        }
    }

    @Published public var bypassConferenceAudio: Bool {
        didSet {
            defaults.set(bypassConferenceAudio, forKey: Key.bypassConference)
            notifyChange()
        }
    }

    @Published public var duckLevel: Double {
        didSet {
            defaults.set(duckLevel, forKey: Key.duckLevel)
            notifyChange()
        }
    }

    @Published public var attackDuration: Double {
        didSet {
            defaults.set(attackDuration, forKey: Key.attack)
            notifyChange()
        }
    }

    @Published public var releaseDuration: Double {
        didSet {
            defaults.set(releaseDuration, forKey: Key.release)
            notifyChange()
        }
    }

    @Published public var releaseDelay: Double {
        didSet {
            defaults.set(releaseDelay, forKey: Key.releaseDelay)
            notifyChange()
        }
    }

    @Published public var appRules: [AppDuckingRule] {
        didSet {
            persistAppRules()
            notifyChange()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        bypassConferenceAudio = defaults.object(forKey: Key.bypassConference) as? Bool ?? true
        duckLevel = Self.clamp(
            defaults.object(forKey: Key.duckLevel) as? Double ?? DuckingPreset.standard.duckLevel,
            to: Self.duckLevelRange
        )
        attackDuration = Self.clamp(
            defaults.object(forKey: Key.attack) as? Double ?? DuckingPreset.standard.attackDuration,
            to: Self.attackRange
        )
        releaseDuration = Self.clamp(
            defaults.object(forKey: Key.release) as? Double ?? DuckingPreset.standard.releaseDuration,
            to: Self.releaseRange
        )
        releaseDelay = Self.clamp(
            defaults.object(forKey: Key.releaseDelay) as? Double ?? DuckingPreset.standard.releaseDelay,
            to: Self.releaseDelayRange
        )
        if let data = defaults.data(forKey: Key.appRules),
           let stored = try? JSONDecoder().decode([AppDuckingRule].self, from: data) {
            var seen = Set<String>()
            appRules = stored.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
        } else {
            appRules = []
        }
    }

    public var globalParameters: DuckingParameters {
        DuckingParameters(
            duckLevel: duckLevel,
            attackDuration: attackDuration,
            releaseDuration: releaseDuration,
            releaseDelay: releaseDelay,
            bypassOriginalVolume: bypassConferenceAudio
        )
    }

    /// 与应用音频进程（含 helper 子进程）匹配的规则。
    public func rule(matching bundleIDs: [String]) -> AppDuckingRule? {
        guard !bundleIDs.isEmpty else { return nil }
        return appRules.first { $0.matches(bundleIDs: bundleIDs) }
    }

    /// 某个应用实际使用的闪避参数：应用规则优先，未设置的项回落到全局设置。
    public func parameters(for bundleIDs: [String]) -> DuckingParameters {
        var parameters = globalParameters
        guard let rule = rule(matching: bundleIDs) else { return parameters }

        if let preset = rule.preset {
            parameters.duckLevel = preset.duckLevel
            parameters.attackDuration = preset.attackDuration
            parameters.releaseDuration = preset.releaseDuration
            parameters.releaseDelay = preset.releaseDelay
        }
        if let bypass = rule.bypassOriginalVolume {
            parameters.bypassOriginalVolume = bypass
        }
        return parameters
    }

    public func setRule(_ rule: AppDuckingRule) {
        if let index = appRules.firstIndex(where: { $0.bundleID == rule.bundleID }) {
            guard appRules[index] != rule else { return }
            appRules[index] = rule
        } else {
            appRules.append(rule)
        }
    }

    public func removeRule(bundleID: String) {
        guard appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        appRules.removeAll { $0.bundleID == bundleID }
    }

    private func persistAppRules() {
        guard let data = try? JSONEncoder().encode(appRules) else { return }
        defaults.set(data, forKey: Key.appRules)
    }

    public var activePreset: DuckingPreset? {
        DuckingPreset.all.first { preset in
            abs(preset.duckLevel - duckLevel) < 0.001
                && abs(preset.attackDuration - attackDuration) < 0.001
                && abs(preset.releaseDuration - releaseDuration) < 0.001
                && abs(preset.releaseDelay - releaseDelay) < 0.001
        }
    }

    public var duckLevelPercent: Int {
        Int((duckLevel * 100).rounded())
    }

    public func apply(_ preset: DuckingPreset) {
        isBatchingUpdates = true
        duckLevel = Self.clamp(preset.duckLevel, to: Self.duckLevelRange)
        attackDuration = Self.clamp(preset.attackDuration, to: Self.attackRange)
        releaseDuration = Self.clamp(preset.releaseDuration, to: Self.releaseRange)
        releaseDelay = Self.clamp(preset.releaseDelay, to: Self.releaseDelayRange)
        isBatchingUpdates = false
        notifyChange()
    }

    private func notifyChange() {
        guard !isBatchingUpdates else { return }
        onSettingsChange?()
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
