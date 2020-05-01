////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMArray_Private.hpp"

#import "RLMObjectSchema.h"
#import "RLMObjectStore.h"
#import "RLMObject_Private.h"
#import "RLMProperty_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMThreadSafeReference_Private.hpp"
#import "RLMUtil.hpp"

// See -countByEnumeratingWithState:objects:count
@interface RLMArrayHolder : NSObject {
	@public
	std::unique_ptr<id[]> items;
}
@end
@implementation RLMArrayHolder
@end

@interface RLMArray () <RLMThreadConfined_Private>
@end

@implementation RLMArray {
	@public
	// Backing array when this instance is unmanaged
	NSMutableArray *_backingArray;
}

#pragma mark - Initializers

- (instancetype)initWithObjectClassName:
        (__unsafe_unretained NSString *const)objectClassName {
	REALM_ASSERT([objectClassName length] > 0);
	self = [super init];
	if (self) {
		_objectClassName = objectClassName;
		_type = RLMPropertyTypeObject;
	}
	return self;
}

- (instancetype)initWithObjectType:(RLMPropertyType)type
        optional:(BOOL)optional {
	self = [super init];
	if (self) {
		_type = type;
		_optional = optional;
	}
	return self;
}

#pragma mark - Convenience wrappers used for all RLMArray types

- (void)addObjects:(id<NSFastEnumeration>)objects {
	for (id obj in objects) {
		[self addObject:obj];
	}
}

- (void)addObject:(id)object {
	[self insertObject:object atIndex:self.count];
}

- (void)removeLastObject {
	NSUInteger count = self.count;
	if (count) {
		[self removeObjectAtIndex:count - 1];
	}
}

- (id)objectAtIndexedSubscript:(NSUInteger)index {
	return [self objectAtIndex:index];
}

- (void)setObject:(id)newValue atIndexedSubscript:(NSUInteger)index {
	[self replaceObjectAtIndex:index withObject:newValue];
}

- (RLMResults *)sortedResultsUsingKeyPath:(NSString *)keyPath
        ascending:(BOOL)ascending {
	return [self sortedResultsUsingDescriptors:@[
    [RLMSortDescriptor sortDescriptorWithKeyPath:keyPath ascending:ascending]
  ]                                                                                                                                    ];
}

- (NSUInteger)indexOfObjectWhere:(NSString *)predicateFormat, ... {
	va_list args;
	va_start(args, predicateFormat);
	NSUInteger index = [self indexOfObjectWhere:predicateFormat args:args];
	va_end(args);
	return index;
}

- (NSUInteger)indexOfObjectWhere:(NSString *)predicateFormat
        args:(va_list)args {
	return
	        [self indexOfObjectWithPredicate:[NSPredicate
	                                          predicateWithFormat:predicateFormat
	                                          arguments:args]];
}

#pragma mark - Unmanaged RLMArray implementation

- (RLMRealm *)realm {
	return nil;
}

- (id)firstObject {
	if (self.count) {
		return [self objectAtIndex:0];
	}
	return nil;
}

- (id)lastObject {
	NSUInteger count = self.count;
	if (count) {
		return [self objectAtIndex:count - 1];
	}
	return nil;
}

- (id)objectAtIndex:(NSUInteger)index {
	validateArrayBounds(self, index);
	return [_backingArray objectAtIndex:index];
}

- (NSUInteger)count {
	return _backingArray.count;
}

