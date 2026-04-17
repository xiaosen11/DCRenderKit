//
//  EditParameters.swift
//  DCRDemo
//
//  24 editable parameters plus the LUT preset selection. Shared between
//  the camera-preview page and the photo-edit page; the same chain of
//  filters responds to either context.
//

import Foundation
import Observation

/// LUT preset identifier. Matches the filename (without extension) of
/// a `.cube` file bundled under `Resources/LUTs/`.
///
/// `.none` means "no LUT step in the chain".
enum LUTPreset: String, CaseIterable, Identifiable, Sendable {
    case none = ""
    case jade = "jade"
    case frost = "frost"
    case honey = "honey"
    case amber = "amber"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:  return "无"
        case .jade:  return "JADE"
        case .frost: return "FROST"
        case .honey: return "HONEY"
        case .amber: return "AMBER"
        }
    }
}

/// The 24 slider values + LUT preset drive the entire filter chain.
///
/// Units follow DigiCam's test page: sliders are `-100 ... 100` or
/// `0 ... 100` and are internally remapped before being passed to the
/// SDK's filter structs (which mostly take `-1 ... 1` or Kelvin etc.).
@Observable
@MainActor
final class EditParameters {

    // MARK: - Adjustment (12)

    var exposure: Float = 0       // -100 ... 100
    var contrast: Float = 0       // -100 ... 100
    var highlights: Float = 0     // -100 ... 100
    var shadows: Float = 0        // -100 ... 100
    var whites: Float = 0         // -100 ... 100
    var blacks: Float = 0         // -100 ... 100
    var temperature: Float = 0    // -100 ... 100 (remapped to 4400 ... 6800 K)
    var tint: Float = 0           // -100 ... 100 (remapped to -120 ... +120)
    var vibrance: Float = 0       // -100 ... 100
    var saturation: Float = 0     // -100 ... 100
    var clarity: Float = 0        // -100 ... 100
    var sharpening: Float = 0     //  0 ... 100

    // MARK: - Effects (12)

    var filmGrain: Float = 0          //  0 ... 100 (density)
    var filmGrainColor: Float = 50    //  0 ... 100 (chromaticity)

    var ccdStrength: Float = 0              //  0 ... 100
    var ccdDigitalNoise: Float = 50         //  0 ... 100
    var ccdChromaticAberration: Float = 50  //  0 ... 100
    var ccdSharpening: Float = 55           //  0 ... 100
    var ccdSaturation: Float = 100          //  0 ... 100

    var softGlowStrength: Float = 0      //  0 ... 100
    var softGlowThreshold: Float = 0     //  0 ... 100
    var softGlowBloomRadius: Float = 25  //  0 ... 100

    var portraitBlurStrength: Float = 0  //  0 ... 100

    var lutIntensity: Float = 100        //  0 ... 100
    var lutPreset: LUTPreset = .none

