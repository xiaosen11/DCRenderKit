//
//  ShaderSourceExtractor.swift
//  DCRenderKit
//
//  Text extractor for the Phase-3 compute backend. Given a `.metal`
//  source string, pulls out the two fragments the uber kernel needs
//  to splice in for every participating filter:
//
//    1. The uniform `struct` declaration (pattern-matched).
//    2. The inline body function wrapped by the marker pair
//       `// @dcr:body-begin <name>` / `// @dcr:body-end`.
//
//  Operates purely on in-memory strings — the SDK never reads
//  `.metal` files at runtime. Source text is supplied by
//  `FusionBody.sourceText`, which for built-in filters is baked
//  into the binary via `BundledShaderSources` and for third-party
//  filters is loaded at descriptor-construction time by the
//  consumer.
//
//  Design note: the body marker is a paired line comment, not an
//  attribute, because Metal shaders don't surface custom attributes
//  to reflection. The marker lives on its own line with the function
//  name — greppable, never false-matching a symbol that merely
//  appears in the body.
//

import Foundation

/// Extract body functions and uniform structs from a `.metal`
/// source string using the Phase-3 marker convention.
@available(iOS 18.0, *)
internal enum ShaderSourceExtractor {

    /// Errors surfaced to callers. Every variant carries the
    /// diagnostic `sourceLabel` (typically the original `.metal`
    /// file name, e.g. `"ExposureFilter.metal"`) so error
    /// messages point at the offending shader.
    internal enum ExtractionError: Error, CustomStringConvertible {
        case bodyMarkerNotFound(functionName: String, sourceLabel: String)
        case unmatchedBodyMarkers(sourceLabel: String)
        case uniformStructNotFound(structName: String, sourceLabel: String)
        case uniformStructUnterminated(structName: String, sourceLabel: String)

        var description: String {
            switch self {
            case .bodyMarkerNotFound(let name, let label):
                return "ShaderSourceExtractor: no `// @dcr:body-begin \(name)` marker in \(label)"
            case .unmatchedBodyMarkers(let label):
                return "ShaderSourceExtractor: body-begin marker is not closed by a body-end marker in \(label)"
            case .uniformStructNotFound(let name, let label):
                return "ShaderSourceExtractor: no `struct \(name)` declaration in \(label)"
            case .uniformStructUnterminated(let name, let label):
                return "ShaderSourceExtractor: `struct \(name)` in \(label) never hits a matching closing `};`"
            }
        }
    }

    // MARK: - Body function

    /// Return the inline body function wrapped by
    /// `// @dcr:body-begin <functionName>` / `// @dcr:body-end`.
    ///
    /// The markers are matched by **name** — two separate body
    /// functions in the same source (e.g. a future filter with two
    /// body variants) can coexist without interference. The
    /// returned text excludes both marker lines themselves; it
    /// starts at the first line after the begin marker and ends
    /// at the last line before the end marker.
    ///
    /// A source containing a begin marker but no end marker is a
    /// programmer error (the shader is malformed); we surface it
    /// as `.unmatchedBodyMarkers` rather than silently returning
    /// a truncated body.
    ///
    /// - Parameters:
    ///   - functionName: Body symbol to extract.
    ///   - source: Full `.metal` source text.
    ///   - sourceLabel: Diagnostic identifier, e.g.
    ///     `"ExposureFilter.metal"`.
    static func extractBody(
        named functionName: String,
        from source: String,
        sourceLabel: String = "<in-memory>"
    ) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let beginMarker = "@dcr:body-begin"
        let endMarker = "@dcr:body-end"

        var beginIndex: Int?
        for (i, line) in lines.enumerated() {
            if line.contains(beginMarker),
               tokenAfterMarker(line, marker: beginMarker) == functionName {
                beginIndex = i
                break
            }
        }

        guard let start = beginIndex else {
            throw ExtractionError.bodyMarkerNotFound(
                functionName: functionName,
                sourceLabel: sourceLabel
            )
        }

        var endIndex: Int?
        for i in (start + 1)..<lines.count where lines[i].contains(endMarker) {
            endIndex = i
            break
        }

        guard let end = endIndex else {
            throw ExtractionError.unmatchedBodyMarkers(sourceLabel: sourceLabel)
        }

        // Slice between the markers, exclusive of both marker lines.
        let body = lines[(start + 1)..<end].joined(separator: "\n")
        return body
    }

    // MARK: - Uniform struct

    /// Return the full text of `struct <structName> { ... };` by
    /// pattern match + brace-balance scan. Comments and whitespace
    /// inside the struct are preserved verbatim so the emitted
    /// uber-kernel source stays human-readable.
    ///
    /// - Parameters:
    ///   - structName: Metal `struct` name to extract.
    ///   - source: Full `.metal` source text.
    ///   - sourceLabel: Diagnostic identifier, e.g.
    ///     `"ExposureFilter.metal"`.
    static func extractUniformStruct(
        named structName: String,
        from source: String,
        sourceLabel: String = "<in-memory>"
    ) throws -> String {
        // Find `struct <structName>` — optionally followed by
        // whitespace before the opening brace. We accept any
        // trailing characters (brace, newline, etc.) on the same
        // line.
        guard let structRange = source.range(of: "struct \(structName)") else {
            throw ExtractionError.uniformStructNotFound(
                structName: structName,
                sourceLabel: sourceLabel
            )
        }

        // Brace-balance scan starting from the struct keyword until
        // a matching `};` closes it.
        var depth = 0
        var seenOpenBrace = false
        var cursor = structRange.lowerBound
        while cursor < source.endIndex {
            let ch = source[cursor]
            if ch == "{" {
                depth += 1
                seenOpenBrace = true
            } else if ch == "}" {
                depth -= 1
                if seenOpenBrace && depth == 0 {
                    // Require the canonical `};` (Metal / C struct
                    // declaration closer). Skip whitespace between
                    // `}` and `;`.
                    var after = source.index(after: cursor)
                    while after < source.endIndex, source[after].isWhitespace {
                        after = source.index(after: after)
                    }
                    guard after < source.endIndex, source[after] == ";" else {
                        throw ExtractionError.uniformStructUnterminated(
                            structName: structName,
                            sourceLabel: sourceLabel
                        )
                    }
                    let closingSemicolonEnd = source.index(after: after)
                    return String(source[structRange.lowerBound..<closingSemicolonEnd])
                }
            }
            cursor = source.index(after: cursor)
        }

        throw ExtractionError.uniformStructUnterminated(
            structName: structName,
            sourceLabel: sourceLabel
        )
    }

    // MARK: - Private

    /// Parse the whitespace-delimited token following `marker` on
    /// `line`. Returns `nil` if no token appears after the marker.
    /// Used by `extractBody` to match begin markers by function
    /// name rather than by textual proximity.
    private static func tokenAfterMarker(
        _ line: Substring,
        marker: String
    ) -> String? {
        guard let markerEnd = line.range(of: marker)?.upperBound else {
            return nil
        }
        let trailing = line[markerEnd...]
        let trimmed = trailing.drop(while: { $0.isWhitespace })
        let tokenEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let token = String(trimmed[trimmed.startIndex..<tokenEnd])
        return token.isEmpty ? nil : token
    }
}
