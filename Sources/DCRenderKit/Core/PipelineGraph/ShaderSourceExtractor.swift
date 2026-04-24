//
//  ShaderSourceExtractor.swift
//  DCRenderKit
//
//  Runtime text extractor for the Phase-3 compute backend. Reads a
//  `.metal` source file and pulls out the two fragments the uber
//  kernel needs to splice in for every participating filter:
//
//    1. The uniform `struct` declaration (pattern-matched).
//    2. The inline body function wrapped by the marker pair
//       `// @dcr:body-begin <name>` / `// @dcr:body-end`.
//
//  Keeping this as a Swift-side tool (rather than a Metal pre-
//  processor) means we can generate uber kernels at runtime without
//  a toolchain pre-pass; the cost is one file read per filter on
//  first use, cached by the compute backend.
//
//  Design note: the body marker is a paired line comment, not an
//  attribute, because Metal shaders don't surface custom attributes
//  to reflection. The marker lives on its own line with the function
//  name — greppable, never false-matching a symbol that merely
//  appears in the body.
//

import Foundation

/// Extract body functions and uniform structs from `.metal`
/// sources using the Phase-3 marker convention. Every call reads
/// the file from disk; callers that invoke repeatedly should
/// cache the returned text. The compute backend does that
/// caching, so production code never re-reads the same file.
@available(iOS 18.0, *)
internal enum ShaderSourceExtractor {

    /// Errors surfaced to callers. Each variant is recoverable at
    /// the backend layer — the uber-kernel builder falls back to
    /// compiling per-filter kernels instead.
    internal enum ExtractionError: Error, CustomStringConvertible {
        case fileUnreadable(URL, underlying: Error)
        case bodyMarkerNotFound(functionName: String, file: URL)
        case unmatchedBodyMarkers(file: URL)
        case uniformStructNotFound(structName: String, file: URL)
        case uniformStructUnterminated(structName: String, file: URL)

        var description: String {
            switch self {
            case .fileUnreadable(let url, let e):
                return "ShaderSourceExtractor: cannot read \(url.lastPathComponent) — \(e)"
            case .bodyMarkerNotFound(let name, let url):
                return "ShaderSourceExtractor: no `// @dcr:body-begin \(name)` marker in \(url.lastPathComponent)"
            case .unmatchedBodyMarkers(let url):
                return "ShaderSourceExtractor: body-begin marker is not closed by a body-end marker in \(url.lastPathComponent)"
            case .uniformStructNotFound(let name, let url):
                return "ShaderSourceExtractor: no `struct \(name)` declaration in \(url.lastPathComponent)"
            case .uniformStructUnterminated(let name, let url):
                return "ShaderSourceExtractor: `struct \(name)` in \(url.lastPathComponent) never hits a matching closing `};`"
            }
        }
    }

    // MARK: - Body function

    /// Read `url` and return the inline body function wrapped by
    /// `// @dcr:body-begin <functionName>` / `// @dcr:body-end`.
    ///
    /// The markers are matched by **name** — two separate body
    /// functions in the same file (e.g. a future filter with two
    /// body variants) can coexist without interference. The
    /// returned text excludes both marker lines themselves; it
    /// starts at the first line after the begin marker and ends
    /// at the last line before the end marker.
    ///
    /// A file containing a begin marker but no end marker is a
    /// programmer error (the shader is malformed); we surface it
    /// as `.unmatchedBodyMarkers` rather than silently returning
    /// a truncated body.
    static func extractBody(
        named functionName: String,
        from url: URL
    ) throws -> String {
        let source = try readSource(at: url)
        return try extractBody(named: functionName, from: source, url: url)
    }

    /// Overload that operates on source text directly. Useful in
    /// tests that want to build their fixtures inline, and in the
    /// future when the compute backend caches `.metal` contents.
    static func extractBody(
        named functionName: String,
        from source: String,
        url: URL = URL(fileURLWithPath: "<in-memory>")
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
                file: url
            )
        }

        var endIndex: Int?
        for i in (start + 1)..<lines.count where lines[i].contains(endMarker) {
            endIndex = i
            break
        }

        guard let end = endIndex else {
            throw ExtractionError.unmatchedBodyMarkers(file: url)
        }

        // Slice between the markers, exclusive of both marker lines.
        let body = lines[(start + 1)..<end].joined(separator: "\n")
        return body
    }

    // MARK: - Uniform struct

    /// Read `url` and return the full text of `struct <structName>
    /// { ... };` by pattern match + brace-balance scan. Comments
    /// and whitespace inside the struct are preserved verbatim so
    /// the emitted uber-kernel source stays human-readable.
    static func extractUniformStruct(
        named structName: String,
        from url: URL
    ) throws -> String {
        let source = try readSource(at: url)
        return try extractUniformStruct(
            named: structName,
            from: source,
            url: url
        )
    }

    /// Source-text overload (see `extractBody` rationale).
    static func extractUniformStruct(
        named structName: String,
        from source: String,
        url: URL = URL(fileURLWithPath: "<in-memory>")
    ) throws -> String {
        // Find `struct <structName>` — optionally followed by
        // whitespace before the opening brace. We accept any
        // trailing characters (brace, newline, etc.) on the same
        // line.
        guard let structRange = source.range(of: "struct \(structName)") else {
            throw ExtractionError.uniformStructNotFound(
                structName: structName,
                file: url
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
                            file: url
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
            file: url
        )
    }

    // MARK: - Private

    /// Read a `.metal` file as UTF-8 text. Wraps any I/O failure
    /// into the extractor's typed error so callers don't have to
    /// switch on `Foundation.CocoaError`.
    private static func readSource(at url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ExtractionError.fileUnreadable(url, underlying: error)
        }
    }

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
