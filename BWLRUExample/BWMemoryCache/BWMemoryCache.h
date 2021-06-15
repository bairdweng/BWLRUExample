//
//  BWMemoryCache.h
//  BWLRUExample
//
//  Created by bairdweng on 2021/6/15.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BWMemoryCache : NSObject
/// 缓存名称
@property (nullable, copy) NSString *name;
/// 缓存中的对象数量
@property (readonly) NSUInteger totalCount;
@property (readonly) NSUInteger totalCost;

@property NSUInteger countLimit;

@property NSUInteger costLimit;

@property NSTimeInterval ageLimit;

@property NSTimeInterval autoTrimInterval;

@property BOOL shouldRemoveAllObjectsOnMemoryWarning;
@property BOOL shouldRemoveAllObjectsWhenEnteringBackground;

@property (nullable, copy) void (^didReceiveMemoryWarningBlock)(BWMemoryCache *cache);


@property (nullable, copy) void (^didEnterBackgroundBlock)(BWMemoryCache *cache);

@property BOOL releaseOnMainThread;

@property BOOL releaseAsynchronously;


#pragma mark - Access Methods

- (BOOL)containsObjectForKey:(id)key;

- (nullable id)objectForKey:(id)key;

- (void)setObject:(nullable id)object forKey:(id)key;

- (void)setObject:(nullable id)object forKey:(id)key withCost:(NSUInteger)cost;

- (void)removeObjectForKey:(id)key;

- (void)removeAllObjects;


#pragma mark - Trim

- (void)trimToCount:(NSUInteger)count;


- (void)trimToCost:(NSUInteger)cost;

- (void)trimToAge:(NSTimeInterval)age;

@end

NS_ASSUME_NONNULL_END
