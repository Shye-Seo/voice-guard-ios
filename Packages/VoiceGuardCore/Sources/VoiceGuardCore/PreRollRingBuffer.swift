import Foundation

/// 격양 감지 직전 N초의 오디오 샘플을 손실 없이 보존하는 thread-safe 링버퍼
public final class PreRollRingBuffer {
    private var storage: [Float]
    private var writeIndex: Int = 0
    private var isFilled: Bool = false
    private let lock = NSLock()

    public let capacity: Int

    public init(capacitySamples: Int) {
        self.capacity = max(1, capacitySamples)
        self.storage = Array(repeating: 0.0, count: self.capacity)
    }

    public convenience init(seconds: Double, sampleRate: Double) {
        let count = Int(max(1.0, seconds * sampleRate))
        self.init(capacitySamples: count)
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            storage[writeIndex] = sample
            writeIndex += 1
            if writeIndex >= capacity {
                writeIndex = 0
                isFilled = true
            }
        }
    }

    /// 시간 순서대로 직전 오디오 샘플을 꺼내고 버퍼를 비웁니다.
    public func drainOrderedSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let result: [Float]
        if isFilled {
            let tail = Array(storage[writeIndex..<capacity])
            let head = Array(storage[0..<writeIndex])
            result = tail + head
        } else {
            result = Array(storage[0..<writeIndex])
        }

        writeIndex = 0
        isFilled = false
        return result
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        isFilled = false
    }
}
