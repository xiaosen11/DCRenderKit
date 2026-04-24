//
//  PassGraphVisualizer.swift
//  DCRenderKit
//
//  Produces human-readable (text or Mermaid) representations of a pass
//  graph for debugging and documentation.
//

import Foundation
import Metal

/// Formats a `[Pass]` graph as a readable textual diagram.
///
/// Used by `Pipeline.debugPrintPassGraph()` during development to make
/// multi-pass filter pipelines easier to reason about. Also suitable for
/// including in bug reports and filter documentation.
///
/// Two output formats:
/// - `.text` — plain ASCII tree suitable for log output.
/// - `.mermaid` — Mermaid flowchart syntax suitable for Markdown docs or
///   GitHub issue bodies.
@available(iOS 18.0, *)
public enum PassGraphVisualizer {

    public enum Format: String, Sendable {
        case text
        case mermaid
    }

    /// Render the pass graph as a string.
    public static func render(
        passes: [Pass],
        sourceInfo: TextureInfo? = nil,
        format: Format = .text
    ) -> String {
        switch format {
        case .text:
            return renderText(passes: passes, sourceInfo: sourceInfo)
        case .mermaid:
            return renderMermaid(passes: passes, sourceInfo: sourceInfo)
        }
    }

    // MARK: - Text format

    private static func renderText(
        passes: [Pass],
        sourceInfo: TextureInfo?
    ) -> String {
        if passes.isEmpty {
            return "(empty pass graph — identity)"
        }

        var lines: [String] = []
        lines.append("Pass graph (\(passes.count) passes):")

        // Resolve sizes for diagnostic output.
        var resolvedInfos: [String: TextureInfo] = [:]
        for pass in passes {
            if let info = sourceInfo,
               let resolved = pass.output.resolve(source: info, resolvedPeers: resolvedInfos) {
                resolvedInfos[pass.name] = resolved
            }
        }

        for (i, pass) in passes.enumerated() {
            let prefix = pass.isFinal ? "★" : " "
            let inputsDesc = pass.inputs.map { input -> String in
                switch input {
                case .source: return "source"
                case .named(let n): return n
                case .additional(let i): return "additional[\(i)]"
                }
            }.joined(separator: ", ")

            var line = "  \(prefix) [\(i)] \(pass.name): \(pass.modifier)"
            line += " <- [\(inputsDesc)]"
            if let outputInfo = resolvedInfos[pass.name] {
                line += " → \(outputInfo.width)×\(outputInfo.height)"
            }
            if pass.uniforms.byteCount > 0 {
                line += " (uniforms: \(pass.uniforms.byteCount)B)"
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Mermaid format

    private static func renderMermaid(
        passes: [Pass],
        sourceInfo: TextureInfo?
    ) -> String {
        if passes.isEmpty {
            return "graph LR\n    source[source] --> output[output]"
        }

        var lines: [String] = ["graph LR"]

        // Source node (if we have dimensions, include them in the label).
        if let info = sourceInfo {
            lines.append("    source[\"source<br/>\(info.width)×\(info.height)\"]")
        } else {
            lines.append("    source[source]")
        }

        // Resolve sizes.
        var resolvedInfos: [String: TextureInfo] = [:]
        for pass in passes {
            if let info = sourceInfo,
               let resolved = pass.output.resolve(source: info, resolvedPeers: resolvedInfos) {
                resolvedInfos[pass.name] = resolved
            }
        }

        // Nodes
        for pass in passes {
            let nodeId = mermaidId(pass.name)
            var label = pass.name
            if let outputInfo = resolvedInfos[pass.name] {
                label += "<br/>\(outputInfo.width)×\(outputInfo.height)"
            }
            let style = pass.isFinal ? ":::final" : ""
            lines.append("    \(nodeId)[\"\(label)\"]\(style)")
        }

        // Edges
        for pass in passes {
            for input in pass.inputs {
                let from: String
                switch input {
                case .source: from = "source"
                case .named(let n): from = mermaidId(n)
                case .additional(let i): from = "additional_\(i)"
                }
                lines.append("    \(from) --> \(mermaidId(pass.name))")
            }
        }

        // Final node styling
        lines.append("    classDef final fill:#b7e1cd,stroke:#34a853,stroke-width:2px")

        return lines.joined(separator: "\n")
    }

    private static func mermaidId(_ name: String) -> String {
        // Mermaid node IDs must not contain special chars. Replace
        // non-alphanumeric chars with underscores.
        var result = ""
        for char in name {
            if char.isLetter || char.isNumber {
                result.append(char)
            } else {
                result.append("_")
            }
        }
        // Prefix with a letter to guarantee it starts with a valid char.
        return "p_" + result
    }
}
