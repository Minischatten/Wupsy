import ImageIO
import MetalKit

// Independent static image backend. No compatibility pipelines, effect slots,
// simulation or external engine-resource provider are constructed here.
enum WSSRenderProjection { case cover, fullCanvas }

final class WSSStaticResources: @unchecked Sendable {
    private let family: NSObject
    let scene: WSSScene
    let device: MTLDevice
    let queue: MTLCommandQueue
    struct Image {
        let texture: MTLTexture
        let sampler: MTLSamplerState
        let uvScale: SIMD2<Float>
    }
    let images: [WSSAssetID: Image]
    let trail: WSSTrailRenderer?
    let rain: WSSRainResources?
    let ripple: WSSRippleResources?
    let flow: WSSFlowResources?
    let vectorFields: WSSVectorFieldResources?
    private(set) var effectPlans: [Int: WSSImageEffectPlan] = [:]
    private var effectInputs: [MTLTexture] = []
    private let clouds: WSSCloudsResources?
    private let cloudsReplace: MTLRenderPipelineState?
    private let cloudsOver: MTLRenderPipelineState?
    private let cloudsExtendedReplace: MTLRenderPipelineState?
    private let cloudsExtendedOver: MTLRenderPipelineState?
    private let cloudsSoftReplace: MTLRenderPipelineState?
    private let cloudsSoftOver: MTLRenderPipelineState?
    private let replace: MTLRenderPipelineState
    private let sourceOver: MTLRenderPipelineState
    private var directionPreviewBytes = 0
    var bufferBytes: Int { rain?.bufferBytes ?? 0 }
    var textureBytes: Int {
        images.values.reduce(
            (clouds?.textureBytes ?? 0) + (ripple?.textureBytes ?? 0)
                + (vectorFields?.textureBytes ?? 0) + (flow?.regionTextureBytes ?? 0)
                + (rain?.textureBytes ?? 0) + directionPreviewBytes
        ) {
            $0 + $1.texture.allocatedSize
        }
    }

