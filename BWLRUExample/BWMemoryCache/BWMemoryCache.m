//
//  BWMemoryCache.m
//  BWLRUExample
//
//  Created by bairdweng on 2021/6/15.
//

#import "BWMemoryCache.h"
#import <pthread.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue() {
	return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

/**
   双向链表
 */
@interface _YYLinkedMapNode : NSObject {
	@package
	__unsafe_unretained _YYLinkedMapNode *_prev; // retained by dic
	__unsafe_unretained _YYLinkedMapNode *_next; // retained by dic
	id _key;
	id _value;
	NSUInteger _cost;
	NSTimeInterval _time;
}
@end

@implementation _YYLinkedMapNode
@end

@interface _YYLinkedMap : NSObject {
	@package
	// 用字典保存所有节点_YYLinkedMapNode (为什么不用oc字典?因为用CFMutableDictionaryRef效率高，毕竟基于c)
	CFMutableDictionaryRef _dic;
	// 总缓存开销
	NSUInteger _totalCost;
	// 总缓存数量
	NSUInteger _totalCount;
	// 链表头节点
	_YYLinkedMapNode *_head;
	// 链表尾节点
	_YYLinkedMapNode *_tail;
	// 是否在主线程上，异步释放 _YYLinkedMapNode对象
	BOOL _releaseOnMainThread;
	// 是否异步释放 _YYLinkedMapNode对象
	BOOL _releaseAsynchronously;
}

// 添加节点到链表头节点
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node;

// 移动当前节点到链表头节点
- (void)bringNodeToHead:(_YYLinkedMapNode *)node;

// 移除链表节点
- (void)removeNode:(_YYLinkedMapNode *)node;

// 移除链表尾节点(如果存在)
- (_YYLinkedMapNode *)removeTailNode;

// 移除所有缓存
- (void)removeAll;

@end

@implementation _YYLinkedMap

- (instancetype)init {
	self = [super init];
	_dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	_releaseOnMainThread = NO;
	_releaseAsynchronously = YES;
	return self;
}

- (void)dealloc {
	CFRelease(_dic);
}

- (void)insertNodeAtHead:(_YYLinkedMapNode *)node {
	// 字典保存链表节点node
	CFDictionarySetValue(_dic, (__bridge const void *)(node->_key), (__bridge const void *)(node));
	// 叠加该缓存开销到总内存开销
	_totalCost += node->_cost;
	// 总缓存数+1
	_totalCount++;
	if (_head) {
		// 存在链表头，取代当前表头
		node->_next = _head;
		_head->_prev = node;
		// 重新赋值链表表头临时变量_head
		_head = node;
	} else {
		// 不存在链表头
		_head = _tail = node;
	}
}


// 移动当前节点到链表头节点
- (void)bringNodeToHead:(_YYLinkedMapNode *)node {
	// 当前节点已是链表头节点
	if (_head == node) return;

	if (_tail == node) {
		//**如果node是链表尾节点**

		// 把node指向的上一个节点赋值给链表尾节点
		_tail = node->_prev;
		// 把链表尾节点指向的下一个节点赋值nil
		_tail->_next = nil;
	} else {
		//**如果node是非链表尾节点和链表头节点**

		// 把node指向的上一个节点赋值給node指向的下一个节点node指向的上一个节点
		node->_next->_prev = node->_prev;
		// 把node指向的下一个节点赋值给node指向的上一个节点node指向的下一个节点
		node->_prev->_next = node->_next;
	}
	// 把链表头节点赋值给node指向的下一个节点
	node->_next = _head;
	// 把node指向的上一个节点赋值nil
	node->_prev = nil;
	// 把节点赋值给链表头节点的指向的上一个节点
	_head->_prev = node;
	_head = node;
}


// 移除节点
- (void)removeNode:(_YYLinkedMapNode *)node {
	// 从字典中移除node
	CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key));
	// 减掉总内存消耗
	_totalCost -= node->_cost;
	// // 总缓存数-1
	_totalCount--;
	// 重新连接链表
	if (node->_next) node->_next->_prev = node->_prev;
	if (node->_prev) node->_prev->_next = node->_next;
	if (_head == node) _head = node->_next;
	if (_tail == node) _tail = node->_prev;
}

