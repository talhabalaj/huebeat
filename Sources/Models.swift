import Foundation
import SwiftUI

enum MusicPreset: String, CaseIterable, Identifiable {
    case chill
    case party
    case reactive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chill: "Chill"
        case .party: "Party"
        case .reactive: "Reactive"
        }
    }

    var symbol: String {
        switch self {
        case .chill: "moon.stars.fill"
        case .party: "sparkles"
        case .reactive: "waveform"
        }
    }

    // Four bulbs take ~200 ms per sweep one after another, so rates above ~5 Hz just get coalesced.
    var defaults: PresetDefaults {
        switch self {
        case .chill: PresetDefaults(floor: 0.005, gain: 8, maxHz: 2, relative: false)
        case .party: PresetDefaults(floor: 0.01, gain: 12, maxHz: 4, relative: false)
        case .reactive: PresetDefaults(floor: 0.005, gain: 6, maxHz: 5, relative: true)
        }
    }
}

struct PresetDefaults: Hashable {
    let floor: Double
    let gain: Double
    let maxHz: Double
    let relative: Bool
}

enum AnimationStyle: String, CaseIterable, Identifiable {
    case jump
    case smooth
    case chill
    case strobe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jump: "Jump"
        case .smooth: "Smooth"
        case .chill: "Chill"
        case .strobe: "Strobe"
        }
    }

    var symbol: String {
        switch self {
        case .jump: "bolt.fill"
        case .smooth: "water.waves"
        case .chill: "leaf.fill"
        case .strobe: "rays"
        }
    }

    /// Fade the bulbs run on their own between frames, in tenths of a second. Beats always snap.
    var bulbTransition: Int {
        switch self {
        case .jump, .strobe: 0
        case .smooth: 3
        case .chill: 8
        }
    }
}

struct ColorUpdate: Sendable, Equatable {
    let h: Int
    let s: Int
    let v: Int
    let beat: Bool

    var color: Color {
        Color(hue: Double(h) / 360, saturation: Double(s) / 1000, brightness: Double(v) / 1000)
    }
}

struct AppConfig: Sendable, Hashable {
    // Every surface that changes the preset (window, menu bar) gets the matching tuning.
    var preset: MusicPreset = .party {
        didSet { if preset != oldValue { applyPresetDefaults() } }
    }
    var animationStyle: AnimationStyle = .jump
    var dryRun = false
    var pulseBrightness = true
    var maxHz = 4.0
    var floor = 0.01
    var gain = 12.0
    var beatThreshold = 1.6
    var beatCooldownMs = 180
    var bassLow = 20.0
    var bassHigh = 180.0
    var sampleRate = 48_000

    var relative: Bool {
        preset.defaults.relative
    }

    mutating func applyPresetDefaults() {
        let values = preset.defaults
        floor = values.floor
        gain = values.gain
        maxHz = values.maxHz
    }
}

enum HuebeatError: LocalizedError {
    case audio(String)
    case bridge(String)

    var errorDescription: String? {
        switch self {
        case .audio(let message), .bridge(let message): message
        }
    }
}
