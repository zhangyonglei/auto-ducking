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
