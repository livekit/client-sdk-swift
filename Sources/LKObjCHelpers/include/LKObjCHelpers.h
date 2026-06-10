#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

// ScreenCaptureKit ships on macOS, and on iOS/tvOS as of the 27.0 SDK. `width`/`height` are
// unavailable on visionOS, so the size setter below is not offered there.
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>) && !TARGET_OS_VISION
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#define LK_SUPPORTS_SCSTREAM_SIZE 1
#endif

@interface LKObjCHelpers : NSObject

#pragma clang diagnostic push
// RPBroadcastSampleHandler is deprecated in the iOS 27 SDK; suppress so the module still builds (#1037).
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (void)finishBroadcastWithoutError:(RPBroadcastSampleHandler *)handler API_AVAILABLE(ios(10.0), macCatalyst(13.1), macos(11.0), tvos(10.0));
#pragma clang diagnostic pop

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

// MARK: - Xcode 27 availability workarounds
// The macOS 27 SDK bumped these APIs past the OS versions they actually ship in (only the Swift
// importer enforces it). Reaching them from ObjC keeps full behavior on every SDK/OS version (#1035).

+ (AUAudioFrameCount)maximumFramesToRenderForNode:(AVAudioNode *)node;

+ (void)setMaximumFramesToRender:(AUAudioFrameCount)maximumFramesToRender forNode:(AVAudioNode *)node;

#ifdef LK_SUPPORTS_SCSTREAM_SIZE
+ (void)setWidth:(size_t)width height:(size_t)height onConfiguration:(SCStreamConfiguration *)configuration API_AVAILABLE(macos(12.3), macCatalyst(18.2), ios(27.0), tvos(27.0));
#endif

@end
