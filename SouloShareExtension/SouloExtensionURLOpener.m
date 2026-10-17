#import "SouloExtensionURLOpener.h"

typedef void (*SouloOpenURLMethod)(id, SEL, NSURL *, id, void (^)(BOOL));

@implementation SouloExtensionURLOpener

+ (BOOL)requestOpenURL:(NSURL *)url fromResponder:(UIResponder *)responder {
    if (!NSThread.isMainThread || ![url.scheme.lowercaseString isEqualToString:@"soulo"] ||
        ![url.host.lowercaseString isEqualToString:@"action"]) {
        return NO;
    }

    // Chromium's Open in extension uses this public selector on the responder
    // chain instead of NSExtensionContext.open. No sharedApplication lookup or
    // private selector is used. Availability is checked on each host at runtime.
    // https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/common/extension_open_url.mm
    SEL selector = NSSelectorFromString(@"openURL:options:completionHandler:");
    UIResponder *candidate = responder.nextResponder;
    for (NSUInteger depth = 0; candidate && depth < 64; depth++, candidate = candidate.nextResponder) {
        if (![candidate respondsToSelector:selector]) { continue; }
        NSMethodSignature *signature = [candidate methodSignatureForSelector:selector];
        if (signature.numberOfArguments != 5 || signature.methodReturnType[0] != 'v' ||
            [signature getArgumentTypeAtIndex:2][0] != '@' ||
            [signature getArgumentTypeAtIndex:3][0] != '@' ||
            [signature getArgumentTypeAtIndex:4][0] != '@') {
            continue;
        }
        IMP implementation = [candidate methodForSelector:selector];
        if (!implementation) { continue; }
        // UIScene and UIApplication expose the same selector but accept
        // different options objects. Both document nil as the default options;
        // a dictionary here would crash when the responder is a UIScene.
        ((SouloOpenURLMethod)implementation)(candidate, selector, url, nil, nil);
        return YES;
    }
    return NO;
}

@end