    /// A single hashable value that changes whenever *any* slider or
    /// the LUT preset changes. Reading this from a SwiftUI `body`
    /// registers `@Observable` observation for the full parameter set
    /// in one line — essential for paused `MTKView` previews whose
    /// redraw is gated on body re-evaluation rather than continuous
    /// display-link ticks.
    var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(exposure); hasher.combine(contrast)
        hasher.combine(highlights); hasher.combine(shadows)
        hasher.combine(whites); hasher.combine(blacks)
        hasher.combine(temperature); hasher.combine(tint)
        hasher.combine(vibrance); hasher.combine(saturation)
        hasher.combine(clarity); hasher.combine(sharpening)
        hasher.combine(filmGrain); hasher.combine(filmGrainColor)
        hasher.combine(ccdStrength); hasher.combine(ccdDigitalNoise)
        hasher.combine(ccdChromaticAberration); hasher.combine(ccdSharpening)
        hasher.combine(ccdSaturation)
        hasher.combine(softGlowStrength); hasher.combine(softGlowThreshold)
        hasher.combine(softGlowBloomRadius)
        hasher.combine(portraitBlurStrength)
        hasher.combine(lutIntensity); hasher.combine(lutPreset)
        return hasher.finalize()
    }

    /// Reset every parameter to its DigiCam default.
    func reset() {
        exposure = 0; contrast = 0; highlights = 0; shadows = 0
        whites = 0; blacks = 0; temperature = 0; tint = 0
        vibrance = 0; saturation = 0; clarity = 0; sharpening = 0
        filmGrain = 0; filmGrainColor = 50
        ccdStrength = 0; ccdDigitalNoise = 50; ccdChromaticAberration = 50
        ccdSharpening = 55; ccdSaturation = 100
        softGlowStrength = 0; softGlowThreshold = 0; softGlowBloomRadius = 25
        portraitBlurStrength = 0
        lutIntensity = 100; lutPreset = .none
    }

    // MARK: - Parameter definitions for UI rendering

    struct Definition: Identifiable {
        let id: String
        let label: String
        let min: Float
        let max: Float
        let defaultValue: Float
        let keyPath: ReferenceWritableKeyPath<EditParameters, Float>
    }

    /// Ordered list of slider definitions. Matches DigiCam's effect test
    /// page row-for-row so test feedback remains apples-to-apples.
    static let definitions: [Definition] = [
        // Adjustment
        .init(id: "exposure", label: "曝光 Exposure", min: -100, max: 100, defaultValue: 0, keyPath: \.exposure),
        .init(id: "contrast", label: "对比度 Contrast", min: -100, max: 100, defaultValue: 0, keyPath: \.contrast),
        .init(id: "highlights", label: "高光 Highlights", min: -100, max: 100, defaultValue: 0, keyPath: \.highlights),
        .init(id: "shadows", label: "阴影 Shadows", min: -100, max: 100, defaultValue: 0, keyPath: \.shadows),
        .init(id: "whites", label: "白色 Whites", min: -100, max: 100, defaultValue: 0, keyPath: \.whites),
        .init(id: "blacks", label: "黑色 Blacks", min: -100, max: 100, defaultValue: 0, keyPath: \.blacks),
        .init(id: "temperature", label: "色温 Temperature", min: -100, max: 100, defaultValue: 0, keyPath: \.temperature),
        .init(id: "tint", label: "色调 Tint", min: -100, max: 100, defaultValue: 0, keyPath: \.tint),
        .init(id: "vibrance", label: "自然饱和 Vibrance", min: -100, max: 100, defaultValue: 0, keyPath: \.vibrance),
        .init(id: "saturation", label: "饱和度 Saturation", min: -100, max: 100, defaultValue: 0, keyPath: \.saturation),
        .init(id: "clarity", label: "清晰度 Clarity", min: -100, max: 100, defaultValue: 0, keyPath: \.clarity),
        .init(id: "sharpening", label: "锐化 Sharpening", min: 0, max: 100, defaultValue: 0, keyPath: \.sharpening),

        // Effects
        .init(id: "filmGrain", label: "胶片颗粒 强度", min: 0, max: 100, defaultValue: 0, keyPath: \.filmGrain),
        .init(id: "filmGrainColor", label: "胶片颗粒 色彩", min: 0, max: 100, defaultValue: 50, keyPath: \.filmGrainColor),
        .init(id: "ccdStrength", label: "CCD 强度", min: 0, max: 100, defaultValue: 0, keyPath: \.ccdStrength),
        .init(id: "ccdDigitalNoise", label: "CCD 噪点", min: 0, max: 100, defaultValue: 50, keyPath: \.ccdDigitalNoise),
        .init(id: "ccdChromaticAberration", label: "CCD 色差", min: 0, max: 100, defaultValue: 50, keyPath: \.ccdChromaticAberration),
        .init(id: "ccdSharpening", label: "CCD 锐化", min: 0, max: 100, defaultValue: 55, keyPath: \.ccdSharpening),
        .init(id: "ccdSaturation", label: "CCD 饱和度", min: 0, max: 100, defaultValue: 100, keyPath: \.ccdSaturation),
        .init(id: "softGlowStrength", label: "柔光 强度", min: 0, max: 100, defaultValue: 0, keyPath: \.softGlowStrength),
        .init(id: "softGlowThreshold", label: "柔光 阈值", min: 0, max: 100, defaultValue: 0, keyPath: \.softGlowThreshold),
        .init(id: "softGlowBloomRadius", label: "柔光 半径", min: 0, max: 100, defaultValue: 25, keyPath: \.softGlowBloomRadius),
        .init(id: "portraitBlurStrength", label: "人像虚化 Portrait Blur", min: 0, max: 100, defaultValue: 0, keyPath: \.portraitBlurStrength),
        .init(id: "lutIntensity", label: "LUT 强度", min: 0, max: 100, defaultValue: 100, keyPath: \.lutIntensity),
    ]
}
