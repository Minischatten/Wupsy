// SplitMix64 recurrence published by Sebastiano Vigna (2015), based on SplitMix
// by Steele, Lea and Flood (2014). New Swift implementation of the documented
// unsigned arithmetic; algorithm/constants are not claimed as Wupsy inventions.
// Mathematical basis, source permission and historical PCG replacement:
// docs/RAIN-RANDOM.md; https://prng.di.unimi.it/splitmix.c
struct WSSRainRandom {
    enum Stream: UInt32, CaseIterable {
        case layout = 0x5241_494E  // RAIN
        case length = 0x4C45_4E47  // LENG
        case profile = 0x4452_4F50  // DROP
    }
    private var state: UInt64

    init(seed: UInt64) { state = seed }
    init(seed: UInt32, stream: Stream) {
        // Disjoint (seed, purpose) inputs; each purpose owns its draw position.
        self.init(seed: (UInt64(seed) << 32) | UInt64(stream.rawValue))
    }
    mutating func next() -> UInt64 {
        // All addition/multiplication is modulo 2^64; shifts of UInt64 are logical.
        state &+= 0x9E37_79B9_7F4A_7C15
        let first = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        let second = (first ^ (first >> 27)) &* 0x94D0_49BB_1331_11EB
        return second ^ (second >> 31)
    }
    mutating func unit() -> Float {
        // Exactly representable 24-bit numerator; no conversion of the full UInt64
        // to Float (which could round an output up to the excluded endpoint 1).
        Float(next() >> 40) / 16_777_216
    }
}
