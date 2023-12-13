/* Copyright Airship and Contributors */

#import <Foundation/Foundation.h>
#import "UAAirshipAutomationCoreImport.h"
#import "UASchedule.h"
#import "UAScheduleEdits.h"

@class UAInAppCoreSwiftBridge;
@class UAPreferenceDataStore;
@class UAChannel;
@class UADispatcher;
@class UARemoteDataInfo;

NS_ASSUME_NONNULL_BEGIN

/**
 * Client delegate.
 */
@protocol UAInAppRemoteDataClientDelegate  <NSObject>

/**
 * Gets schedules.
 *
 * @param completionHandler The completion handler to be called when fetch operation completes.
 */
- (void)getSchedules:(void (^)(NSArray<UASchedule *> *))completionHandler;


/**
 * Schedules multiple in-app messages.
 *
 * @param schedules The schedule info for the messages.
 * @param completionHandler The completion handler to be called when scheduling completes.
 */
- (void)scheduleMultiple:(NSArray<UASchedule *> *)schedules completionHandler:(void (^)(BOOL))completionHandler;


/**
 * Edits a schedule.
 *
 * @param identifier A schedule identifier.
 * @param edits The edits to apply.
 * @param completionHandler The completion handler with the result.
 */
- (void)editScheduleWithID:(NSString *)identifier
                     edits:(UAScheduleEdits *)edits
         completionHandler:(nullable void (^)(BOOL))completionHandler;

/**
 * Called with updated constraints.
 * @param constraintData The updated constraints.
 */
- (void)setConstraints:(NSData *)constraintData;

@end

/**
 * Client class to connect the Remote Data and the In App Messaging services.
 * This class parses the remote data payloads, and asks the in app scheduler to
 * create, update, or delete in-app messages, as appropriate.
 */
@interface UAInAppRemoteDataClient : NSObject

/**
 * Client delegate.
 */
@property (nonatomic, weak) id<UAInAppRemoteDataClientDelegate> delegate;

/**
 * New user cut off time.
 */
@property (nonatomic, readonly) NSDate *scheduleNewUserCutOffTime;

/**
 * Create a remote data client for in-app messaging.
 *
 * @param inAppCoreSwiftBridge The in-app core swift bridge.
 * @param dataStore A UAPreferenceDataStore to store persistent preferences
 * @param channel The channel.
 */
+ (instancetype)clientWithInAppCoreSwiftBridge:(UAInAppCoreSwiftBridge *)inAppCoreSwiftBridge
                                     dataStore:(UAPreferenceDataStore *)dataStore
                                       channel:(UAChannel *)channel;

+ (instancetype)clientWithInAppCoreSwiftBridge:(UAInAppCoreSwiftBridge *)inAppCoreSwiftBridge
                                     dataStore:(UAPreferenceDataStore *)dataStore
                                       channel:(UAChannel *)channel
                           schedulerDispatcher:(UADispatcher *)schedulerDispatcher
                                    SDKVersion:(NSString *)SDKVersion;

/**
 * Subscribes to updates.
 */
- (void)subscribe;

/**
 * Unsubscribes from updates.
 */
- (void)unsubscribe;


- (void)isScheduleUpToDate:(UASchedule *)schedule completionHandler:(void (^)(BOOL))completionHandler;
- (void)scheduleRequiresRefresh:(UASchedule *)schedule completionHandler:(void (^)(BOOL))completionHandler;
- (void)bestEffortRefresh:(UASchedule *)schedule completionHandler:(void (^)(BOOL))completionHandler;
- (void)notifyOutdatedSchedule:(UASchedule *)schedule completionHandler:(void (^)(void))completionHandler;
- (void)waitFullRefresh:(UASchedule *)schedule completionHandler:(void (^)(void))completionHandler;

- (UARemoteDataInfo *)remoteDataInfoFromSchedule:(UASchedule *)schedule;
@end

NS_ASSUME_NONNULL_END
