import Foundation

public struct RoomOptions {
    // default options for capturing
    public var defaultVideoCaptureOptions: VideoCaptureOptions
    public var defaultAudioCaptureOptions: AudioCaptureOptions
    // default options for publishing
    public var defaultVideoPublishOptions: VideoPublishOptions
    public var defaultAudioPublishOptions: AudioPublishOptions

    public var stopLocalTrackOnUnpublish: Bool

    public init(defaultVideoCaptureOptions: VideoCaptureOptions = VideoCaptureOptions(),
                defaultAudioCaptureOptions: AudioCaptureOptions = AudioCaptureOptions(),
                defaultVideoPublishOptions: VideoPublishOptions = VideoPublishOptions(),
                defaultAudioPublishOptions: AudioPublishOptions = AudioPublishOptions(),
                stopLocalTrackOnUnpublish: Bool = true) {

        self.defaultVideoCaptureOptions = defaultVideoCaptureOptions
        self.defaultAudioCaptureOptions = defaultAudioCaptureOptions
        self.defaultVideoPublishOptions = defaultVideoPublishOptions
        self.defaultAudioPublishOptions = defaultAudioPublishOptions
        self.stopLocalTrackOnUnpublish = stopLocalTrackOnUnpublish
    }
}
