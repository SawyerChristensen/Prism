//
//  ProjectMCoordinator.swift
//  Prism
//
//  Replaces MilkdropMetalCoordinator for the new engine. Deliberately simpler than the old one:
//  MilkdropMetalCoordinator kept two full parallel MilkdropMetalRenderer instances
//  (activeRenderer/outgoingRenderer) and cross-faded them in Swift, because the old hand-rolled
//  engine had no concept of blending two presets itself. Real projectM does preset transitions
//  internally on a single persistent instance (smooth_transition, per ProjectMEngine.loadPreset) -
//  so one ProjectMEngine, created once, lives for this coordinator's whole lifetime, and "loading a
//  new preset" is just a call on that same engine, not constructing a new renderer object.
//

import MetalKit
import IOSurface

final class ProjectMCoordinator: NSObject, MTKViewDelegate {
    private let engine: ProjectMEngine?
    private let audioEngine: CoreAudioTapEngine
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    // Cached Metal wrap of the engine's current IOSurface render target - only needs rebuilding
    // when the size changes or the engine hands back a different underlying surface (a resize),
    // not every frame (see ProjectMEGLContext.framebufferForWidth:height:'s matching cache).
    private var cachedTexture: MTLTexture?
    private var cachedIOSurface: IOSurface?
    private var cachedWidth = 0
    private var cachedHeight = 0

    private var lastLoadedPresetURL: URL?
    private weak var model: ProjectMVisualizerModel?

    init(audioEngine: CoreAudioTapEngine) {
        engine = ProjectMEngine()
        self.audioEngine = audioEngine
        super.init()
        if engine == nil {
            NSLog("ProjectMCoordinator: ProjectMEngine failed to initialize")
        }
        engine?.presetLoadFailureHandler = { [weak self] filename, message in
            NSLog("ProjectMCoordinator: preset load failed for \(filename): \(message)")
            DispatchQueue.main.async {
                self?.model?.presetLoadError = "Couldn't load \((filename as NSString).lastPathComponent): \(message)"
            }
        }
    }

    /// Diffs against the last preset this coordinator actually loaded, same pattern
    /// MilkdropMetalCoordinator used for its own model - called every SwiftUI update, but only
    /// triggers an actual engine call when the requested preset URL has changed.
    func updateModelIfNeeded(_ model: ProjectMVisualizerModel) {
        self.model = model
        guard let url = model.presetURL, url != lastLoadedPresetURL else { return }
        lastLoadedPresetURL = url
        engine?.loadPreset(at: url, smoothTransition: true)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let engine,
              let device = view.device,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor
        else {
            return
        }

        if commandQueue == nil {
            commandQueue = device.makeCommandQueue()
        }
        if pipelineState == nil {
            pipelineState = Self.buildPipelineState(device: device, pixelFormat: view.colorPixelFormat)
        }
        guard let commandQueue, let pipelineState else { return }

        ProjectMAudioBridge.feed(engine, from: audioEngine)

        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return }

        guard let ioSurface = engine.renderFrame(width: width, height: height) else { return }

        let texture: MTLTexture
        if let cachedTexture, cachedWidth == width, cachedHeight == height, cachedIOSurface === ioSurface {
            texture = cachedTexture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let newTexture = device.makeTexture(descriptor: descriptor, iosurface: ioSurface, plane: 0) else {
                return
            }
            texture = newTexture
            cachedTexture = newTexture
            cachedIOSurface = ioSurface
            cachedWidth = width
            cachedHeight = height
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func buildPipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "projectm_passthrough_vertex"),
              let fragmentFunction = library.makeFunction(name: "projectm_passthrough_fragment")
        else {
            NSLog("ProjectMCoordinator: failed to load ProjectMCompositeShader.metal functions")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("ProjectMCoordinator: makeRenderPipelineState failed: \(error)")
            return nil
        }
    }
}
