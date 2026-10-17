#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SouloExtensionURLOpener : NSObject
/// YES means a URL-opening request was dispatched, not that the app is foreground.
+ (BOOL)requestOpenURL:(NSURL *)url
        fromResponder:(UIResponder *)responder NS_SWIFT_NAME(requestOpen(_:from:));
@end

NS_ASSUME_NONNULL_END
