// Offscreen benchmark of the actual terminal shaders. No window or UI input.
// swiftc -O benchmark_scroll_gpu.swift -o benchmark-scroll-gpu -framework Metal
// benchmark-scroll-gpu src/renderer/shaders/shaders.metal results.json
import Foundation
import Metal
import simd

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: sourceURL, encoding: .utf8)
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("Metal device unavailable")
}
let start = source.range(of: "float scroll_opacity(")!.lowerBound
let end = source.range(of: "\n}\n", range: start..<source.endIndex)!.upperBound
let without = source.replacingCharacters(in: start..<end,
    with: "float scroll_opacity(float y, constant Uniforms& uniforms) { return 1.0; }\n")
let originalHelper = String(source[start..<end])
let edgeOnly = source.replacingCharacters(in: start..<end, with:
    originalHelper.replacingOccurrences(of: "  float opacity = 1.0;", with: """
  if ((uniforms.scroll_fade.z <= 0 || y >= uniforms.scroll_fade.x + uniforms.scroll_fade.z) &&
      (uniforms.scroll_fade.w <= 0 || y <= uniforms.scroll_fade.y - uniforms.scroll_fade.w)) return 1.0;
  float opacity = 1.0;
"""))
let options = MTLCompileOptions()
if #available(macOS 15, *) { options.mathMode = .fast } else { options.fastMathEnabled = true }
let libraries = try [without, source, edgeOnly].map { try device.makeLibrary(source: $0, options: options) }

func pipeline(_ library: MTLLibrary, text: Bool) throws -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: text ? "cell_text_vertex" : "full_screen_vertex")
    d.fragmentFunction = library.makeFunction(name: text ? "cell_text_fragment" : "cell_bg_fragment")
    let a = d.colorAttachments[0]!
    a.pixelFormat = .bgra8Unorm
    a.isBlendingEnabled = true
    a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
    a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    if text {
        let v = MTLVertexDescriptor()
        let formats: [MTLVertexFormat] = [.uint2, .uint2, .short2, .ushort2, .uchar4, .uchar, .uchar]
        let offsets = [0, 8, 16, 20, 24, 28, 29]
        for i in formats.indices {
            v.attributes[i].format = formats[i]; v.attributes[i].offset = offsets[i]; v.attributes[i].bufferIndex = 0
        }
        v.layouts[0].stride = 32; v.layouts[0].stepFunction = .perInstance
        d.vertexDescriptor = v
    }
    return try device.makeRenderPipelineState(descriptor: d)
}
let pipelines = try libraries.map { (try pipeline($0, text: false), try pipeline($0, text: true)) }
let atlasDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 256, mipmapped: false)
atlasDesc.usage = .shaderRead; atlasDesc.storageMode = .shared
let atlas = device.makeTexture(descriptor: atlasDesc)!
let pixels = (0..<(256 * 256)).map { UInt8(($0 % 7 < 3 && $0 / 256 % 11 < 7) ? 220 : 0) }
pixels.withUnsafeBytes { atlas.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0,
                                      withBytes: $0.baseAddress!, bytesPerRow: 256) }
