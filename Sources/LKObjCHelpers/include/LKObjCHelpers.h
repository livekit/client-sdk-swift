#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>

@interface LKObjCHelpers : NSObject

#pragma clang diagnostic push
// RPBroadcastSampleHandler is deprecated in the iOS 27 SDK; suppress so the module still builds (#1037).
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (void)finishBroadcastWithoutError:(RPBroadcastSampleHandler *)handler API_AVAILABLE(ios(10.0), macCatalyst(13.1), macos(11.0), tvos(10.0));
#pragma clang diagnostic pop

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end
