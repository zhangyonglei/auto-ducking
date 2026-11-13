import Foundation

public final class SystemDuckingScheduler: DuckingScheduling {
    public init() {}

    public func after(_ delay: TimeInterval, _ action: @escaping () -> Void) -> DuckingCancellable {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
            action()
        }
        timer.tolerance = min(0.05, max(0.005, delay * 0.05))
        RunLoop.main.add(timer, forMode: .common)
        return TimerToken(timer: timer)
    }

    public func ramp(
        from start: Float,
        to target: Float,
        duration: TimeInterval,
        update: @escaping (Float) -> Void,
        completion: @escaping () -> Void
    ) -> DuckingCancellable {
        let safeDuration = max(0.02, duration)
        let steps = max(2, Int((safeDuration * 60).rounded()))
        let interval = safeDuration / Double(steps)
        var step = 0

        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            step += 1
            let progress = min(1, Float(step) / Float(steps))
            let eased = progress * progress * (3 - 2 * progress)
            update(start + (target - start) * eased)
            if step >= steps {
                timer.invalidate()
                completion()
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        return TimerToken(timer: timer)
    }
}

private final class TimerToken: DuckingCancellable {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