let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
colorDesc.usage = .shaderRead
let colorAtlas = device.makeTexture(descriptor: colorDesc)!
let names = ["no_fade_code", "fades_disabled", "fades_enabled", "edge_only"]
var results: [[String: Any]] = []
for (width, height) in [(1600, 1200), (2560, 1600), (3840, 2160)] {
    let cw = 16, ch = 34, cols = width / cw, rows = height / ch + 1
    let glyphs = device.makeBuffer(length: cols * rows * 32, options: .storageModeShared)!
    let cells = device.makeBuffer(length: cols * rows * 4, options: .storageModeShared)!
    memset(glyphs.contents(), 0, glyphs.length)
    for i in 0..<(cols * rows) {
        let p = glyphs.contents().advanced(by: i * 32)
        p.storeBytes(of: UInt32(i % 16 * 16), as: UInt32.self)
        p.storeBytes(of: UInt32(i / 16 % 6 * 32), toByteOffset: 4, as: UInt32.self)
        p.storeBytes(of: UInt32(14), toByteOffset: 8, as: UInt32.self)
        p.storeBytes(of: UInt32(28), toByteOffset: 12, as: UInt32.self)
        p.storeBytes(of: Int16(30), toByteOffset: 18, as: Int16.self)
        p.storeBytes(of: UInt16(i % cols), toByteOffset: 20, as: UInt16.self)
        p.storeBytes(of: UInt16(i / cols), toByteOffset: 22, as: UInt16.self)
        p.storeBytes(of: UInt32(0xFFDCDCDC), toByteOffset: 24, as: UInt32.self)
        p.storeBytes(of: UInt8(1), toByteOffset: 29, as: UInt8.self)
        cells.contents().storeBytes(of: UInt32(i % 3 == 0 ? 0xFF282420 : 0xFF161616),
                                    toByteOffset: i * 4, as: UInt32.self)
    }
    // Byte offsets match both the Zig extern struct and MSL Uniforms.
    let uniforms = device.makeBuffer(length: 192, options: .storageModeShared)!
    let u = uniforms.contents(); memset(u, 0, uniforms.length)
    let w = Float(width), h = Float(height)
    let projection = simd_float4x4(SIMD4(2/w, 0, 0, 0), SIMD4(0, -2/h, 0, 0),
                                  SIMD4(0, 0, 1, 0), SIMD4(-1, 1, 0, 1))
    u.storeBytes(of: projection, as: simd_float4x4.self)
    u.storeBytes(of: SIMD2(w, h), toByteOffset: 64, as: SIMD2<Float>.self)
    u.storeBytes(of: SIMD2(Float(cw), Float(ch)), toByteOffset: 72, as: SIMD2<Float>.self)
    u.storeBytes(of: SIMD2(UInt16(cols), UInt16(rows)), toByteOffset: 80, as: SIMD2<UInt16>.self)
    u.storeBytes(of: UInt32.max, toByteOffset: 120, as: UInt32.self)
    u.storeBytes(of: UInt32(0xFF161616), toByteOffset: 128, as: UInt32.self)
    u.storeBytes(of: Float(1), toByteOffset: 144, as: Float.self)
    u.storeBytes(of: h - 96, toByteOffset: 152, as: Float.self)
    let targetDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    targetDesc.usage = .renderTarget; targetDesc.storageMode = .private
    let target = device.makeTexture(descriptor: targetDesc)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.08, 0.08, 1)
    func render(mode: Int, round: Int) -> (Double, Double) {
        let index = mode == 0 ? 0 : mode == 3 ? 2 : 1
        let fade: SIMD4<Float> = mode == 1 ? .zero : SIMD4(0, h - 96, 51, 51)
        u.storeBytes(of: fade, toByteOffset: 176, as: SIMD4<Float>.self)
        u.storeBytes(of: Float(round % ch), toByteOffset: 148, as: Float.self)
        let command = queue.makeCommandBuffer()!
        let begin = ProcessInfo.processInfo.systemUptime
        let repetitions = 8
        for _ in 0..<repetitions {
            let e = command.makeRenderCommandEncoder(descriptor: pass)!
            e.setVertexBuffer(uniforms, offset: 0, index: 1)
            e.setFragmentBuffer(uniforms, offset: 0, index: 1)
            e.setFragmentBuffer(cells, offset: 0, index: 2)
            e.setRenderPipelineState(pipelines[index].0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.setRenderPipelineState(pipelines[index].1)
            e.setVertexBuffer(glyphs, offset: 0, index: 0)
            e.setVertexBuffer(cells, offset: 0, index: 2)
            e.setFragmentTexture(atlas, index: 0); e.setFragmentTexture(colorAtlas, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cols * rows)
            e.endEncoding()
        }
        let encoded = ProcessInfo.processInfo.systemUptime - begin
        command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed, String(describing: command.error))
        return ((command.gpuEndTime - command.gpuStartTime) * 1000 / Double(repetitions),
                encoded * 1000 / Double(repetitions))
    }
    for round in 0..<12 { for mode in 0..<4 { _ = render(mode: mode, round: round) } }
    var samples = Array(repeating: [Double](), count: 4)
    var cpu = samples
    for round in 0..<48 {
        // Rotate and reverse order, sharing one device/queue/target/buffer set.
        var order = (0..<4).map { ($0 + round) % 4 }
        if round % 2 != 0 { order.reverse() }
        for mode in order {
            let (gpu, encoding) = render(mode: mode, round: round)
            samples[mode].append(gpu); cpu[mode].append(encoding)
        }
    }
    func percentile(_ a: [Double], _ p: Double) -> Double { a.sorted()[Int(Double(a.count - 1) * p)] }
    for mode in 0..<4 {
        results.append(["width": width, "height": height, "mode": names[mode],
            "gpu_median_ms": percentile(samples[mode], 0.5), "gpu_p95_ms": percentile(samples[mode], 0.95),
            "cpu_encode_median_ms": percentile(cpu[mode], 0.5), "gpu_samples_ms": samples[mode]])
    }
}
let output: [String: Any] = ["device": device.name, "shader": sourceURL.path,
    "method": "Interleaved offscreen actual background+text pipelines; 12 warmup, 48 rounds, 8 render passes per command buffer; GPU timestamps. Synthetic dense glyph fixture, not WindowServer latency or a claim about all terminal workloads.",
    "results": results]
try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
for r in results { print(r["width"]!, r["height"]!, r["mode"]!, r["gpu_median_ms"]!, r["gpu_p95_ms"]!) }
