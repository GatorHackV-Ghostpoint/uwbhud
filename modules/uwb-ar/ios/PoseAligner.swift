import Foundation
import simd

/// A turn about the vertical axis plus an offset: how one gravity-aligned AR world sits in another.
struct Alignment {
    var angle: Float
    var offset: SIMD3<Float>

    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(c * p.x - s * p.z, p.y, s * p.x + c * p.z) + offset
    }
}

/// Works out where the other phone's ARKit world sits inside ours, so its own (smooth, wall-proof)
/// tracking can be shown in our camera view.
///
/// Both phones run ARKit with `.gravity` alignment, so the two worlds share "up" and differ only by a
/// yaw and an offset: 4 unknowns. Each UWB fix gives one point known in both worlds:
///   - our UWB fix of them (our world) ↔ their streamed position (their world)
///   - their UWB fix of us (their world) ↔ our position (our world)
/// A weighted least-squares fit over a sliding window solves it in closed form. Old pairs fade out,
/// so slow ARKit drift on either phone is absorbed; when UWB drops (behind a wall) no new pairs
/// arrive and the last fit holds.
struct PoseAligner {
    struct Pair {
        var theirs: SIMD3<Float>
        var ours: SIMD3<Float>
        var time: TimeInterval
        var weight: Float
    }

    /// Pairs fade with this time constant (seconds), relative to the newest pair.
    static let memory: TimeInterval = 8
    static let maxPairs = 400
    static let minPairs = 12
    /// The fit is only trusted when their points spread at least this far (m) horizontally, else yaw is a guess.
    static let minSpread: Float = 0.35
    /// Sanity limit on how far single pairs sit from the fit (m). Raw UWB fixes scatter ~0.5 m at a few
    /// meters (mostly elevation), which the fit averages out; a much larger RMS means the pairs disagree.
    static let maxRMS: Float = 1.0
    /// Once aligned, a UWB fix that lands this far (m, horizontally; at least 0.5 m) from where their own
    /// tracking puts them is not used: behind a wall UWB keeps reporting, just off a reflection, and a
    /// steady stream of those would otherwise drag the alignment onto the wrong spot.
    static let gateFraction: Float = 0.2
    /// …unless fixes have disagreed for this long with none agreeing: then the fit itself is what's wrong.
    static let realignAfter: TimeInterval = 15

    private(set) var pairs: [Pair] = []
    private(set) var fit: Alignment?      // latest trustworthy solve
    private(set) var rms: Float = 0
    private var shown: Alignment?         // eases toward `fit` so a re-solve doesn't make the tag jump
    private var shownTime: TimeInterval = 0
    private var rejectedSince: TimeInterval?

    mutating func reset() { self = PoseAligner() }

    /// Adds a pair unless it contradicts a settled fit. `range` is how far the measuring phone was from the
    /// point (the gate widens with it). Pairs that can't stand on their own (camera bearings) pass
    /// `canRealign: false` so a wrong match never forces a re-alignment. Returns whether it was used.
    @discardableResult
    mutating func add(theirs: SIMD3<Float>, ours: SIMD3<Float>, at time: TimeInterval, range: Float,
                      weight: Float = 1, canRealign: Bool = true) -> Bool {
        if let fit {
            let r = fit.apply(theirs) - ours
            if hypot(r.x, r.z) > max(0.5, Self.gateFraction * range) {
                guard canRealign else { return false }
                let since = rejectedSince ?? time
                rejectedSince = since
                guard time - since > Self.realignAfter else { return false }
                reset()
            } else if canRealign {
                rejectedSince = nil
            }
        }
        pairs.append(Pair(theirs: theirs, ours: ours, time: time, weight: weight))
        pairs.removeAll { time - $0.time > 3 * Self.memory }
        if pairs.count > Self.maxPairs { pairs.removeFirst(pairs.count - Self.maxPairs) }
        solve(now: time)
        return true
    }

    /// Their-world point in our world, or nil until the alignment can be trusted.
    mutating func map(_ theirs: SIMD3<Float>, at now: TimeInterval) -> SIMD3<Float>? {
        guard let fit else { return nil }
        if let s = shown, now > shownTime {
            let k = Float(1 - exp(-(now - shownTime) / 0.4))
            var da = fit.angle - s.angle
            da = atan2(sin(da), cos(da))   // shortest way round
            shown = Alignment(angle: s.angle + k * da, offset: s.offset + k * (fit.offset - s.offset))
        } else if shown == nil {
            shown = fit
        }
        shownTime = now
        return shown!.apply(theirs)
    }

    private mutating func solve(now: TimeInterval) {
        guard pairs.count >= Self.minPairs else { return }
        var weights = pairs.map { $0.weight * Float(exp(-(now - $0.time) / Self.memory)) }
        guard var result = Self.solve(pairs, weights) else { return }

        // Second pass without outliers (reflections, a bad UWB direction).
        let first = residuals(result.alignment)
        let firstRMS = weightedRMS(first, weights)
        let limit = max(0.4, 2.5 * firstRMS)
        for i in weights.indices where first[i] > limit { weights[i] = 0 }
        guard weights.filter({ $0 > 0 }).count >= Self.minPairs,
              let second = Self.solve(pairs, weights) else { return }
        result = second

        rms = weightedRMS(residuals(result.alignment), weights)
        if rms <= Self.maxRMS && result.spread >= Self.minSpread {
            fit = result.alignment
        }
    }

    private func residuals(_ a: Alignment) -> [Float] {
        pairs.map { simd_distance(a.apply($0.theirs), $0.ours) }
    }

    private func weightedRMS(_ r: [Float], _ w: [Float]) -> Float {
        let total = w.reduce(0, +)
        guard total > 0 else { return .infinity }
        return sqrt(zip(r, w).reduce(0) { $0 + $1.1 * $1.0 * $1.0 } / total)
    }

    /// Weighted 2D Procrustes on the horizontal plane; the vertical offset is the mean difference.
    private static func solve(_ pairs: [Pair], _ w: [Float]) -> (alignment: Alignment, spread: Float)? {
        let total = w.reduce(0, +)
        guard total > 1e-3 else { return nil }
        var cb = SIMD3<Float>.zero, ca = SIMD3<Float>.zero
        for (p, wi) in zip(pairs, w) {
            cb += wi * p.theirs
            ca += wi * p.ours
        }
        cb /= total
        ca /= total
        var dot: Float = 0, cross: Float = 0, spread: Float = 0
        for (p, wi) in zip(pairs, w) {
            let b = p.theirs - cb, a = p.ours - ca
            dot += wi * (b.x * a.x + b.z * a.z)
            cross += wi * (b.x * a.z - b.z * a.x)
            spread += wi * (b.x * b.x + b.z * b.z)
        }
        let angle = atan2(cross, dot)
        let offset = ca - Alignment(angle: angle, offset: .zero).apply(cb)
        return (Alignment(angle: angle, offset: offset), sqrt(spread / total))
    }
}
