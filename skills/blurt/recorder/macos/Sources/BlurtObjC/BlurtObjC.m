#import "BlurtObjC.h"

BOOL BlurtTry(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"BlurtObjCException" code:1
                                     userInfo:@{@"name": e.name ?: @"", @"reason": e.reason ?: @"",
                                                NSLocalizedDescriptionKey: e.reason ?: e.name ?: @"exception"}];
        }
        return NO;
    }
}