// 移除尾节点(如果存在)
- (_YYLinkedMapNode *)removeTailNode {
	if (!_tail) return nil;
	// 拷贝一份要删除的尾节点指针
	_YYLinkedMapNode *tail = _tail;
	// 移除链表尾节点
	CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key));
	// 减掉总内存消耗
	_totalCost -= _tail->_cost;
	// 总缓存数-1
	_totalCount--;
	if (_head == _tail) {
		// 清除节点，链表上已无节点了
		_head = _tail = nil;
	} else {
		// 设倒数第二个节点为链表尾节点
		_tail = _tail->_prev;
		_tail->_next = nil;
	}
	// 返回完tail后_tail将会释放
	return tail;
}

// 移除所有缓存
- (void)removeAll {
	// 清空内存开销与缓存数量
	_totalCost = 0;
	_totalCount = 0;
	// 清空头尾节点
	_head = nil;
	_tail = nil;

	if (CFDictionaryGetCount(_dic) > 0) {
		// 拷贝一份字典
		CFMutableDictionaryRef holder = _dic;
		// 重新分配新的空间
		_dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

		if (_releaseAsynchronously) {
			// 异步释放缓存
			dispatch_queue_t queue = _releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
			dispatch_async(queue, ^{
				CFRelease(holder); // hold and release in specified queue
			});
		} else if (_releaseOnMainThread && !pthread_main_np()) {
			// 主线程上释放缓存
			dispatch_async(dispatch_get_main_queue(), ^{
				CFRelease(holder); // hold and release in specified queue
			});
		} else {
			// 同步释放缓存
			CFRelease(holder);
		}
	}
}

@end





@implementation BWMemoryCache {
	pthread_mutex_t _lock;
	_YYLinkedMap *_lru;
	dispatch_queue_t _queue;
}

#pragma mark-----无需关注内部方法------
- (void)_trimRecursively {
	__weak typeof(self) _self = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		__strong typeof(_self) self = _self;
		if (!self) return;
		[self _trimInBackground];
		[self _trimRecursively];
	});
}

- (void)_trimInBackground {
	dispatch_async(_queue, ^{
		[self _trimToCost:self->_costLimit];
		[self _trimToCount:self->_countLimit];
		[self _trimToAge:self->_ageLimit];
	});
}

- (void)_trimToCost:(NSUInteger)costLimit {
	BOOL finish = NO;
	pthread_mutex_lock(&_lock);
	if (costLimit == 0) {
		[_lru removeAll];
		finish = YES;
	} else if (_lru->_totalCost <= costLimit) {
		finish = YES;
	}
	pthread_mutex_unlock(&_lock);
	if (finish) return;

	NSMutableArray *holder = [NSMutableArray new];
	while (!finish) {
		if (pthread_mutex_trylock(&_lock) == 0) {
			if (_lru->_totalCost > costLimit) {
				_YYLinkedMapNode *node = [_lru removeTailNode];
				if (node) [holder addObject:node];
			} else {
				finish = YES;
			}
			pthread_mutex_unlock(&_lock);
		} else {
			usleep(10 * 1000); //10 ms
		}
	}
	if (holder.count) {
		dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
		dispatch_async(queue, ^{
			[holder count]; // release in queue
		});
	}
}

- (void)_trimToCount:(NSUInteger)countLimit {
	BOOL finish = NO;
	pthread_mutex_lock(&_lock);
	if (countLimit == 0) {
		[_lru removeAll];
		finish = YES;
	} else if (_lru->_totalCount <= countLimit) {
		finish = YES;
	}
	pthread_mutex_unlock(&_lock);
	if (finish) return;

	NSMutableArray *holder = [NSMutableArray new];
	while (!finish) {
		if (pthread_mutex_trylock(&_lock) == 0) {
			if (_lru->_totalCount > countLimit) {
				_YYLinkedMapNode *node = [_lru removeTailNode];
				if (node) [holder addObject:node];
			} else {
				finish = YES;
			}
			pthread_mutex_unlock(&_lock);
		} else {
			usleep(10 * 1000); //10 ms
		}
	}
	if (holder.count) {
		dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
		dispatch_async(queue, ^{
			[holder count]; // release in queue
		});
	}
}

