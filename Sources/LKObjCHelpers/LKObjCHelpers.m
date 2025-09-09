#import "LKObjCHelpers.h"

@implementation LKObjCHelpers

NS_ASSUME_NONNULL_BEGIN

+ (void)finishBroadcastWithoutError:(RPBroadcastSampleHandler *)handler API_AVAILABLE(ios(10.0), macCatalyst(13.1), macos(11.0), tvos(10.0)) {
    // Call finishBroadcastWithError with nil error, which ends the broadcast without an error popup
    // This is unsupported/undocumented but appears to work and is preferable to an error dialog with a cryptic default message
    // See https://stackoverflow.com/a/63402492 for more discussion
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wnonnull"
    [handler finishBroadcastWithError:nil];
    #pragma clang diagnostic pop
}

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        *error = [[NSError alloc] initWithDomain:exception.name code:0 userInfo:exception.userInfo];
        return NO;
    }
}

NS_ASSUME_NONNULL_END

@end
