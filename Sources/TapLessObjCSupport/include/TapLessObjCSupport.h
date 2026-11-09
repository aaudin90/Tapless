#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Домен ошибки, в которую превращается исключение Objective-C.
extern NSErrorDomain const TLExceptionErrorDomain;
/// Ключи `userInfo` ошибки: имя исключения и его причина.
extern NSErrorUserInfoKey const TLExceptionNameKey;
extern NSErrorUserInfoKey const TLExceptionReasonKey;

/// Swift не ловит `NSException`: она пролетает через его кадры и роняет приложение (так делает AVFAudio,
/// например `installTap` с «Format mismatch»). Этот класс выполняет блок под `@try` / `@catch`.
@interface TLExceptionGuard : NSObject

/// Выполняет блок. Если он бросил `NSException`, возвращает NO и ошибку с именем и причиной исключения.
+ (BOOL)runGuarded:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
