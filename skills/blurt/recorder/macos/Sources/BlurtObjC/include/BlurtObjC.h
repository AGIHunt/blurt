// Objective-C exceptions Swift cannot catch: AVFoundation raises NSException for conditions it calls programmer
// errors (a tap whose format no longer matches the input hardware, after a Bluetooth headset switched profiles or the
// input device changed under a prepared engine). Uncaught, they abort the app. BlurtTry runs the block and hands the
// exception back as an NSError (domain "BlurtObjCException", userInfo name / reason) instead.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when the block ran without raising; otherwise NO, with `error` describing the exception.
BOOL BlurtTry(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
