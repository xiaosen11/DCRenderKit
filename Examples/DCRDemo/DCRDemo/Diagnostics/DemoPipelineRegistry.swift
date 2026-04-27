//
//  DemoPipelineRegistry.swift
//  DCRDemo
//
//  Demo-local registry that tracks every long-lived `Pipeline` the
//  Demo creates so the multi-Pipeline status HUD can iterate them.
//  Lives in the Demo because it's an instrumentation concern, not
//  an SDK responsibility — `Pipeline` itself shouldn't know it's
//  being monitored.
//
//  Owners (camera Coordinator / edit Coordinator / export task)
//  call `register(_:label:)` on init and the registry holds a weak
//  reference; entries auto-clear when their Pipeline deinits.
//

import Foundation
import Observation
import DCRenderKit

/// Demo-only weakly-held registry of active `Pipeline` instances,
/// used by `MultiPipelineStatusView` to display per-Pipeline
/// resource utilisation.
///
/// Thread-safe — `register` / `unregister` may be called from any
/// thread (Coordinator init runs on main; export tasks run on
/// background). `tick()` and `entries` access is also lock-guarded.
@Observable
final class DemoPipelineRegistry: @unchecked Sendable {

    static let shared = DemoPipelineRegistry()

    /// Exposed snapshot for the HUD. Updated on every `tick()` call.
    private(set) var entries: [Snapshot] = []

    private struct Slot {
        let id: Int
        let label: String
        weak var pipeline: Pipeline?
    }

    private let lock = NSLock()
    private var slots: [Slot] = []
    private var nextID = 0

    /// Single live snapshot of one Pipeline's diagnostics + label.
    /// Identifiable via `id` so SwiftUI ForEach can stably diff.
    struct Snapshot: Identifiable, Equatable {
        let id: Int
        let label: String
        let textureBytesCached: Int
        let textureCachedCount: Int
        let uniformSlotsInUse: Int
        let uniformSlotsReserved: Int
        let uberComputePSOCount: Int
        let uberRenderPSOCount: Int
    }

    private init() {}

    /// Register a Pipeline weakly. Call from the owner's `init`.
    /// Returns a token the owner uses to deregister on `deinit`.
    @discardableResult
    func register(_ pipeline: Pipeline, label: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        slots.append(Slot(id: id, label: "\(label)#\(id)", pipeline: pipeline))
        return id
    }

    /// Manually deregister (optional — deinit-released Pipelines
    /// fall out automatically on next `tick()`). Pass the id
    /// returned by `register`.
    func unregister(id: Int) {
        lock.lock()
        defer { lock.unlock() }
        slots.removeAll { $0.id == id }
    }

    /// Refresh `entries` from currently live Pipelines. Drops slots
    /// whose weak reference is now nil. Cheap to call on a SwiftUI
    /// timer or task at 1-2 Hz. Should be called on the main thread
    /// since it updates an `@Observable` property the UI binds to.
    func tick() {
        lock.lock()
        slots.removeAll { $0.pipeline == nil }
        let snapshots: [Snapshot] = slots.compactMap { slot in
            guard let p = slot.pipeline else { return nil }
            let d = p.diagnostics
            return Snapshot(
                id: slot.id,
                label: slot.label,
                textureBytesCached: d.textureBytesCached,
                textureCachedCount: d.textureCachedCount,
                uniformSlotsInUse: d.uniformSlotsInUse,
                uniformSlotsReserved: d.uniformSlotsReserved,
                uberComputePSOCount: d.uberComputePSOCount,
                uberRenderPSOCount: d.uberRenderPSOCount
            )
        }
        lock.unlock()
        entries = snapshots
    }
}
