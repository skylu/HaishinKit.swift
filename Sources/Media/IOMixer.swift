import AVFoundation
#if canImport(SwiftPMSupport)
import SwiftPMSupport
#endif
#if os(iOS)
import UIKit
#endif

protocol IOMixerDelegate: AnyObject {
    func mixer(_ mixer: IOMixer, didOutput audio: AVAudioPCMBuffer, presentationTimeStamp: CMTime)
    func mixer(_ mixer: IOMixer, didOutput video: CMSampleBuffer)
    #if os(iOS)
    func mixer(_ mixer: IOMixer, sessionWasInterrupted session: AVCaptureSession, reason: AVCaptureSession.InterruptionReason?)
    func mixer(_ mixer: IOMixer, sessionInterruptionEnded session: AVCaptureSession)
    #endif
}

/// An object that mixies audio and video for streaming.
public class IOMixer {
    /// The default fps for an IOMixer, value is 30.
    public static let defaultFrameRate: Float64 = 30
    /// The AVAudioEngine shared instance holder.
    public static let audioEngineHolder: InstanceHolder<AVAudioEngine> = .init {
        return AVAudioEngine()
    }

    enum ReadyState {
        case standby
        case encoding
        case decoding
    }

    public var hasVideo: Bool {
        get {
            mediaLink.hasVideo
        }
        set {
            mediaLink.hasVideo = newValue
        }
    }

    public var isPaused: Bool {
        get {
            mediaLink.isPaused
        }
        set {
            mediaLink.isPaused = newValue
        }
    }

    #if os(tvOS)
    private var _session: Any?
    /// The capture session instance.
    @available(tvOS 17.0, *)
    public var session: AVCaptureSession {
        get {
            if _session == nil {
                _session = makeSession()
            }
            return _session as! AVCaptureSession
        }
        set {
            _session = newValue
        }
    }
    #else
    /// The capture session instance.
    public internal(set) lazy var session: AVCaptureSession = makeSession() {
        didSet {
            if oldValue.isRunning {
                removeSessionObservers(oldValue)
                oldValue.stopRunning()
            }
            audioIO.capture.detachSession(oldValue)
            videoIO.capture.detachSession(oldValue)
            if session.canSetSessionPreset(sessionPreset) {
                session.sessionPreset = sessionPreset
            }
            audioIO.capture.attachSession(session)
            videoIO.capture.attachSession(session)
        }
    }
    #endif

    public private(set) var isRunning: Atomic<Bool> = .init(false)
    /// The recorder instance.
    public lazy var recorder = IORecorder()

    /// Specifies the drawable object.
    public weak var drawable: (any NetStreamDrawable)? {
        get {
            videoIO.drawable
        }
        set {
            videoIO.drawable = newValue
        }
    }

    weak var delegate: (any IOMixerDelegate)?

    lazy var audioIO: IOAudioUnit = {
        var audioIO = IOAudioUnit()
        audioIO.mixer = self
        return audioIO
    }()

    lazy var videoIO: IOVideoUnit = {
        var videoIO = IOVideoUnit()
        videoIO.mixer = self
        return videoIO
    }()

    lazy var mediaLink: MediaLink = {
        var mediaLink = MediaLink()
        mediaLink.delegate = self
        return mediaLink
    }()

    var audioFormat: AVAudioFormat? {
        didSet {
            guard let audioEngine else {
                return
            }
            nstry({
                if let audioFormat = self.audioFormat {
                    audioEngine.connect(self.mediaLink.playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
                } else {
                    audioEngine.disconnectNodeInput(self.mediaLink.playerNode)
                }
            }, { exeption in
                logger.warn(exeption)
            })
        }
    }

    var isMultiCamSessionEnabled = false {
        didSet {
            guard oldValue != isMultiCamSessionEnabled else {
                return
            }
            #if os(iOS)
            session = makeSession()
            #endif
        }
    }

    #if os(tvOS)
    private var _sessionPreset: Any?
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset {
        get {
            if _sessionPreset == nil {
                _sessionPreset = AVCaptureSession.Preset.default
            }
            return _sessionPreset as! AVCaptureSession.Preset
        }
        set {
            guard sessionPreset != newValue, session.canSetSessionPreset(newValue) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = newValue
            session.commitConfiguration()
        }
    }
    #else
    var sessionPreset: AVCaptureSession.Preset = .default {
        didSet {
            guard sessionPreset != oldValue, session.canSetSessionPreset(sessionPreset) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = sessionPreset
            session.commitConfiguration()
        }
    }
    #endif

    var inBackgroundMode = false {
        didSet {
            if #available(tvOS 17.0, *) {
                guard inBackgroundMode != oldValue else {
                    return
                }
                if inBackgroundMode {
                    if !session.isMultitaskingCameraAccessEnabled {
                        videoIO.multiCamCapture.detachSession(session)
                        videoIO.capture.detachSession(session)
                    }
                } else {
                    startCaptureSessionIfNeeded()
                    if !session.isMultitaskingCameraAccessEnabled {
                        videoIO.capture.attachSession(session)
                        videoIO.multiCamCapture.attachSession(session)
                    }
                }
            }
        }
    }

    private var readyState: ReadyState = .standby
    private(set) lazy var audioEngine: AVAudioEngine? = {
        return IOMixer.audioEngineHolder.retain()
    }()

