import Accelerate
import Foundation

/// Turns raw system audio into an HSV color per frame: bass-band beat detection plus an energy envelope.
final class AudioColorMapper {
    private let partyHues: [Double] = [0, 30, 60, 120, 180, 210, 270, 300]
    private let sampleRate: Double
    private let floor: Double
    private let gain: Double
    private let relative: Bool
    private let beatThreshold: Double
    private let beatCooldown: TimeInterval
    private let bassLow: Double
    private let bassHigh: Double
    private let animation: AnimationStyle

    private var hueIndex = 0
    private var currentHue: Double = 0
    private var energyAverage = 0.1
    private var bassHistory: [Double] = []
    private var lowpassState = (0.0, 0.0)
    private var beatBoost = 0.0
    private var lastBeatTime = Date.distantPast
    private var lastDriftTime = Date()
    private var brightnessEnvelope: EnvelopeFollower

    init(config: AppConfig) {
        sampleRate = Double(config.sampleRate)
        floor = config.floor
        gain = config.gain
        relative = config.relative
        beatThreshold = config.beatThreshold
        beatCooldown = Double(config.beatCooldownMs) / 1000
        bassLow = config.bassLow
        bassHigh = config.bassHigh
        animation = config.animationStyle
        currentHue = partyHues[0]

        switch config.animationStyle {
        case .jump:
            brightnessEnvelope = EnvelopeFollower(attack: 0.4, decay: 0.08)
        case .smooth:
            brightnessEnvelope = EnvelopeFollower(attack: 0.15, decay: 0.04)
        case .chill:
            brightnessEnvelope = EnvelopeFollower(attack: 0.08, decay: 0.02)
        case .strobe:
            brightnessEnvelope = EnvelopeFollower(attack: 0.6, decay: 0.15)
        }
    }

    func map(samples: [Float], channels: Int) -> ColorUpdate {
        guard channels > 0, samples.count >= channels else {
            return ColorUpdate(h: Int(currentHue), s: 0, v: 0, beat: false)
        }

        let frameCount = samples.count / channels
        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            mono = Array(samples.prefix(frameCount))
        } else {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                mono[frame] = sum / Float(channels)
            }
        }

        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(frameCount))

        let rawRms = Double(rms)
        let energy: Double
        if relative {
            energyAverage = energyAverage * 0.97 + rawRms * 0.03
            energy = clamp((rawRms / (energyAverage + 0.001) - 0.6) * 2.5, 0, 1)
        } else {
            energy = clamp((rawRms - floor) * gain, 0, 1)
        }


        // Beat = bass energy jumping well above its recent (~1 s) average, the classic onset test.
        let bassEnergy = bassRMS(samples: mono)
        let history = bassHistory
        bassHistory.append(bassEnergy)
        if bassHistory.count > historyLength { bassHistory.removeFirst() }
        let mean = history.isEmpty ? bassEnergy : history.reduce(0, +) / Double(history.count)
        let variance = history.isEmpty ? 0 : history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count)

        let now = Date()
        let isSilent = energy < 0.01 && bassEnergy < 0.002
        let isBeat = !isSilent
            && history.count >= historyLength / 2
            && bassEnergy > 0.002
            && bassEnergy > mean * beatThreshold * 0.85
            && bassEnergy > mean + sqrt(variance) * 1.2
            && now.timeIntervalSince(lastBeatTime) >= beatCooldown

        let profile = animationProfile(animation)
        if isBeat && profile.jumpOnBeat {
            hueIndex = (hueIndex + 1) % partyHues.count
            currentHue = partyHues[hueIndex]
            beatBoost = 1
            lastBeatTime = now
            brightnessEnvelope.level = 1
        } else if !isSilent {
            let elapsed = max(0, now.timeIntervalSince(lastDriftTime))
            let drift = elapsed * (profile.driftBase + energy * profile.driftEnergy)
            currentHue = currentHue.truncatingRemainder(dividingBy: 360) + drift
            if currentHue >= 360 { currentHue -= 360 }
            beatBoost *= profile.beatDecay
        } else {
            beatBoost *= 0.45
            brightnessEnvelope.level *= 0.45
        }
        lastDriftTime = now

        if isBeat && profile.jumpOnBeat {
            return ColorUpdate(h: Int(currentHue), s: 1000, v: 1000, beat: true)
        }

        let saturation = Int(clamp(700 + energy * 220 + beatBoost * 120, 0, 1000))
        let rawValue = clamp(220 + energy * 520 + beatBoost * 420, 0, 1000)
        let value = Int(brightnessEnvelope.process(rawValue / 1000) * 1000)
        return ColorUpdate(h: Int(currentHue), s: saturation, v: value, beat: isBeat)
    }

    private var historyLength: Int { 45 }

    /// RMS of the signal below ~150 Hz (two cascaded one-pole low-passes; state carries across buffers).
    private func bassRMS(samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let alpha = 1 - exp(-2 * Double.pi * max(bassHigh, 60) / sampleRate)
        var (a, b) = lowpassState
        var sum = 0.0
        for sample in samples {
            a += alpha * (Double(sample) - a)
            b += alpha * (a - b)
            sum += b * b
        }
        lowpassState = (a, b)
        return sqrt(sum / Double(samples.count))
    }

    private func animationProfile(_ style: AnimationStyle) -> (driftBase: Double, driftEnergy: Double, jumpOnBeat: Bool, beatDecay: Double) {
        switch style {
        case .jump:
            return (8, 16, true, 0.82)
        case .smooth:
            return (4, 8, false, 0.70)
        case .chill:
            return (2, 4, false, 0.70)
        case .strobe:
            return (12, 24, true, 0.70)
        }
    }
}

final class EnvelopeFollower {
    let attack: Double
    let decay: Double
    var level = 0.0

    init(attack: Double, decay: Double) {
        self.attack = attack
        self.decay = decay
    }

    func process(_ input: Double) -> Double {
        if input > level {
            level = attack * input + (1 - attack) * level
        } else {
            level = decay * input + (1 - decay) * level
        }
        return level
    }
}

func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}
