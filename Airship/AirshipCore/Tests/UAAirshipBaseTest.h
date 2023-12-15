/* Copyright Airship and Contributors */

#import "UABaseTest.h"

@import AirshipCore;


NS_ASSUME_NONNULL_BEGIN
//TODO: remove and use the swift implementation
@interface UAAirshipBaseTest : UABaseTest

/**
 * A preference data store unique to this test. The dataStore is created
 * lazily when first used.
 */
@property (nonatomic, strong) UAPreferenceDataStore *dataStore;

/**
 * A preference airship with unique appkey/secret. A runtime config is created
 * lazily when first used.
 */
@property (nonatomic, strong) UARuntimeConfig *config;

@end

NS_ASSUME_NONNULL_END