    init(
        scene: WSSScene, assets: any WSSImageAssetSource, device: MTLDevice,
        staticCanvas: Bool = false, referenceFlowShader: String? = nil
    ) throws {
        try scene.validate(allowEmpty: staticCanvas)
        family = NSObject()
        self.scene = scene
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw WSSSceneError.invalid("Metal queue")
        }
        self.queue = queue
        let library = try device.makeLibrary(
            source: Self.shader + WSSCloudsResources.shader + WSSCloudsResources.extendedShader
                + WSSCloudsResources.softShader + WSSRainResources.shader
                + WSSRippleResources.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "imageQuad")
        descriptor.fragmentFunction = library.makeFunction(name: "imageColor")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        replace = try device.makeRenderPipelineState(descriptor: descriptor)
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        sourceOver = try device.makeRenderPipelineState(descriptor: descriptor)
        if scene.imageLayers.contains(where: {
            $0.effects.contains {
                if case .clouds = $0 { return true }
                return false
            }
        }) {
            clouds = try WSSCloudsResources(scene: scene, assets: assets, device: device)
            descriptor.fragmentFunction = library.makeFunction(name: "cloudsColor")
            cloudsOver = try device.makeRenderPipelineState(descriptor: descriptor)
            color.isBlendingEnabled = false
            cloudsReplace = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "cloudsExtendedColor")
            cloudsExtendedReplace = try device.makeRenderPipelineState(descriptor: descriptor)
            color.isBlendingEnabled = true
            cloudsExtendedOver = try device.makeRenderPipelineState(descriptor: descriptor)
            if scene.imageLayers.contains(where: { layer in
                layer.effects.contains {
                    if case .clouds(let e) = $0 { return e.softness > 0 }
                    return false
                }
            }) {
                descriptor.fragmentFunction = library.makeFunction(name: "cloudsSoftColor")
                cloudsSoftOver = try device.makeRenderPipelineState(descriptor: descriptor)
                color.isBlendingEnabled = false
                cloudsSoftReplace = try device.makeRenderPipelineState(descriptor: descriptor)
            } else {
                cloudsSoftOver = nil
                cloudsSoftReplace = nil
            }
        } else {
            clouds = nil
            cloudsOver = nil
            cloudsReplace = nil
            cloudsExtendedReplace = nil
            cloudsExtendedOver = nil
            cloudsSoftOver = nil
            cloudsSoftReplace = nil
        }
        ripple =
            try scene.imageLayers.contains(where: {
                $0.effects.contains {
                    if $0.samplingRipple != nil { return true }
                    return false
                }
            })
            ? WSSRippleResources(scene: scene, assets: assets, device: device, library: library)
            : nil
        rain =
            try scene.layers.contains(where: {
                if case .rain = $0 { return true }
                return false
            })
            ? WSSRainResources(scene: scene, assets: assets, device: device, library: library) : nil
        trail =
            try scene.layers.contains {
                if case .trail = $0 { return true }
                return false
            }
            ? WSSTrailRenderer(device: device) : nil
        let fieldIDs = scene.imageLayers.flatMap { layer in
            layer.effects.compactMap { e -> WSSAssetID? in
                if case .flow(let f) = e { return f.flowMap }
                return nil
            }
        }
        vectorFields =
            try fieldIDs.isEmpty
            ? nil
            : WSSVectorFieldResources(ids: fieldIDs, device: device) {
                try assets.vectorField(for: $0)
            }
        flow =
            try scene.imageLayers.contains { layer in
                layer.effects.contains {
                    if case .flow = $0 { return true }
                    return false
                }
            }
            ? WSSFlowResources(
                scene: scene, assets: assets, device: device, sharedFields: vectorFields,
                referenceShader: referenceFlowShader) : nil
        var loaded: [WSSAssetID: Image] = [:]
        var budget =
            (vectorFields?.textureBytes ?? 0) + (flow?.regionTextureBytes ?? 0)
            + (rain?.textureBytes ?? 0)
        for layer in scene.imageLayers where loaded[layer.asset] == nil {
            try Task.checkCancellation()
            let asset = try assets.image(for: layer.asset)
            guard (1...8192).contains(asset.width), (1...8192).contains(asset.height),
                asset.uvScale.x.isFinite, asset.uvScale.y.isFinite,
                asset.uvScale.x > 0, asset.uvScale.x <= 1, asset.uvScale.y > 0, asset.uvScale.y <= 1
            else { throw WSSSceneError.invalid("image dimensions or UV bounds") }
            budget += asset.width * asset.height * 4
            guard budget <= 128 * 1024 * 1024 else {
                throw WSSSceneError.decodedImageBudget
            }
            let texture = try Self.upload(asset, device: device, queue: queue)
            let settings = MTLSamplerDescriptor()
            settings.minFilter = asset.filter == .linear ? .linear : .nearest
            settings.magFilter = settings.minFilter
            settings.mipFilter =
                asset.mipmapped ? (asset.filter == .linear ? .linear : .nearest) : .notMipmapped
            settings.sAddressMode = asset.edge == .clamp ? .clampToEdge : .repeat
            settings.tAddressMode = settings.sAddressMode
            guard let sampler = device.makeSamplerState(descriptor: settings) else {
                throw WSSSceneError.invalid("image sampler")
            }
            loaded[layer.asset] = Image(texture: texture, sampler: sampler, uvScale: asset.uvScale)
        }
        images = loaded
        for (index, node) in scene.layers.enumerated() {
            guard case .image(let layer) = node else { continue }
            effectPlans[index] = try WSSImageEffectPlan(
                effects: layer.effects,
                binding: { effect in
                    var binding = WSSImageEffectPlan.Binding()
                    switch effect {
                    case .ripple(let e):
                        binding.ripple = ripple
                        binding.mask = e.mask.flatMap { ripple?.masks[$0.asset]?.texture }
                    case .clouds(let e):
                        binding.clouds = clouds
                        binding.mask = e.mask.flatMap { clouds?.masks[$0.asset]?.texture }
                        binding.maskUV =
                            e.mask.flatMap { clouds?.masks[$0.asset]?.uvScale } ?? SIMD2(1, 1)
                        binding.noise = clouds?.noise[e.seed]
                    case .flow(let e):
                        binding.flow = flow
                        binding.field = vectorFields?.fields[e.flowMap]
                    }
                    return binding
                }, flowActive: { flow?.isActive($0) == true })
        }
        effectInputs = Array(images.values.map(\.texture))
        for plan in effectPlans.values {
            for stage in plan.stages {
                if let mask = stage.binding.mask { effectInputs.append(mask) }
                if let noise = stage.binding.noise { effectInputs.append(noise) }
                if let field = stage.binding.field {
                    effectInputs.append(field.vectors)
                    if let coverage = field.coverage { effectInputs.append(coverage) }
                }
            }
        }
    }
    // Only the scene transforms change. Every GPU resource remains immutable/shared.
    private init(
        scene: WSSScene, sharing original: WSSStaticResources, flowOverride: WSSFlowResources? = nil
    ) {
        self.scene = scene
        family = original.family
        device = original.device
        queue = original.queue
        images = original.images
        trail = original.trail
        rain = original.rain
        ripple = original.ripple
        flow = flowOverride ?? original.flow
        directionPreviewBytes = flowOverride?.fields.textureBytes ?? original.directionPreviewBytes
        vectorFields = original.vectorFields
        effectPlans = original.effectPlans
        effectInputs = original.effectInputs
        clouds = original.clouds
        cloudsReplace = original.cloudsReplace
        cloudsOver = original.cloudsOver
        cloudsExtendedReplace = original.cloudsExtendedReplace
        cloudsExtendedOver = original.cloudsExtendedOver
        cloudsSoftReplace = original.cloudsSoftReplace
        cloudsSoftOver = original.cloudsSoftOver
        replace = original.replace
        sourceOver = original.sourceOver
    }
    func previewDirection(at address: WSSEffectAddress, state: WSSDirectionPaintState) throws
        -> WSSStaticResources
    {
        guard let original = flow, let plan = effectPlans[address.layerIndex],
            plan.stages.indices.contains(address.effectIndex),
            case .flow(let effect) = plan.stages[address.effectIndex].declaredEffect,
            case .image(let layer) = scene.layers[address.layerIndex]
        else { throw WSSVectorFieldEditError.stale }
        try state.field.validate()
        try state.region?.validate()
        let estimate =
            state.field.vectors.count + (state.field.coverage?.count ?? 0)
            + (state.region?.pixels.count ?? 0) * 5 + 4096
        // Budget two in-flight frames, the displayed state and the next upload.
        guard estimate <= (128 * 1024 * 1024 - textureBytes) / 4 else {
            throw WSSVectorFieldEditError.budget
        }
        let replacement = try WSSFlowResources(
            effect: effect, size: layer.transform.localSize,
            field: state.field, region: state.region, sharing: original, device: device)
        let regionBytes = replacement.regions.filter {
            $0.id == effect.flowRegion && $0.size == layer.transform.localSize
        }
        .reduce(0) { $0 + $1.region.allocatedSize + $1.distance.allocatedSize }
        guard
            replacement.fields.textureBytes + regionBytes <= (128 * 1024 * 1024 - textureBytes) / 4
        else { throw WSSVectorFieldEditError.budget }
        let result = WSSStaticResources(scene: scene, sharing: self, flowOverride: replacement)
        var stages = plan.stages
        let old = stages[address.effectIndex]
        var binding = old.binding
        binding.flow = replacement
        binding.field = replacement.fields.fields[effect.flowMap]
        stages[address.effectIndex] = WSSImageEffectPlan.Stage(
            manifestIndex: old.manifestIndex,
            declaredEffect: old.declaredEffect,
            effect: replacement.isActive(effect) ? .flow(effect) : nil, binding: binding)
        result.effectPlans[address.layerIndex] = WSSImageEffectPlan(stages: stages)
        if let field = binding.field {
            result.effectInputs.append(field.vectors)
            if let coverage = field.coverage { result.effectInputs.append(coverage) }
        }
        result.effectInputs += replacement.regions.flatMap { [$0.region, $0.distance] }
        return result
    }
    func sharesPreparedResources(with other: WSSStaticResources) -> Bool {
        family === other.family
    }
    func updatingTransforms(
        from previous: WSSSceneDocumentV1, to candidate: WSSSceneDocumentV1,
        staticCanvas: Bool = false
    ) throws -> WSSStaticResources? {
        guard previous.layers.count == candidate.layers.count,
            scene.layers.count == previous.layers.count
        else { return nil }
        var normalized = candidate
        var updated = scene
        for index in previous.layers.indices {
            if case .image(let old) = previous.layers[index].content,
                case .image(var new) = normalized.layers[index].content,
                case .image(var native) = updated.layers[index]
            {
                // Region distances are measured in local image pixels. View/layer
                // transforms can share textures, but changing local size cannot.
                if old.transform.size != new.transform.size,
                    old.effects.contains(where: { $0.flowRegionID != nil })
                {
                    return nil
                }
                native.transform = try new.transform.native()
                updated.layers[index] = .image(native)
                new.transform = old.transform
                normalized.layers[index].content = .image(new)
            }
        }
        guard normalized == previous else { return nil }
        try updated.validate(allowEmpty: staticCanvas)
        return WSSStaticResources(scene: updated, sharing: self)
    }
    private static func upload(_ asset: WSSImageAsset, device: MTLDevice, queue: MTLCommandQueue)
        throws -> MTLTexture
    {
        var pixels: Data
        switch asset.payload {
        case .rgba8(let bytes):
            guard bytes.count == asset.width * asset.height * 4 else {
                throw WSSSceneError.invalid("RGBA byte count")
            }
            pixels = bytes
            pixels.withUnsafeMutableBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    for c in 0..<3 {
                        bytes[i + c] = UInt8((Int(bytes[i + c]) * Int(bytes[i + 3]) + 127) / 255)
                    }
                }
            }
        case .encoded(let data):
            guard data.count <= 128 * 1024 * 1024,
                let source = CGImageSourceCreateWithData(
                    data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) == 1,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                properties[kCGImagePropertyPixelWidth] as? Int == asset.width,
                properties[kCGImagePropertyPixelHeight] as? Int == asset.height,
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                image.width == asset.width, image.height == asset.height,
                image.bitsPerComponent == 8
            else { throw WSSSceneError.invalid("encoded image") }
            if [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) {
                return try MTKTextureLoader(device: device).newTexture(
                    cgImage: image,
                    options: [
                        .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
                        .generateMipmaps: asset.mipmapped,
                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    ])
            }
            pixels = Data(count: asset.width * asset.height * 4)
            let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: asset.width, height: asset.height,
                        bitsPerComponent: 8, bytesPerRow: asset.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.draw(
                    image, in: CGRect(x: 0, y: 0, width: asset.width, height: asset.height))
                return true
            }
            guard success else { throw WSSSceneError.invalid("image normalization") }
        }
        let settings = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: asset.width, height: asset.height,
            mipmapped: asset.mipmapped)
        settings.usage = .shaderRead
        settings.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: settings) else {
            throw WSSSceneError.invalid("image allocation")
        }
        pixels.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, asset.width, asset.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: asset.width * 4)
        }
        if asset.mipmapped {
            guard let command = queue.makeCommandBuffer(),
                let blit = command.makeBlitCommandEncoder()
            else { throw WSSSceneError.invalid("mipmap encoder") }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw WSSSceneError.invalid("mipmap generation")
            }
        }
        return texture
    }
    // Compatibility inspection API. Rendering addresses plans by scene-layer index.
    func stages(for layer: WSSImageLayer) -> [WSSImageEffect] {
        effectPlans.values.first { $0.stages.map(\.declaredEffect) == layer.effects }?.effects ?? []
    }
    struct Uniforms {
        var horizontal: SIMD4<Float>
        var vertical: SIMD4<Float>
        var sampling: SIMD4<Float>
    }
    func encode(
        command: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, size: CGSize,
        time: Double = 0, rippleContext: WSSRippleRenderContext? = nil,
        trailContext: WSSTrailRenderContext? = nil, pointer: SIMD2<Float>? = nil,
        projection: WSSRenderProjection = .cover, advanceTrail: Bool = true
    ) throws {
        guard time.isFinite, time >= 0 else { throw WSSSceneError.invalid("playback time") }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            command.commandQueue.device.registryID == device.registryID,
            let output = descriptor.colorAttachments[0].texture, output.pixelFormat == .bgra8Unorm,
            output.sampleCount == 1, output.device.registryID == device.registryID
        else { throw WSSSceneError.invalid("render target") }
        guard !effectInputs.contains(where: { $0 === output }) else {
            throw WSSSceneError.invalid("effect input/output alias")
        }
        let aspect = Float(size.width / size.height)
        let canvasAspect = Float(scene.width) / Float(scene.height)
        let crop =
            projection == .fullCanvas
            ? SIMD2<Float>(repeating: 1)
            : (aspect > canvasAspect
                ? SIMD2<Float>(1, canvasAspect / aspect) : SIMD2<Float>(aspect / canvasAspect, 1))
        var requests: [WSSImageEffectRenderContext.Target: SIMD2<Int>] = [:]
        for (index, node) in scene.layers.enumerated() {
            guard case .image(let layer) = node, layer.visible,
                let plan = effectPlans[index], plan.intermediateCount > 0
            else { continue }
            let t = layer.transform
            let density = SIMD2(
                Float(size.width) / (Float(scene.width) * crop.x),
                Float(size.height) / (Float(scene.height) * crop.y))
            let width = ceil(simd_length(t.axisX * density))
            let height = ceil(simd_length(t.axisY * density))
            guard width.isFinite, height.isFinite, width >= 1, height >= 1,
                width <= 8192, height <= 8192
            else { throw WSSSceneError.invalid("effect projected dimensions") }
            for scratch in 0..<plan.intermediateCount {
                requests[.init(layer: index, scratch: scratch)] = SIMD2(Int(width), Int(height))
            }
        }
        let lease: WSSImageEffectRenderContext.Lease?
        if requests.isEmpty {
            lease = nil
        } else {
            guard let rippleContext, rippleContext.device.registryID == device.registryID else {
                throw WSSSceneError.invalid("effect stack requires its player's render context")
            }
            lease = try rippleContext.acquire(
                requests: requests, output: output, inputs: effectInputs)
        }
        var completionOwnsLease = false
        defer { if !completionOwnsLease, let lease { rippleContext?.release(lease) } }
        if let lease {
            for (index, node) in scene.layers.enumerated() {
                guard case .image(let layer) = node, layer.visible,
                    let plan = effectPlans[index], plan.intermediateCount > 0,
                    var input = images[layer.asset]
                else { continue }
                for (position, stage) in plan.activeStages.dropLast().enumerated() {
                    guard
                        let target = lease.intermediateTargets[
                            .init(layer: index, scratch: position % 2)],
                        input.texture !== target
                    else {
                        throw WSSSceneError.invalid("effect input/target alias or missing target")
                    }
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                    guard let local = command.makeRenderCommandEncoder(descriptor: pass) else {
                        throw WSSSceneError.invalid("effect intermediate encoder")
                    }
                    local.setCullMode(.none)
                    do {
                        try encodeImageStage(
                            stage, input: input, layer: layer,
                            mode: .intermediate, time: time, encoder: local)
                    } catch {
                        local.endEncoding()
                        throw error
                    }
                    local.endEncoding()
                    input = try intermediateImage(target)
                }
            }
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WSSSceneError.invalid("image encoder")
        }
        encoder.setCullMode(.none)
        for (index, node) in scene.layers.enumerated() where node.visible {
            if case .trail(let layer) = node {
                do {
                    guard let trail, let trailContext else {
                        throw WSSSceneError.invalid("trail requires player context")
                    }
                    try trailContext.encode(
                        index: index, layer: layer, renderer: trail,
                        encoder: encoder, time: time, pointer: pointer,
                        canvas: SIMD2(Float(scene.width), Float(scene.height)), crop: crop,
                        advance: advanceTrail)
                } catch {
                    encoder.endEncoding()
                    throw error
                }
                continue
            }
            if case .rain = node {
                rain?.encode(
                    index, encoder: encoder, canvas: SIMD2(Float(scene.width), Float(scene.height)),
                    crop: crop, time: time)
                continue
            }
            guard case .image(let layer) = node else { continue }
            guard let image = images[layer.asset] else {
                encoder.endEncoding()
                throw WSSSceneError.invalid("missing prepared image")
            }
            do {
                guard let plan = effectPlans[index] else {
                    throw WSSSceneError.invalid("missing prepared effect plan")
                }
                let input: Image
                if plan.intermediateCount > 0 {
                    guard
                        let target = lease?.intermediateTargets[
                            .init(layer: index, scratch: (plan.activeStages.count - 2) % 2)]
                    else {
                        throw WSSSceneError.invalid("missing final effect input")
                    }
                    input = try intermediateImage(target)
                } else {
                    input = image
                }
                try encodeImageStage(
                    plan.activeStages.last, input: input, layer: layer,
                    mode: .composition(crop: crop), time: time, encoder: encoder)
            } catch {
                encoder.endEncoding()
                throw error
            }
        }
        encoder.endEncoding()
        if let lease, let rippleContext {
            command.addCompletedHandler { _ in rippleContext.release(lease) }
            completionOwnsLease = true
        }
    }

    enum ImageOutputMode {
        // Preserve the frozen neutral output: opacity one, transparent clear + over.
        case intermediate
        case composition(crop: SIMD2<Float>)
    }

    // One outer contract for every active effect; the caller explicitly supplies
    // either the original image sampling contract or the preceding stage output.
    func encodeImageStage(
        _ stage: WSSImageEffectPlan.Stage?, input: Image, layer: WSSImageLayer,
        mode: ImageOutputMode, time: Double, encoder: MTLRenderCommandEncoder
    ) throws {
        let t = layer.transform
        let composition: WSSImageLayer.Composition
        var u: Uniforms
        switch mode {
        case .intermediate:
            composition = .sourceOver
            u = Uniforms(
                horizontal: SIMD4(2, 0, 0, 2), vertical: SIMD4(0, 2, 0, 2),
                sampling: SIMD4(input.uvScale.x, input.uvScale.y, 1, 0))
        case .composition(let crop):
            composition = layer.composition
            u = Uniforms(
                horizontal: SIMD4(t.axisX.x, t.axisY.x, t.center.x, Float(scene.width) * crop.x),
                vertical: SIMD4(t.axisX.y, t.axisY.y, t.center.y, Float(scene.height) * crop.y),
                sampling: SIMD4(
                    input.uvScale.x, input.uvScale.y, layer.opacity,
                    composition == .replace ? 1 : 0))
            u.horizontal.z -= Float(scene.width) / 2
            u.vertical.z -= Float(scene.height) / 2
        }
        if stage == nil {
            encoder.setRenderPipelineState(composition == .replace ? replace : sourceOver)
        }
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(input.texture, index: 0)
        encoder.setFragmentSamplerState(input.sampler, index: 0)
        if let stage {
            guard let effect = stage.effect else {
                throw WSSSceneError.invalid("elided stage dispatched")
            }
            switch effect {
            case .ripple(let effect):
                guard let ripple = stage.binding.ripple else {
                    throw WSSSceneError.invalid("missing Ripple stage resources")
                }
                try ripple.bind(
                    effect, size: t.localSize, time: time,
                    composition: composition, encoder: encoder)
            case .flow(let effect):
                guard let flow = stage.binding.flow, let field = stage.binding.field else {
                    throw WSSSceneError.invalid("missing Flow stage resources")
                }
                try flow.bind(
                    effect, size: t.localSize, time: time,
                    composition: composition, encoder: encoder, boundField: field)
            case .clouds(let effect):
                guard let clouds = stage.binding.clouds, stage.binding.noise != nil else {
                    throw WSSSceneError.invalid("missing Clouds stage resources")
                }
                try bindClouds(
                    effect, stage: stage, clouds: clouds, transform: t,
                    time: time, composition: composition, encoder: encoder)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func bindClouds(
        _ effect: WSSCloudsEffect, stage: WSSImageEffectPlan.Stage,
        clouds: WSSCloudsResources, transform t: WSSImageTransform, time: Double,
        composition: WSSImageLayer.Composition, encoder: MTLRenderCommandEncoder
    ) throws {
        let phase = try effect.phase(at: time, orientation: WSSCloudsNoise.orientation)
        let middle = try effect.phase(
            at: time, frequency: WSSCloudsNoise.middleFrequency,
            orientation: WSSCloudsNoise.orientation)
        let detail = try effect.phase(
            at: time, frequency: WSSCloudsNoise.detailFrequency,
            orientation: WSSCloudsNoise.orientation)
        let maskUV = stage.binding.maskUV
        let secondary = effect.secondaryField
        let secondaryPhase = try effect.secondaryPhase(at: time)
        let light = effect.shadingVector / 32 * (1 + effect.softness)
        let primaryLight = SIMD2(
            WSSCloudsNoise.orientation.x * light.x - WSSCloudsNoise.orientation.y * light.y,
            WSSCloudsNoise.orientation.y * light.x + WSSCloudsNoise.orientation.x * light.y)
        let secondaryLight =
            SIMD2(
                WSSCloudsNoise.secondaryOrientation.x * light.x - WSSCloudsNoise
                    .secondaryOrientation.y * light.y,
                WSSCloudsNoise.secondaryOrientation.y * light.x + WSSCloudsNoise
                    .secondaryOrientation.x * light.y)
            * (effect.scale / (secondary?.scale ?? effect.scale))
        var c = WSSCloudsResources.Uniforms(
            domain: SIMD4(
                simd_length(t.axisX) / effect.scale, simd_length(t.axisY) / effect.scale,
                phase.x, phase.y),
            appearance: SIMD4(
                effect.intensity, effect.density, WSSCloudsNoise.middleFrequency,
                WSSCloudsNoise.detailFrequency),
            maskUV: SIMD4(
                maskUV.x, maskUV.y, WSSCloudsNoise.orientation.x,
                WSSCloudsNoise.orientation.y),
            detailPhases: SIMD4(middle.x, middle.y, detail.x, detail.y),
            secondary: SIMD4(
                simd_length(t.axisX) / (secondary?.scale ?? effect.scale),
                simd_length(t.axisY) / (secondary?.scale ?? effect.scale),
                secondaryPhase.x, secondaryPhase.y),
            controls: SIMD4(
                secondary == nil ? 0 : effect.secondaryInfluence, effect.brightness,
                effect.shadingAmount, effect.softness),
            lightSteps: SIMD4(
                primaryLight.x, primaryLight.y, secondaryLight.x, secondaryLight.y))
        encoder.setRenderPipelineState(
            effect.softness > 0
                ? (composition == .replace ? cloudsSoftReplace! : cloudsSoftOver!)
                : effect.isExtended
                    ? (composition == .replace
                        ? cloudsExtendedReplace! : cloudsExtendedOver!)
                    : (composition == .replace ? cloudsReplace! : cloudsOver!))
        encoder.setFragmentBytes(
            &c, length: MemoryLayout<WSSCloudsResources.Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(stage.binding.noise, index: 1)
        encoder.setFragmentTexture(stage.binding.mask ?? clouds.white, index: 2)
        encoder.setFragmentSamplerState(clouds.noiseSampler, index: 1)
        encoder.setFragmentSamplerState(clouds.maskSampler, index: 2)
    }

    private func intermediateImage(_ texture: MTLTexture) throws -> Image {
        guard let sampler = ripple?.sampler ?? vectorFields?.sampler ?? clouds?.maskSampler else {
            throw WSSSceneError.invalid("missing intermediate sampler")
        }
        return Image(texture: texture, sampler: sampler, uvScale: SIMD2(1, 1))
    }
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct ImageTransform { float4 horizontal, vertical, sampling; };
        struct ImageVertex { float4 position [[position]]; float2 uv; };
        vertex ImageVertex imageQuad(uint corner [[vertex_id]], constant ImageTransform &t [[buffer(0)]]) {
            float2 cornerUV = float2(corner % 2, corner / 2);
            float2 q = cornerUV - 0.5;
            float x = (dot(t.horizontal.xy, q) + t.horizontal.z) * 2 / t.horizontal.w;
            float y = (dot(t.vertical.xy, q) + t.vertical.z) * 2 / t.vertical.w;
            return { float4(x, y, 0, 1), float2(cornerUV.x, 1-cornerUV.y) };
        }
        fragment float4 imageColor(ImageVertex v [[stage_in]], constant ImageTransform &t [[buffer(0)]], texture2d<float> image [[texture(0)]], sampler filtering [[sampler(0)]]) {
            float4 pixel = image.sample(filtering, v.uv * t.sampling.xy);
            if (t.sampling.w > 0.5) {
                return float4(pixel.a > 0 ? pixel.rgb / pixel.a : float3(0), pixel.a * t.sampling.z);
            }
            return pixel * t.sampling.z;
        }
        """
}
