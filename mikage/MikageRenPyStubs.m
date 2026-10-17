// Objective-C classes Ren'Py looks up through pyobjus on iOS. Ren'Py's own
// iOS project (renpy-build) provides them; Mikage has no App Store purchases
// or age range, so these report that neither is available.

#import <Foundation/Foundation.h>

// renpy/common/00iap.rpy resolves this class at init on every iOS game.
@interface IAPHelper : NSObject
@property (nonatomic, strong) NSArray *productIdentifiers;
@property (nonatomic, copy) NSString *dialogTitle;
@property (nonatomic) BOOL finished;
- (BOOL)canMakePayments;
- (void)validateProductIdentifiers;
- (void)validateProductIdentifiersInBackground;
- (void)beginPurchase:(NSString *)identifier;
- (void)restorePurchases;
- (BOOL)hasPurchased:(NSString *)identifier;
- (BOOL)hasPurchasedConsumable:(NSString *)identifier;
- (BOOL)isDeferred:(NSString *)identifier;
- (NSString *)formatPrice:(NSString *)identifier;
- (void)requestReview;
@end

@implementation IAPHelper
- (instancetype)init {
    if ((self = [super init])) {
        _finished = YES;
    }
    return self;
}
- (BOOL)canMakePayments { return NO; }
- (void)validateProductIdentifiers { self.finished = YES; }
- (void)validateProductIdentifiersInBackground {}
- (void)beginPurchase:(NSString *)identifier { self.finished = YES; }
- (void)restorePurchases { self.finished = YES; }
- (BOOL)hasPurchased:(NSString *)identifier { return NO; }
- (BOOL)hasPurchasedConsumable:(NSString *)identifier { return NO; }
- (BOOL)isDeferred:(NSString *)identifier { return NO; }
- (NSString *)formatPrice:(NSString *)identifier { return nil; }
- (void)requestReview {}
@end

// renpy.exports.get_age_range() on iOS.
@interface Age : NSObject
@property (class, nonatomic, readonly) BOOL valid;
@property (class, nonatomic, readonly) BOOL inProgress;
@property (class, nonatomic, readonly) NSInteger ageLower;
@property (class, nonatomic, readonly) NSInteger ageUpper;
+ (void)update;
@end

@implementation Age
+ (BOOL)valid { return NO; }
+ (BOOL)inProgress { return NO; }
+ (NSInteger)ageLower { return 0; }
+ (NSInteger)ageUpper { return 0; }
+ (void)update {}
@end