- (void)_trimToAge:(NSTimeInterval)ageLimit {
	BOOL finish = NO;
	NSTimeInterval now = CACurrentMediaTime();
	pthread_mutex_lock(&_lock);
	if (ageLimit <= 0) {
		[_lru removeAll];
		finish = YES;
	} else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit) {
		finish = YES;
	}
	pthread_mutex_unlock(&_lock);
	if (finish) return;

	NSMutableArray *holder = [NSMutableArray new];
	while (!finish) {
		if (pthread_mutex_trylock(&_lock) == 0) {
			if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
				_YYLinkedMapNode *node = [_lru removeTailNode];
				if (node) [holder addObject:node];
			} else {
				finish = YES;
			}
			pthread_mutex_unlock(&_lock);
		} else {
			usleep(10 * 1000); //10 ms
		}
	}
	if (holder.count) {
		dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
		dispatch_async(queue, ^{
			[holder count]; // release in queue
		});
	}
}

- (void)_appDidReceiveMemoryWarningNotification {
	if (self.didReceiveMemoryWarningBlock) {
		self.didReceiveMemoryWarningBlock(self);
	}
	if (self.shouldRemoveAllObjectsOnMemoryWarning) {
		[self removeAllObjects];
	}
}

- (void)_appDidEnterBackgroundNotification {
	if (self.didEnterBackgroundBlock) {
		self.didEnterBackgroundBlock(self);
	}
	if (self.shouldRemoveAllObjectsWhenEnteringBackground) {
		[self removeAllObjects];
	}
}


#pragma mark -----------public------------


- (instancetype)init {
	self = super.init;
	pthread_mutex_init(&_lock, NULL);
	_lru = [_YYLinkedMap new];
	// 并发队列
	_queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);

	_countLimit = NSUIntegerMax;
	_costLimit = NSUIntegerMax;
	_ageLimit = DBL_MAX;
	_autoTrimInterval = 5.0;
	_shouldRemoveAllObjectsOnMemoryWarning = YES;
	_shouldRemoveAllObjectsWhenEnteringBackground = YES;

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidReceiveMemoryWarningNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidEnterBackgroundNotification) name:UIApplicationDidEnterBackgroundNotification object:nil];

	[self _trimRecursively];
	return self;
}


- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
	[_lru removeAll];
	pthread_mutex_destroy(&_lock);
}

#pragma mark Getter
// 查找缓存
- (id)objectForKey:(id)key {
	if (!key) return nil;
	// 加锁，防止资源竞争
	// 互斥锁。
	pthread_mutex_lock(&_lock);
	// _lru为链表_YYLinkedMap，全部节点存在_lru->_dic中
	// 获取节点
	_YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
	if (node) {
		//** 有对应缓存 **
		// 重新更新缓存时间
		node->_time = CACurrentMediaTime();
		// 把当前node移到链表表头(为什么移到表头？根据LRU淘汰算法:Cache的容量是有限的，当Cache的空间都被占满后，如果再次发生缓存失效，就必须选择一个缓存块来替换掉.LRU法是依据各块使用的情况， 总是选择那个最长时间未被使用的块替换。这种方法比较好地反映了程序局部性规律)
		[_lru bringNodeToHead:node];
	}
	// 解锁
	pthread_mutex_unlock(&_lock);
	// 有缓存则返回缓存值
	return node ? node->_value : nil;
}

- (NSUInteger)totalCount {
	pthread_mutex_lock(&_lock);
	NSUInteger count = _lru->_totalCount;
	pthread_mutex_unlock(&_lock);
	return count;
}

- (NSUInteger)totalCost {
	pthread_mutex_lock(&_lock);
	NSUInteger totalCost = _lru->_totalCost;
	pthread_mutex_unlock(&_lock);
	return totalCost;
}

- (BOOL)releaseOnMainThread {
	pthread_mutex_lock(&_lock);
	BOOL releaseOnMainThread = _lru->_releaseOnMainThread;
	pthread_mutex_unlock(&_lock);
	return releaseOnMainThread;
}

