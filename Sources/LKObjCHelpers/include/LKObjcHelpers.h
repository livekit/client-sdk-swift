#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>

@interface LKObjCHelpers : NSObject

+ (void)finishBroadcastWithoutError:(RPBroadcastSampleHandler *)handler API_AVAILABLE(macos(11.0));

@end
