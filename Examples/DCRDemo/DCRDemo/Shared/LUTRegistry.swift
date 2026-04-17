//
//  LUTRegistry.swift
//  DCRDemo
//
//  Loads `.cube` LUT files bundled under Resources/LUTs/ into
//  LUT3DFilter instances, caching parsed data so repeated filter
//  builds don't re-parse the cube file on every slider tweak.
//

import Foundation
import Metal
import DCRenderKit

/// Resolves a `LUTPreset` into a ready-to-use `LUT3DFilter`.
///
/// Thread-safe: parsed cube data is cached in a serial-access `lock`ed
/// dictionary, so concurrent camera frames asking for the same preset
/// share the same underlying 3D Metal texture.
@MainActor
final class LUTRegistry {

    static let shared = LUTRegistry()

    private struct CachedEntry {
        let filter: LUT3DFilter
    }

    private var cache: [LUTPreset: CachedEntry] = [:]

    private init() {}

    /// Returns a `LUT3DFilter` for the given preset with the given
    /// intensity. Returns `nil` for `.none` (caller should skip adding a
    /// LUT step to the chain).
    func filter(for preset: LUTPreset, intensity: Float) -> LUT3DFilter? {
        guard preset != .none else { return nil }

        if var cached = cache[preset]?.filter {
            cached.intensity = intensity
            return cached
        }

        guard let url = Bundle.main.url(
            forResource: preset.rawValue,
            withExtension: "cube",
            subdirectory: "LUTs"
        ) ?? Bundle.main.url(
            forResource: preset.rawValue,
            withExtension: "cube"
        ) else {
            return nil
        }

        do {
            let filter = try LUT3DFilter(cubeURL: url, intensity: intensity)
            cache[preset] = CachedEntry(filter: filter)
            return filter
        } catch {
            return nil
        }
    }
}
