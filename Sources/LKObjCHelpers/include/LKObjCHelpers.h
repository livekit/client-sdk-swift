#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>

@interface LKObjCHelpers : NSObject

+ (void)finishBroadcastWithoutError:(RPBroadcastSampleHandler *)handler API_AVAILABLE(ios(10.0), macCatalyst(13.1), macos(11.0), tvos(10.0));

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end
