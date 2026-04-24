//
//  CubeFileParser.swift
//  DCRenderKit
//
//  Standard .cube 3D LUT file parser. Produces tightly-packed RGBA Float32
//  suitable for direct upload into an MTLTexture of type3D.
//

import Foundation

/// Parses the Adobe `.cube` 3D LUT file format. Returns the LUT data as a
/// tightly-packed RGBA32Float byte sequence plus the LUT dimension (the
/// shared side length of the cube — 17, 25, 33, 64 are the common sizes).
///
/// ## Supported headers
///
/// - `LUT_3D_SIZE <n>` (required)
/// - `DOMAIN_MIN r g b` (optional, defaults to `0 0 0`)
/// - `DOMAIN_MAX r g b` (optional, defaults to `1 1 1`)
/// - `TITLE "..."` and `#` comments are ignored
///
/// ## Domain mapping
///
/// Values outside `[DOMAIN_MIN, DOMAIN_MAX]` are clamped into `[0, 1]` after
/// the linear remap. LUTs that depend on domain-extended colour data (e.g.
/// log HDR grading LUTs) are not losslessly preserved — callers expecting
/// HDR should post-process the 3D texture or use a domain-aware sampler.
///
/// 1D LUTs (`LUT_1D_SIZE`) are **not** supported by this parser; the filter
/// pipeline's 3D texture contract requires cube-shaped data.
@available(iOS 18.0, *)
public enum CubeFileParser {

    /// Parse a `.cube` file from disk.
    ///
    /// Returns `nil` if the file cannot be read, the header is malformed,
    /// or the data count doesn't match `dimension^3`.
    public static func parse(url: URL) -> (data: Data, dimension: Int)? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parse(string: contents)
    }

    /// Parse `.cube` contents already loaded as a string.
    public static func parse(string: String) -> (data: Data, dimension: Int)? {
        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = .whitespaces

        var dimension = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]

        // Header block — consumed until the first data row is encountered.
        while !scanner.isAtEnd {
            if scanner.scanString("#") != nil || scanner.scanString("TITLE") != nil {
                _ = scanner.scanUpToCharacters(from: .newlines)
                _ = scanner.scanCharacters(from: .newlines)
                continue
            }
            if scanner.scanString("LUT_3D_SIZE") != nil {
                dimension = scanner.scanInt() ?? 0
                _ = scanner.scanCharacters(from: .newlines)
                continue
            }
            if scanner.scanString("DOMAIN_MIN") != nil {
                if let r = scanner.scanFloat(),
                   let g = scanner.scanFloat(),
                   let b = scanner.scanFloat() {
                    domainMin = [r, g, b]
                }
                _ = scanner.scanCharacters(from: .newlines)
                continue
            }
            if scanner.scanString("DOMAIN_MAX") != nil {
                if let r = scanner.scanFloat(),
                   let g = scanner.scanFloat(),
                   let b = scanner.scanFloat() {
                    domainMax = [r, g, b]
                }
                _ = scanner.scanCharacters(from: .newlines)
                continue
            }
            if scanner.scanString("LUT_") != nil {
                // Unsupported LUT_1D_SIZE or similar — skip the line and
                // let the dimension==0 guard below reject the file.
                _ = scanner.scanUpToCharacters(from: .newlines)
                _ = scanner.scanCharacters(from: .newlines)
                continue
            }
            break  // First non-header token is a data row.
        }

        guard dimension > 0 else { return nil }

        let total = dimension * dimension * dimension
        var rgba: [Float] = []
        rgba.reserveCapacity(total * 4)

        for _ in 0..<total {
            _ = scanner.scanCharacters(from: .newlines)
            guard let r = scanner.scanFloat(),
                  let g = scanner.scanFloat(),
                  let b = scanner.scanFloat() else { break }
            rgba.append(remap(r, min: domainMin[0], max: domainMax[0]))
            rgba.append(remap(g, min: domainMin[1], max: domainMax[1]))
            rgba.append(remap(b, min: domainMin[2], max: domainMax[2]))
            rgba.append(1.0)
        }

        guard rgba.count == total * 4 else { return nil }

        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return (data, dimension)
    }

    // MARK: - Private

    private static func remap(_ value: Float, min: Float, max: Float) -> Float {
        if min == 0, max == 1 {
            return Swift.max(0, Swift.min(1, value))
        }
        let mapped = (value - min) / (max - min)
        return Swift.max(0, Swift.min(1, mapped))
    }
}
