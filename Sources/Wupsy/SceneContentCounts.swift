struct SceneContentCounts: Equatable {
    var visibleLayers = 0
    var effectiveEffects = 0
}

extension WSSStaticResources {
    // Count enabled scene entries, independent of temporary weather or pointer activity.
    var performanceContentCounts: SceneContentCounts {
        var counts = SceneContentCounts()
        for (index, node) in scene.layers.enumerated() where node.visible {
            counts.visibleLayers += 1
            switch node {
            case .image(let layer):
                guard layer.opacity > 0, let plan = effectPlans[index] else { continue }
                for effect in plan.effects {
                    switch effect {
                    case .clouds(let value) where value.intensity == 0: continue
                    case .ripple(let value) where value.amplitude == 0: continue
                    default: counts.effectiveEffects += 1
                    }
                }
            case .rain(let layer):
                if rain?.layers[index]?.buffer != nil, layer.rain.opacity.max > 0 {
                    counts.effectiveEffects += 1
                }
            case .trail(let layer):
                if layer.configuration.opacity > 0 { counts.effectiveEffects += 1 }
            case .storm(let layer):
                if layer.isAnimated { counts.effectiveEffects += 1 }
            case .starfield(let layer):
                let stars = layer.starfield
                let meteors =
                    stars.shootingStars.isEffective
                    && max(stars.red, max(stars.green, stars.blue)) > 0
                if stars.isEffective || stars.milkyWay.isEffective || meteors {
                    counts.effectiveEffects += 1
                }
            case .fog(let layer):
                if hasEffectiveFog(layer) { counts.effectiveEffects += 1 }
            case .musicNotes(let layer):
                let symbols =
                    layer.singleSymbol.map { $0.opacity > 0 }
                    ?? (layer.notes.count > 0 && layer.notes.opacity > 0)
                let staff =
                    layer.drawsStaff && musicNotesStaffs[index] != nil
                    && (layer.staff?.opacity ?? 0) > 0
                if symbols || staff { counts.effectiveEffects += 1 }
            }
        }
        return counts
    }
}
