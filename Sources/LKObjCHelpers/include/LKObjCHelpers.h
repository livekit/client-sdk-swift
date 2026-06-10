#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_OSX
#import <ScreenCaptureKit/ScreenCaptureKit.h>
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

#if TARGET_OS_OSX
+ (void)setWidth:(size_t)width height:(size_t)height onConfiguration:(SCStreamConfiguration *)configuration API_AVAILABLE(macos(12.3));
#endif

@end