- (BOOL)isInvalidated {
	return NO;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
        objects:
        (__unused __unsafe_unretained id[])buffer
        count:(__unused NSUInteger)len {
	if (state->state != 0) {
		return 0;
	}

	// We need to enumerate a copy of the backing array so that it doesn't
	// reflect changes made during enumeration. This copy has to be autoreleased
	// (since there's nowhere for us to store a strong reference), and uses
	// RLMArrayHolder rather than an NSArray because NSArray doesn't guarantee
	// that it'll use a single contiguous block of memory, and if it doesn't
	// we'd need to forward multiple calls to this method to the same NSArray,
	// which would require holding a reference to it somewhere.
	__autoreleasing RLMArrayHolder *copy = [[RLMArrayHolder alloc] init];
	copy->items = std::make_unique<id[]>(self.count);

	NSUInteger i = 0;
	for (id object in _backingArray) {
		copy->items[i++] = object;
	}

	state->itemsPtr = (__unsafe_unretained id *)(void *)copy->items.get();
	// needs to point to something valid, but the whole point of this is so
	// that it can't be changed
	state->mutationsPtr = state->extra;
	state->state = i;

	return i;
}

template <typename IndexSetFactory>
static void changeArray(__unsafe_unretained RLMArray *const ar,
                        NSKeyValueChange kind, dispatch_block_t f,
                        IndexSetFactory &&is) {
	if (!ar->_backingArray) {
		ar->_backingArray = [NSMutableArray new];
	}

	if (RLMObjectBase *parent = ar->_parentObject) {
		NSIndexSet *indexes = is();
		[parent willChange:kind valuesAtIndexes:indexes forKey:ar->_key];
		f();
		[parent didChange:kind valuesAtIndexes:indexes forKey:ar->_key];
	} else {
		f();
	}
}

static void changeArray(__unsafe_unretained RLMArray *const ar,
                        NSKeyValueChange kind, NSUInteger index,
                        dispatch_block_t f) {
	changeArray(ar, kind, f,
	            [=] {
		return [NSIndexSet indexSetWithIndex:index];
	});
}

static void changeArray(__unsafe_unretained RLMArray *const ar,
                        NSKeyValueChange kind, NSRange range,
                        dispatch_block_t f) {
	changeArray(ar, kind, f,
	            [=] {
		return [NSIndexSet indexSetWithIndexesInRange:range];
	});
}

static void changeArray(__unsafe_unretained RLMArray *const ar,
                        NSKeyValueChange kind, NSIndexSet *is,
                        dispatch_block_t f) {
	changeArray(ar, kind, f, [=] {
		return is;
	});
}

void RLMArrayValidateMatchingObjectType(
	__unsafe_unretained RLMArray *const array,
	__unsafe_unretained id const value) {
	if (!value && !array->_optional) {
		@throw RLMException(@"Invalid nil value for array of '%@'.",
		                    array->_objectClassName
		            ? : RLMTypeToString(array->_type));
	}
	if (array->_type != RLMPropertyTypeObject) {
		if (!RLMValidateValue(value, array->_type, array->_optional, false, nil)) {
			@throw RLMException(
				       @"Invalid value '%@' of type '%@' for expected type '%@%s'.", value,
				       [value class], RLMTypeToString(array->_type),
				       array->_optional ? "?" : "");
		}
		return;
	}

	auto object = RLMDynamicCast<RLMObjectBase>(value);
	if (!object) {
		return;
	}
	if (!object->_objectSchema) {
		@throw RLMException(
			       @"Object cannot be inserted unless the schema is initialized. "
			       "This can happen if you try to insert objects into a RLMArray / List "
			       "from a default value or from an overridden unmanaged initializer "
			       "(`init()`).");
	}
	if (![array->_objectClassName
	      isEqualToString:object->_objectSchema.className]) {
		@throw RLMException(
			       @"Object of type '%@' does not match RLMArray type '%@'.",
			       object->_objectSchema.className, array->_objectClassName);
	}
}

static void validateArrayBounds(__unsafe_unretained RLMArray *const ar,
                                NSUInteger index,
                                bool allowOnePastEnd = false) {
	NSUInteger max = ar->_backingArray.count + allowOnePastEnd;
	if (index >= max) {
		@throw RLMException(
			       @"Index %llu is out of bounds (must be less than %llu).",
			       (unsigned long long)index, (unsigned long long)max);
	}
}

- (void)addObjectsFromArray:(NSArray *)array {
	for (id obj in array) {
		RLMArrayValidateMatchingObjectType(self, obj);
	}
	changeArray(self, NSKeyValueChangeInsertion,
	            NSMakeRange(_backingArray.count, array.count), ^{
		[_backingArray addObjectsFromArray:array];
	});
}

- (void)insertObject:(id)anObject atIndex:(NSUInteger)index {
	RLMArrayValidateMatchingObjectType(self, anObject);
	validateArrayBounds(self, index, true);
	changeArray(self, NSKeyValueChangeInsertion, index, ^{
		[_backingArray insertObject:anObject atIndex:index];
	});
}

- (void)insertObjects:(id<NSFastEnumeration>)objects
        atIndexes:(NSIndexSet *)indexes {
	changeArray(self, NSKeyValueChangeInsertion, indexes, ^{
		NSUInteger currentIndex = [indexes firstIndex];
		for (RLMObject *obj in objects) {
		        RLMArrayValidateMatchingObjectType(self, obj);
		        [_backingArray insertObject:obj atIndex:currentIndex];
		        currentIndex = [indexes indexGreaterThanIndex:currentIndex];
		}
	});
}

- (void)removeObjectAtIndex:(NSUInteger)index {
	validateArrayBounds(self, index);
	changeArray(self, NSKeyValueChangeRemoval, index, ^{
		[_backingArray removeObjectAtIndex:index];
	});
}

- (void)removeObjectsAtIndexes:(NSIndexSet *)indexes {
	changeArray(self, NSKeyValueChangeRemoval, indexes, ^{
		[_backingArray removeObjectsAtIndexes:indexes];
	});
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject {
	RLMArrayValidateMatchingObjectType(self, anObject);
	validateArrayBounds(self, index);
	changeArray(self, NSKeyValueChangeReplacement, index, ^{
		[_backingArray replaceObjectAtIndex:index withObject:anObject];
	});
}

- (void)moveObjectAtIndex:(NSUInteger)sourceIndex
        toIndex:(NSUInteger)destinationIndex {
	validateArrayBounds(self, sourceIndex);
	validateArrayBounds(self, destinationIndex);
	id original = _backingArray[sourceIndex];

	auto start = std::min(sourceIndex, destinationIndex);
	auto len = std::max(sourceIndex, destinationIndex) - start + 1;
	changeArray(self, NSKeyValueChangeReplacement, {start, len}, ^{
		[_backingArray removeObjectAtIndex:sourceIndex];
		[_backingArray insertObject:original atIndex:destinationIndex];
	});
}

- (void)exchangeObjectAtIndex:(NSUInteger)index1
        withObjectAtIndex:(NSUInteger)index2 {
	validateArrayBounds(self, index1);
	validateArrayBounds(self, index2);

	changeArray(
		self, NSKeyValueChangeReplacement,
		^{
		[_backingArray exchangeObjectAtIndex:index1 withObjectAtIndex:index2];
	},
		[=] {
		NSMutableIndexSet *set =
			[[NSMutableIndexSet alloc] initWithIndex:index1];
		[set addIndex:index2];
		return set;
	});
}

- (NSUInteger)indexOfObject:(id)object {
	RLMArrayValidateMatchingObjectType(self, object);
	if (!_backingArray) {
		return NSNotFound;
	}
	if (_type != RLMPropertyTypeObject) {
		return [_backingArray indexOfObject:object];
	}

	NSUInteger index = 0;
	for (RLMObjectBase *cmp in _backingArray) {
		if (RLMObjectBaseAreEqual(object, cmp)) {
			return index;
		}
		index++;
	}
	return NSNotFound;
}

- (void)removeAllObjects {
	changeArray(self, NSKeyValueChangeRemoval,
	            NSMakeRange(0, _backingArray.count), ^{
		[_backingArray removeAllObjects];
	});
}

- (RLMResults *)objectsWhere:(NSString *)predicateFormat, ... {
	va_list args;
	va_start(args, predicateFormat);
	RLMResults *results = [self objectsWhere:predicateFormat args:args];
	va_end(args);
	return results;
}

- (RLMResults *)objectsWhere:(NSString *)predicateFormat args:(va_list)args {
	return [self
	        objectsWithPredicate:[NSPredicate predicateWithFormat:predicateFormat
	                              arguments:args]];
}

static bool canAggregate(RLMPropertyType type, bool allowDate) {
	switch (type) {
	case RLMPropertyTypeInt:
	case RLMPropertyTypeFloat:
	case RLMPropertyTypeDouble:
		return true;
	case RLMPropertyTypeDate:
		return allowDate;
	default:
		return false;
	}
}

- (RLMPropertyType)typeForProperty:(NSString *)propertyName {
	if ([propertyName isEqualToString:@"self"]) {
		return _type;
	}

	RLMObjectSchema *objectSchema;
	if (_backingArray.count) {
		objectSchema = [_backingArray[0] objectSchema];
	} else {
		objectSchema = [RLMSchema.partialPrivateSharedSchema
		                schemaForClassName:_objectClassName];
	}

	return RLMValidatedProperty(objectSchema, propertyName).type;
}

- (id)aggregateProperty:(NSString *)key
        operation:(NSString *)op
        method:(SEL)sel {
	// Although delegating to valueForKeyPath: here would allow to support
	// nested key paths as well, limiting functionality gives consistency
	// between unmanaged and managed arrays.
	if ([key rangeOfString:@"."].location != NSNotFound) {
		@throw RLMException(@"Nested key paths are not supported yet for KVC "
		                    @"collection operators.");
	}

	bool allowDate = false;
	bool sum = false;
	if ([op isEqualToString:@"@min"] || [op isEqualToString:@"@max"]) {
		allowDate = true;
	} else if ([op isEqualToString:@"@sum"]) {
		sum = true;
	} else if (![op isEqualToString:@"@avg"]) {
		// Just delegate to NSArray for all other operators
		return
		        [_backingArray valueForKeyPath:[op stringByAppendingPathExtension:key]];
	}

	RLMPropertyType type = [self typeForProperty:key];
	if (!canAggregate(type, allowDate)) {
		NSString *method = sel ? NSStringFromSelector(sel) : op;
		if (_type == RLMPropertyTypeObject) {
			@throw RLMException(@"%@: is not supported for %@ property '%@.%@'",
			                    method, RLMTypeToString(type), _objectClassName, key);
		} else {
			@throw RLMException(@"%@ is not supported for %@%s array", method,
			                    RLMTypeToString(_type), _optional ? "?" : "");
		}
	}

	NSArray *values = [key isEqualToString:@"self"]
	                ? _backingArray
	                :[_backingArray valueForKey:key];
	if (_optional) {
		// Filter out NSNull values to match our behavior on managed arrays
		NSIndexSet *nonnull =
			[values indexesOfObjectsPassingTest:^BOOL (id obj, NSUInteger, BOOL *) {
			         return obj != NSNull.null;
			 }];
		if (nonnull.count < values.count) {
			values = [values objectsAtIndexes:nonnull];
		}
	}
	id result = [values valueForKeyPath:[op stringByAppendingString:@".self"]];
	return sum && !result ? @0 : result;
}

- (id)valueForKeyPath:(NSString *)keyPath {
	if ([keyPath characterAtIndex:0] != '@') {
		return _backingArray ?[_backingArray valueForKeyPath:keyPath]
		         :[super valueForKeyPath:keyPath];
	}

	if (!_backingArray) {
		_backingArray = [NSMutableArray new];
	}

	NSUInteger dot = [keyPath rangeOfString:@"."].location;
	if (dot == NSNotFound) {
		return [_backingArray valueForKeyPath:keyPath];
	}

	NSString *op = [keyPath substringToIndex:dot];
	NSString *key = [keyPath substringFromIndex:dot + 1];
	return [self aggregateProperty:key operation:op method:nil];
}

- (id)valueForKey:(NSString *)key {
	if ([key isEqualToString:RLMInvalidatedKey]) {
		return @NO; // Unmanaged arrays are never invalidated
	}
	if (!_backingArray) {
		_backingArray = [NSMutableArray new];
	}
	return [_backingArray valueForKey:key];
}

- (void)setValue:(id)value forKey:(NSString *)key {
	if ([key isEqualToString:@"self"]) {
		RLMArrayValidateMatchingObjectType(self, value);
		for (NSUInteger i = 0, count = _backingArray.count; i < count; ++i) {
			_backingArray[i] = value;
		}
		return;
	} else if (_type == RLMPropertyTypeObject) {
		[_backingArray setValue:value forKey:key];
	} else {
		[self setValue:value forUndefinedKey:key];
	}
}

- (id)minOfProperty:(NSString *)property {
	return [self aggregateProperty:property operation:@"@min" method:_cmd];
}

- (id)maxOfProperty:(NSString *)property {
	return [self aggregateProperty:property operation:@"@max" method:_cmd];
}

- (id)sumOfProperty:(NSString *)property {
	return [self aggregateProperty:property operation:@"@sum" method:_cmd];
}

- (id)averageOfProperty:(NSString *)property {
	return [self aggregateProperty:property operation:@"@avg" method:_cmd];
}

- (NSUInteger)indexOfObjectWithPredicate:(NSPredicate *)predicate {
	if (!_backingArray) {
		return NSNotFound;
	}
	return [_backingArray
	        indexOfObjectPassingTest:^BOOL (id obj, NSUInteger, BOOL *) {
	                return [predicate evaluateWithObject:obj];
		}];
}

- (NSArray *)objectsAtIndexes:(NSIndexSet *)indexes {
	if (!_backingArray) {
		_backingArray = [NSMutableArray new];
	}
	return [_backingArray objectsAtIndexes:indexes];
}

- (void)addObserver:(NSObject *)observer
        forKeyPath:(NSString *)keyPath
        options:(NSKeyValueObservingOptions)options
        context:(void *)context {
	RLMValidateArrayObservationKey(keyPath, self);
	[super addObserver:observer
	 forKeyPath:keyPath
	 options:options
	 context:context];
}

#pragma mark - Methods unsupported on unmanaged RLMArray instances

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"

- (RLMResults *)objectsWithPredicate:(NSPredicate *)predicate {
	@throw RLMException(@"This method may only be called on RLMArray instances "
	                    @"retrieved from an RLMRealm");
}

- (RLMResults *)sortedResultsUsingDescriptors:
        (NSArray<RLMSortDescriptor *> *)properties {
	@throw RLMException(@"This method may only be called on RLMArray instances "
	                    @"retrieved from an RLMRealm");
}

// The compiler complains about the method's argument type not matching due to
// it not having the generic type attached, but it doesn't seem to be possible
// to actually include the generic type
// http://www.openradar.me/radar?id=6135653276319744
#pragma clang diagnostic ignored "-Wmismatched-parameter-types"
- (RLMNotificationToken *)addNotificationBlock:
        (void (^)(RLMArray *, RLMCollectionChange *, NSError *))block {
	@throw RLMException(@"This method may only be called on RLMArray instances "
	                    @"retrieved from an RLMRealm");
}

#pragma mark - Thread Confined Protocol Conformance

- (std::unique_ptr<realm::ThreadSafeReferenceBase>)makeThreadSafeReference {
	REALM_TERMINATE("Unexpected handover of unmanaged `RLMArray`");
}

- (id)objectiveCMetadata {
	REALM_TERMINATE("Unexpected handover of unmanaged `RLMArray`");
}

+ (instancetype)objectWithThreadSafeReference:
        (std::unique_ptr<realm::ThreadSafeReferenceBase>)reference
        metadata:(id)metadata
        realm:(RLMRealm *)realm {
	REALM_TERMINATE("Unexpected handover of unmanaged `RLMArray`");
}

#pragma clang diagnostic pop // unused parameter warning

#pragma mark - Superclass Overrides

- (NSString *)description {
	return [self descriptionWithMaxDepth:RLMDescriptionMaxDepth];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
	return RLMDescriptionWithMaxDepth(@"RLMArray", self, depth);
}
@end

@implementation RLMSortDescriptor

+ (instancetype)sortDescriptorWithKeyPath:(NSString *)keyPath
        ascending:(BOOL)ascending {
	RLMSortDescriptor *desc = [[RLMSortDescriptor alloc] init];
	desc->_keyPath = keyPath;
	desc->_ascending = ascending;
	return desc;
}

- (instancetype)reversedSortDescriptor {
	return [self.class sortDescriptorWithKeyPath:_keyPath ascending:!_ascending];
}

@end