- (BOOL)releaseAsynchronously {
	pthread_mutex_lock(&_lock);
	BOOL releaseAsynchronously = _lru->_releaseAsynchronously;
	pthread_mutex_unlock(&_lock);
	return releaseAsynchronously;
}

- (BOOL)containsObjectForKey:(id)key {
	if (!key) return NO;
	pthread_mutex_lock(&_lock);
	BOOL contains = CFDictionaryContainsKey(_lru->_dic, (__bridge const void *)(key));
	pthread_mutex_unlock(&_lock);
	return contains;
}

- (NSString *)description {
	if (_name) return [NSString stringWithFormat:@"<%@: %p> (%@)", self.class, self, _name];
	else return [NSString stringWithFormat:@"<%@: %p>", self.class, self];
}

#pragma mark Setting
- (void)setReleaseOnMainThread:(BOOL)releaseOnMainThread {
	pthread_mutex_lock(&_lock);
	_lru->_releaseOnMainThread = releaseOnMainThread;
	pthread_mutex_unlock(&_lock);
}

- (void)setReleaseAsynchronously:(BOOL)releaseAsynchronously {
	pthread_mutex_lock(&_lock);
	_lru->_releaseAsynchronously = releaseAsynchronously;
	pthread_mutex_unlock(&_lock);
}

- (void)setObject:(id)object forKey:(id)key {
	[self setObject:object forKey:key withCost:0];
}

// 添加缓存
- (void)setObject:(id)object forKey:(id)key withCost:(NSUInteger)cost {
	if (!key) return;
	if (!object) {
		// ** 缓存对象为空，移除缓存 **
		[self removeObjectForKey:key];
		return;
	}
	// 加锁
	pthread_mutex_lock(&_lock);

	// 查找缓存
	_YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));

	// 当前时间
	NSTimeInterval now = CACurrentMediaTime();
	if (node) {
		//** 之前有缓存，更新旧缓存 **

		// 更新值
		_lru->_totalCost -= node->_cost;
		_lru->_totalCost += cost;
		node->_cost = cost;
		node->_time = now;
		node->_value = object;

		// 移动节点到链表表头
		[_lru bringNodeToHead:node];
	} else {
		//** 之前未有缓存，添加新缓存 **

		// 新建节点
		node = [_YYLinkedMapNode new];
		node->_cost = cost;
		node->_time = now;
		node->_key = key;
		node->_value = object;

		// 添加节点到表头
		[_lru insertNodeAtHead:node];
	}
	if (_lru->_totalCost > _costLimit) {
		// ** 总缓存开销大于设定的开销 **

		// 异步清理最久未使用的缓存
		dispatch_async(_queue, ^{
			[self trimToCost:self->_costLimit];
		});
	}
	if (_lru->_totalCount > _countLimit) {
		// ** 总缓存数量大于设定的数量 **

		// 移除链表尾节点(最久未访问的缓存)
		_YYLinkedMapNode *node = [_lru removeTailNode];
		if (_lru->_releaseAsynchronously) {
			dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
			dispatch_async(queue, ^{
				[node class]; //  and release in queue
			});
		} else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[node class]; //hold and release in queue
			});
		}
	}
	pthread_mutex_unlock(&_lock);
}

- (void)removeObjectForKey:(id)key {
	if (!key) return;
	pthread_mutex_lock(&_lock);
	_YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
	if (node) {
		[_lru removeNode:node];
		if (_lru->_releaseAsynchronously) {
			dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
			dispatch_async(queue, ^{
				[node class]; //hold and release in queue
			});
		} else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[node class]; //hold and release in queue
			});
		}
	}
	pthread_mutex_unlock(&_lock);
}

- (void)removeAllObjects {
	pthread_mutex_lock(&_lock);
	[_lru removeAll];
	pthread_mutex_unlock(&_lock);
}

- (void)trimToCount:(NSUInteger)count {
	if (count == 0) {
		[self removeAllObjects];
		return;
	}
	[self _trimToCount:count];
}

- (void)trimToCost:(NSUInteger)cost {
	[self _trimToCost:cost];
}

- (void)trimToAge:(NSTimeInterval)age {
	[self _trimToAge:age];
}


@end