    deinit {
        if #available(tvOS 17.0, *) {
            if session.isRunning {
                session.stopRunning()
            }
        }
        IOMixer.audioEngineHolder.release(audioEngine)
    }

    /// Append a CMSampleBuffer with media type.
    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        switch readyState {
        case .encoding:
            break
        case .decoding:
            switch sampleBuffer.formatDescription?._mediaType {
            case kCMMediaType_Audio:
                audioIO.codec.appendSampleBuffer(sampleBuffer)
            case kCMMediaType_Video:
                videoIO.codec.formatDescription = sampleBuffer.formatDescription
                videoIO.codec.appendSampleBuffer(sampleBuffer)
            default:
                break
            }
        case .standby:
            break
        }
    }

    #if os(iOS) || os(tvOS)
    @available(tvOS 17.0, *)
    private func makeSession() -> AVCaptureSession {
        let session: AVCaptureSession
        if isMultiCamSessionEnabled, #available(iOS 13.0, *) {
            session = AVCaptureMultiCamSession()
        } else {
            session = AVCaptureSession()
        }
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        return session
    }
    #else
    private func makeSession() -> AVCaptureSession {
        let session = AVCaptureSession()
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        return session
    }
    #endif
}

extension IOMixer: IOUnitEncoding {
    /// Starts encoding for video and audio data.
    public func startEncoding(_ delegate: any AVCodecDelegate) {
        guard readyState == .standby else {
            return
        }
        readyState = .encoding
        videoIO.startEncoding(delegate)
        audioIO.startEncoding(delegate)
    }

    /// Stop encoding.
    public func stopEncoding() {
        guard readyState == .encoding else {
            return
        }
        videoIO.stopEncoding()
        audioIO.stopEncoding()
        readyState = .standby
    }
}

extension IOMixer: IOUnitDecoding {
    /// Starts decoding for video and audio data.
    public func startDecoding() {
        guard readyState == .standby else {
            return
        }
        audioIO.startDecoding()
        videoIO.startDecoding()
        mediaLink.startRunning()
        readyState = .decoding
    }

    /// Stop decoding.
    public func stopDecoding() {
        guard readyState == .decoding else {
            return
        }
        mediaLink.stopRunning()
        audioIO.stopDecoding()
        videoIO.stopDecoding()
        readyState = .standby
    }
}

extension IOMixer: MediaLinkDelegate {
    // MARK: MediaLinkDelegate
    func mediaLink(_ mediaLink: MediaLink, dequeue sampleBuffer: CMSampleBuffer) {
        delegate?.mixer(self, didOutput: sampleBuffer)
        drawable?.enqueue(sampleBuffer)
    }

    func mediaLink(_ mediaLink: MediaLink, didBufferingChanged: Bool) {
        logger.info(didBufferingChanged)
    }
}

extension IOMixer: Running {
    // MARK: Running
    public func startRunning() {
        guard !isRunning.value else {
            return
        }
        if #available(tvOS 17.0, *) {
            addSessionObservers(session)
            session.startRunning()
            isRunning.mutate { $0 = session.isRunning }
        }
    }

    public func stopRunning() {
        guard isRunning.value else {
            return
        }
        if #available(tvOS 17.0, *) {
            removeSessionObservers(session)
            session.stopRunning()
            isRunning.mutate { $0 = session.isRunning }
        }
    }

    @available(tvOS 17.0, *)
    func startCaptureSessionIfNeeded() {
        guard isRunning.value && !session.isRunning else {
            return
        }
        session.startRunning()
        isRunning.mutate { $0 = session.isRunning }
    }

    @available(tvOS 17.0, *)
    private func addSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        #endif
    }

    @available(tvOS 17.0, *)
    private func removeSessionObservers(_ session: AVCaptureSession) {
        #if os(iOS)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
        #endif
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
    }

    @available(tvOS 17.0, *)
    @objc
    private func sessionRuntimeError(_ notification: NSNotification) {
        guard
            let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        let error = AVError(_nsError: errorValue)
        switch error.code {
        case .unsupportedDeviceActiveFormat:
            #if os(iOS)
            let isMultiCamSupported: Bool
            if #available(iOS 13.0, *) {
                isMultiCamSupported = session is AVCaptureMultiCamSession
            } else {
                isMultiCamSupported = false
            }
            #else
            let isMultiCamSupported = true
            #endif
            guard let device = error.device, let format = device.videoFormat(
                width: sessionPreset.width ?? Int32(videoIO.codec.settings.videoSize.width),
                height: sessionPreset.height ?? Int32(videoIO.codec.settings.videoSize.height),
                frameRate: videoIO.frameRate,
                isMultiCamSupported: isMultiCamSupported
            ), device.activeFormat != format else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                if format.isFrameRateSupported(videoIO.frameRate) {
                    device.activeVideoMinFrameDuration = CMTime(value: 100, timescale: CMTimeScale(100 * videoIO.frameRate))
                    device.activeVideoMaxFrameDuration = CMTime(value: 100, timescale: CMTimeScale(100 * videoIO.frameRate))
                }
                device.unlockForConfiguration()
                session.startRunning()
            } catch {
                logger.warn(error)
            }
        #if os(iOS)
        case .mediaServicesWereReset:
            startCaptureSessionIfNeeded()
        #endif
        default:
            break
        }
    }

    #if os(iOS)
    @objc
    private func sessionWasInterrupted(_ notification: Notification) {
        guard let session = notification.object as? AVCaptureSession else {
            return
        }
        guard let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
              let reasonIntegerValue = userInfoValue.integerValue,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) else {
            delegate?.mixer(self, sessionWasInterrupted: session, reason: nil)
            return
        }
        delegate?.mixer(self, sessionWasInterrupted: session, reason: reason)
    }

    @objc
    private func sessionInterruptionEnded(_ notification: Notification) {
        delegate?.mixer(self, sessionInterruptionEnded: session)
    }
    #endif
}
