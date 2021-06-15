# LRU在项目中的实际应用

##### 1. 什么是LRU

> LRU是Least Recently Used的缩写，即最近最少使用，是一种常用的页面置换算法，选择最近最久未使用的页面予以淘汰。该算法赋予每个页面一个访问字段，用来记录一个页面自上次被访问以来所经历的时间 t，当须淘汰一个页面时，选择现有页面中其 t 值最大的，即最近最少使用的页面予以淘汰。

##### 2.  确定数据结构

需要有一个双向链表，用户数据的插入和删除O(n)，插入到第一个事O(1) 核心代码如下

```objective-c
// 插入
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

// 移除
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
```

##### 3. 暴露方法

```objective-c
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
```

```objective-c
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
```

##### 4. 设置缓存的清理机制

```objective-c
// 异步并发队列结合互斥锁的使用。
_queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);
dispatch_async(_queue, ^{
  [self trimToCost:self->_costLimit];
});

//移除尾部的数据，通常来说，最不经常使用的数据将放置在尾部
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
```

##### 5. 总结

1. LRU主要解决缓存淘汰的问题，访问一个缓存后，将会移动到链表的最前面，访问链表的第一个时间复杂度是O(1)，移动到头部O(1)
2. 几轮操作之后，最常使用的缓存会排在链表前面，只有极大地提高了查询速度。
3. 缓存淘汰，首先设置几个清理缓存的条件，例如超过一定的数量，缓存达到500，删除链表尾部，内存警告了，删除链表尾部的数据。
4. 结合多线程的使用，在项目中可以看到初始化了一个异步并发队列，并使用了互斥锁。

