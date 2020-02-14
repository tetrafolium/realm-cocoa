////////////////////////////////////////////////////////////////////////////
//
// Copyright 2020 Realm Inc.
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

#import "RLMDecimal128_Private.hpp"

#import "RLMUtil.hpp"

#import <realm/decimal128.hpp>

@implementation RLMDecimal128 {
    realm::Decimal128 _value;
}

- (instancetype)initWithValue:(realm::Decimal128)value {
    if ((self = [super init])) {
        _value = value;
    }
    return self;
}

- (instancetype)initWithNumber:(NSNumber *)number {
    if ((self = [super init])) {
        auto type = number.objCType[0];
        // FIXME: NSDecimalNumber
        if (type == *@encode(double) || type == *@encode(float)) {
            _value = realm::Decimal128(number.doubleValue);
        }
        else if (std::isupper(type)) {
            _value = realm::Decimal128(number.unsignedLongLongValue);
        }
        else {
            _value = realm::Decimal128(number.longLongValue);
        }
    }
    return self;
}

- (instancetype)initWithString:(NSString *)string error:(NSError **)error {
    if ((self = [super init])) {
        try {
            _value = realm::Decimal128(string.UTF8String);
        }
        catch (std::exception const& e) {
            if (error) {
                *error = RLMMakeError(RLMErrorInvalidInput, e);
            }
            return nil;
        }
    }
    return self;
}

+ (instancetype)decimalWithNumber:(NSNumber *)number {
    return [[self alloc] initWithNumber:number];
}

- (realm::Decimal128)decimal128Value {
    return _value;
}

- (BOOL)isEqual:(id)object {
    if (auto decimal128 = RLMDynamicCast<RLMDecimal128>(object)) {
        return _value == decimal128->_value;
    }
    return NO;
}

- (NSUInteger)hash {
    return std::hash<realm::Decimal128>()(_value);
}

- (NSString *)description {
    return @(_value.to_string().c_str());
}
@end
