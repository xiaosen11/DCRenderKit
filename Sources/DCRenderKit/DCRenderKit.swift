// DCRenderKit
//
// A commercial-grade Metal-based image processing SDK for iOS and macOS.
//
// Public API surface — everything the consumer ever imports. See
// `docs/metal-engine-plan.md` for the architecture, and the per-type
// SwiftDoc for usage.

import Foundation

/// SDK metadata.
///
/// Consumers don't normally touch this; `Pipeline` is the working
/// entry point. Included here to standardize version reporting in bug
/// reports and telemetry surfaces.
public enum DCRenderKit {

    /// Current SDK version following SemVer 2.0.
    public static let version = "0.1.0-dev"

    /// Build channel. "dev" during Phase 1–2, "release" once the SDK
    /// is tagged for consumer adoption.
    public static let channel = "dev"
}
