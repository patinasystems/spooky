#if SPOOKY_WINDOW_CAPTURE
import AppKit
import AVFoundation
import ScreenCaptureKit
import VideoToolbox

/// Explicitly enabled, local-only diagnostic recording. No production capture
/// or permission request occurs unless the capture flag and directory are set.
@MainActor
enum CommandWindowCapture {
    private static var attempted = false
    @available(macOS 14.4, *) private static var session: Session?

    static func startIfRequested(for window: NSWindow) {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["SPOOKY_WINDOW_CAPTURE"] == "1"
            || Bundle.main.object(forInfoDictionaryKey: "SpookyWindowCaptureEnabled") as? Bool == true
        guard enabled, !attempted, window.isKeyWindow, window.isVisible, window.isOnActiveSpace,
              #available(macOS 14.4, *) else { return }
        let path = environment["SPOOKY_WINDOW_CAPTURE_DIRECTORY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpookyWindowCaptureDirectory") as? String ?? ""
        guard path.hasPrefix("/"), !path.contains("\0") else { return }
        let seconds = Double(environment["SPOOKY_WINDOW_CAPTURE_SECONDS"] ?? "")
            ?? (Bundle.main.object(forInfoDictionaryKey: "SpookyWindowCaptureSeconds") as? NSNumber)?.doubleValue ?? 30
        let region = environment["SPOOKY_WINDOW_CAPTURE_ROI"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SpookyWindowCaptureROI") as? String ?? ""
        let videoEnabled = environment["SPOOKY_WINDOW_CAPTURE_VIDEO"].map { $0 != "0" }
            ?? Bundle.main.object(forInfoDictionaryKey: "SpookyWindowCaptureVideo") as? Bool ?? true
        attempted = true
        let value = Session(window: window, directory: URL(fileURLWithPath: path, isDirectory: true),
                            duration: max(1, min(60, seconds.isFinite ? seconds : 30)), region: region,
                            videoEnabled: videoEnabled)
        session = value
        Task { await value.run() }
    }

    @available(macOS 14.4, *)
    @MainActor
    private final class Session {
        private weak var window: NSWindow?
        private let directory: URL
        private let duration: Double
        private let region: String
        private let videoEnabled: Bool
        private var stream: SCStream?
        private var output: Output?
        private var timer: Task<Void, Never>?
        private var observers: [NSObjectProtocol] = []
        private var spaceObserver: NSObjectProtocol?
        private var stopped = false
        private var started = false

        init(window: NSWindow, directory: URL, duration: Double, region: String, videoEnabled: Bool) {
            self.window = window
            self.directory = directory
            self.duration = duration
            self.region = region
            self.videoEnabled = videoEnabled
        }

        func run() async {
            do {
                guard let window, window.isVisible else {
                    await stop()
                    return
                }
                // The first key-window callback can precede WindowServer enumeration
                // and the final startup size. Retry only this app-owned window, and
                // require its frame to settle before allocating the recording.
                guard let captured = try await settledWindow(window) else {
                    await stop()
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: captured)
                let preparedFrame = window.frame
                let preparedBackingScale = window.backingScaleFactor
                let scale = max(CGFloat(filter.pointPixelScale), window.backingScaleFactor)
                let width = Int(ceil(max(window.frame.width, max(captured.frame.width, filter.contentRect.width)) * scale))
                let height = Int(ceil(max(window.frame.height, max(captured.frame.height, filter.contentRect.height)) * scale))
                let geometry: [String: Double] = [
                    "window_width_pt": window.frame.width, "window_height_pt": window.frame.height,
                    "shareable_width_pt": captured.frame.width, "shareable_height_pt": captured.frame.height,
                    "filter_width_pt": filter.contentRect.width, "filter_height_pt": filter.contentRect.height,
                    "backing_scale": window.backingScaleFactor, "filter_pixel_scale": Double(filter.pointPixelScale)
                ]
                guard width > 0, height > 0, width <= 8192, height <= 8192,
                      width * height <= 8_388_608 else { return }
                let output = Output(directory: directory, width: width, height: height,
                                    region: region, geometry: geometry, videoEnabled: videoEnabled) { [weak self] in
                    Task { @MainActor in await self?.stop() }
                }
                self.output = output
                try await output.prepare()
                guard !stopped, window.isVisible,
                      window.frame == preparedFrame, window.backingScaleFactor == preparedBackingScale else {
                    await stop()
                    return
                }
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.ignoreShadowsSingleWindow = true
                config.scalesToFit = false
                config.captureResolution = .best
                config.minimumFrameInterval = .zero
                config.queueDepth = 3
                config.capturesAudio = false
                config.showsCursor = false
                // Keep the editor/terminal pixel grid fixed when completion panels appear.
                config.includeChildWindows = false
                if #available(macOS 15.0, *) { config.captureMicrophone = false }
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                self.stream = stream
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                             NSWindow.didChangeBackingPropertiesNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.recordWindowState() }
                        Task { @MainActor in await self?.stop() }
                    })
                }
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didMoveNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.recordWindowState() } })
                }
                for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                             NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: NSApp, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.recordWindowState() } })
                }
                spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.recordWindowState() } }
                recordWindowState()
                try await stream.startCapture()
                guard !stopped else { try? await stream.stopCapture(); return }
                started = true
                timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.duration ?? 30))
                    guard !Task.isCancelled else { return }
                    await self?.stop()
                }
            } catch {
                await stop()
            }
        }

        private func settledWindow(_ window: NSWindow) async throws -> SCWindow? {
            let deadline = ContinuousClock.now + .seconds(2)
            var previousFrame: NSRect?
            var stableObservations = 0
            while !stopped, ContinuousClock.now < deadline {
                guard window.isVisible else { return nil }
                let frame = window.frame
                stableObservations = frame == previousFrame ? stableObservations + 1 : 0
                previousFrame = frame
                if stableObservations >= 2 {
                    let content = try await SCShareableContent.currentProcess
                    if let captured = content.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber)
                            && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    }), window.frame == frame { return captured }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        private func recordWindowState() {
            guard let window else { return }
            output?.recordWindowState(uptime: ProcessInfo.processInfo.systemUptime, metrics: [
                "key": window.isKeyWindow ? 1 : 0, "visible": window.isVisible ? 1 : 0,
                "active_space": window.isOnActiveSpace ? 1 : 0,
                "occlusion_visible": window.occlusionState.contains(.visible) ? 1 : 0,
                "miniaturized": window.isMiniaturized ? 1 : 0,
                "application_active": NSApp.isActive ? 1 : 0, "application_hidden": NSApp.isHidden ? 1 : 0,
                "window_x": window.frame.minX, "window_y": window.frame.minY,
                "window_width": window.frame.width, "window_height": window.frame.height,
                "backing_scale": window.backingScaleFactor
            ])
        }

        private func stop() async {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
            spaceObserver = nil
            if let stream { try? await stream.stopCapture() }
            await output?.finish()
            stream = nil
            output = nil
            CommandWindowCapture.session = nil
            if !started { CommandWindowCapture.attempted = false }
        }
    }

    /// Mutable writer state is confined to `queue`, including delegate errors
    /// and finalization. No file access or pixel copying runs on MainActor.
    private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "com.patinasystems.spooky.window-capture", qos: .utility)
        private let directory: URL
        private let width: Int
        private let height: Int
        private let region: String
        private let videoEnabled: Bool
        private let onStop: @Sendable () -> Void
        private let geometry: [String: Double]
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var metadata: FileHandle?
        private var pixels: FileHandle?
        private var roi: CGRect?
        private var previousPixels: Data?
        private var pixelOffset: UInt64 = 0
        private var previousOffset: UInt64?
        private var frameIndex = 0
        private var encodedFrames = 0
        private var firstPTS: CMTime?
        private var finished = false
        private var timebase = mach_timebase_info_data_t()
        private let rawLimit: UInt64 = 128 * 1024 * 1024

        init(directory: URL, width: Int, height: Int, region: String, geometry: [String: Double], videoEnabled: Bool,
             onStop: @escaping @Sendable () -> Void) {
            self.directory = directory
            self.width = width
            self.height = height
            self.region = region
            self.videoEnabled = videoEnabled
            self.onStop = onStop
            self.geometry = geometry
            super.init()
        }

        func prepare() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        self.roi = Self.parseRegion(self.region, width: self.width, height: self.height)
                        // Raw-only recording must contain pixels. Reject a missing or
                        // invalid ROI before creating any files rather than silently
                        // producing a metadata-only diagnostic.
                        guard self.videoEnabled || self.roi != nil else {
                            throw CocoaError(.validationMissingMandatoryProperty)
                        }
                        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                                attributes: [.posixPermissions: 0o700])
                        let movie = self.directory.appendingPathComponent("window.mov")
                        guard !FileManager.default.fileExists(atPath: movie.path) else {
                            throw CocoaError(.fileWriteFileExists)
                        }
                        self.metadata = try self.newFile("frames.jsonl")
                        self.pixels = try self.newFile("roi.bgra")
                        mach_timebase_info(&self.timebase)
                        if self.videoEnabled { try self.prepareVideo(at: movie) }
                        self.write(["kind": "header", "schema": 1, "width": self.width, "height": self.height,
                            "scope": "Own-window WindowServer pixels, not physical display scanout",
                            "pixel_format": "BGRA8", "raw_roi": self.roi.map(Self.rect) ?? [],
                            "mach_numer": self.timebase.numer, "mach_denom": self.timebase.denom,
                            "raw_limit_bytes": self.rawLimit, "minimum_frame_interval": 0, "window_geometry": self.geometry,
                            "video_enabled": self.videoEnabled, "pid": ProcessInfo.processInfo.processIdentifier])
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }

        private func prepareVideo(at movie: URL) throws {
            let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoEncoderSpecificationKey: [
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
                ],
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 60]
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CocoaError(.featureUnsupported) }
            writer.add(input)
            self.writer = writer
            self.input = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        }

        private func newFile(_ name: String) throws -> FileHandle {
            let url = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path),
                  FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteFileExists)
            }
            return try FileHandle(forWritingTo: url)
        }

        func recordWindowState(uptime: Double, metrics: [String: Double]) {
            queue.async {
                guard !self.finished else { return }
                self.write(["kind": "window_state", "uptime_s": uptime, "metrics": metrics])
            }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard !finished, type == .screen, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]], let info = attachments.first else { return }
            let status = (info[.status] as? NSNumber)?.intValue ?? -1
            let ticks = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
            let pts = sampleBuffer.presentationTimeStamp
            var record: [String: Any] = ["kind": "frame", "i": frameIndex, "status": status,
                "display_time_ticks": ticks, "display_uptime_s": Double(ticks) * Double(timebase.numer)
                    / Double(timebase.denom) / 1_000_000_000,
                "source_pts_s": pts.seconds, "callback_uptime_s": ProcessInfo.processInfo.systemUptime]
            frameIndex += 1
            guard status == SCFrameStatus.complete.rawValue, let buffer = sampleBuffer.imageBuffer else {
                write(record)
                return
            }
            if firstPTS == nil {
                firstPTS = pts
                if videoEnabled {
                    guard writer?.startWriting() == true else { writeFailure("writer_start"); return }
                    writer?.startSession(atSourceTime: .zero)
                }
            }
            let relative = CMTimeSubtract(pts, firstPTS ?? pts)
            // Retain this timeline coordinate in raw-only recordings so existing
            // frame analysis stays compatible. Latency uses display_uptime_s.
            record["video_pts_s"] = relative.seconds
            let appended = videoEnabled && input?.isReadyForMoreMediaData == true
                && adaptor?.append(buffer, withPresentationTime: relative) == true
            record["video_written"] = appended
            if appended { record["video_frame"] = encodedFrames; encodedFrames += 1 }
            if let roi { recordROI(buffer, region: roi, record: &record) }
            if let rect = Self.attachmentRect(info[.contentRect]) { record["content_rect"] = Self.rect(rect) }
            if let scale = info[.scaleFactor] as? NSNumber { record["scale_factor"] = scale }
            if let scale = info[.contentScale] as? NSNumber { record["content_scale"] = scale }
            write(record)
            if frameIndex.isMultiple(of: 30) {
                let size = videoEnabled ? (try? directory.appendingPathComponent("window.mov")
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 : 0
                if UInt64(size) + pixelOffset >= 256 * 1024 * 1024 { writeFailure("file_budget"); return }
            }
        }

        private func recordROI(_ buffer: CVPixelBuffer, region: CGRect, record: inout [String: Any]) {
            guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
                record["roi_unavailable"] = "dimensions_changed"
                return
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let rowBytes = Int(region.width) * 4
            var data = Data(capacity: rowBytes * Int(region.height))
            for y in Int(region.minY)..<Int(region.maxY) {
                data.append(base.advanced(by: y * stride + Int(region.minX) * 4)
                    .assumingMemoryBound(to: UInt8.self), count: rowBytes)
            }
            if data == previousPixels, let previousOffset {
                record["roi_offset"] = previousOffset
                record["roi_bytes"] = data.count
                record["roi_changed"] = false
            } else if pixelOffset + UInt64(data.count) <= rawLimit {
                do {
                    try pixels?.write(contentsOf: data)
                    record["roi_offset"] = pixelOffset
                    record["roi_bytes"] = data.count
                    record["roi_changed"] = true
                    previousOffset = pixelOffset
                    pixelOffset += UInt64(data.count)
                    previousPixels = data
                } catch { writeFailure("roi_write") }
            } else { record["roi_unavailable"] = "raw_budget" }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            queue.async { self.writeFailure("stream_error") }
        }

        private func writeFailure(_ reason: String) {
            write(["kind": "error", "reason": reason])
            onStop()
        }

        private func write(_ record: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            do { try metadata?.write(contentsOf: data + Data([10])) } catch { onStop() }
        }

        func finish() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    guard !self.finished else { continuation.resume(); return }
                    self.finished = true
                    guard let writer = self.writer, writer.status == .writing else {
                        self.closeFiles()
                        continuation.resume()
                        return
                    }
                    self.input?.markAsFinished()
                    writer.finishWriting {
                        self.queue.async {
                            self.closeFiles()
                            continuation.resume()
                        }
                    }
                }
            }
        }

        private func closeFiles() {
            write(["kind": "summary", "frames": frameIndex, "encoded_frames": encodedFrames,
                   "raw_bytes": pixelOffset, "video_enabled": videoEnabled,
                   "writer_status": writer?.status.rawValue ?? -1])
            try? metadata?.close()
            try? pixels?.close()
        }

        private static func parseRegion(_ value: String, width: Int, height: Int) -> CGRect? {
            let fields = value.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let parts = fields.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, parts[0] >= 0, parts[1] >= 0, parts[2] > 0, parts[3] > 0,
                  parts[2] <= width, parts[3] <= height, parts[0] <= width - parts[2],
                  parts[1] <= height - parts[3], parts[2] * parts[3] <= 2_097_152 else { return nil }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }

        private static func attachmentRect(_ value: Any?) -> CGRect? {
            if let rect = value as? CGRect { return rect }
            if let dictionary = value as? [String: Any] {
                return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            }
            return nil
        }

        private static func rect(_ value: CGRect) -> [Double] {
            [value.origin.x, value.origin.y, value.width, value.height]
        }
    }
}
#endif
