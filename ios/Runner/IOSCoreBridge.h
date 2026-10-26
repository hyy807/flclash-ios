#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IOSCoreResultHandler)(NSString *_Nullable result);

@interface IOSCoreBridge : NSObject

+ (void)invokeMethod:(NSString *)methodCall result:(IOSCoreResultHandler)result;
+ (void)setEventListener:(IOSCoreResultHandler _Nullable)listener;

/// The entitlements this process is actually signed with.
///
/// The embedded profile says what the App ID *may* use; the code signature says
/// what the app *got*. NetworkExtension refuses to answer when those disagree,
/// which looks like a saveToPreferences that never calls back. SecTask is not
/// public on iOS, but it is the only way to read the effective set from inside
/// the app.
+ (NSString *)effectiveEntitlements;

@end

NS_ASSUME_NONNULL_END
