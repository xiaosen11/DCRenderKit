#!/bin/bash
set -euo pipefail

OUT="$1"
declare -a SPECS=(
    "exposureFilter|Sources/DCRenderKit/Shaders/Adjustment/Exposure/ExposureFilter.metal"
    "contrastFilter|Sources/DCRenderKit/Shaders/Adjustment/Contrast/ContrastFilter.metal"
    "blacksFilter|Sources/DCRenderKit/Shaders/Adjustment/Blacks/BlacksFilter.metal"
    "whitesFilter|Sources/DCRenderKit/Shaders/Adjustment/Whites/WhitesFilter.metal"
    "sharpenFilter|Sources/DCRenderKit/Shaders/Adjustment/Sharpen/SharpenFilter.metal"
    "saturationFilter|Sources/DCRenderKit/Shaders/ColorGrading/Saturation/SaturationFilter.metal"
    "vibranceFilter|Sources/DCRenderKit/Shaders/ColorGrading/Vibrance/VibranceFilter.metal"
    "whiteBalanceFilter|Sources/DCRenderKit/Shaders/ColorGrading/WhiteBalance/WhiteBalanceFilter.metal"
    "ccdFilter|Sources/DCRenderKit/Shaders/Effects/CCD/CCDFilter.metal"
    "filmGrainFilter|Sources/DCRenderKit/Shaders/Effects/FilmGrain/FilmGrainFilter.metal"
    "lut3DFilter|Sources/DCRenderKit/Shaders/LUT/LUT3D/LUT3DFilter.metal"
    "normalBlendFilter|Sources/DCRenderKit/Shaders/Blend/Normal/NormalBlendFilter.metal"
)

{
cat <<'HEADER'
//
//  BundledShaderSources.swift
//  DCRenderKit
//
//  Verbatim source text of every built-in pixel-local / neighbour-
//  read filter's `.metal` file. The compiler's runtime codegen
//  reads these strings directly instead of hitting Bundle.module —
//  Xcode's SPM integration for iOS does not copy `.metal` sources
//  into the app's resource bundle (it only compiles them into the
//  default metallib), so a Bundle-based runtime read worked under
//  `swift test` on macOS but crashed at launch on an iPhone. Baking
//  the sources into Swift constants makes the compiler path work
//  identically on every platform and removes runtime file-I/O from
//  the hot path entirely.
//
//  Regenerating: run `Scripts/generate-bundled-shaders.sh`. Edit a
//  `.metal` file under `Sources/DCRenderKit/Shaders/` → re-run the
//  script → commit the regenerated file alongside the `.metal`
//  change. Check script for list of bundled filters; extend if new
//  fusion-body filter is added.
//

import Foundation

/// Canonical source text of every SDK-built-in filter's `.metal`
/// file. Consumed by `ShaderSourceExtractor` via
/// `FusionBody.sourceText`.
@available(iOS 18.0, *)
internal enum BundledShaderSources {

HEADER

first=1
for spec in "${SPECS[@]}"; do
    IFS='|' read -r NAME METAL_FILE <<< "$spec"
    if [ "$first" = "0" ]; then
        echo ""
    fi
    first=0
    BASE="$(/usr/bin/basename "$METAL_FILE" .metal)"
    echo "    /// Verbatim text of \`${BASE}.metal\`."
    echo "    static let ${NAME}: String = #\"\"\""
    /bin/cat "$METAL_FILE"
    echo "\"\"\"#"
done

cat <<'FOOTER'
}
FOOTER
} > "$OUT"
