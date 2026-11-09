#import "TapLessObjCSupport.h"

NSErrorDomain const TLExceptionErrorDomain = @"io.github.aaudin90.tapless.objc-exception";
NSErrorUserInfoKey const TLExceptionNameKey = @"TLExceptionName";
NSErrorUserInfoKey const TLExceptionReasonKey = @"TLExceptionReason";

@implementation TLExceptionGuard

+ (BOOL)runGuarded:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *name = exception.name ?: @"";
            NSString *reason = exception.reason ?: @"";
            *error = [NSError errorWithDomain:TLExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", name, reason],
                TLExceptionNameKey: name,
                TLExceptionReasonKey: reason,
            }];
        }
        return NO;
    }
}

@end
