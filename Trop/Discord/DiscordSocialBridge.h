//
//  DiscordSocialBridge.h
//  Trop
//
//  Created by 686udjie on 24/20/2026.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol DiscordSocialBridgeDelegate <NSObject>
- (void)discordSocialAuthorizationSucceededWithAccessToken:(NSString *)accessToken
                                              refreshToken:(NSString *)refreshToken
                                                expiresIn:(NSInteger)expiresIn
                                                     scope:(NSString *)scope;
- (void)discordSocialAuthorizationFailed:(NSString *)message;
- (void)discordSocialStatusChanged:(NSInteger)status;
@end

@interface DiscordSocialBridge : NSObject
+ (instancetype)shared;
@property(nonatomic, weak, nullable) id<DiscordSocialBridgeDelegate> delegate;
- (void)authorize;
- (void)connectWithAccessToken:(NSString *)accessToken;
- (void)updateActivityWithName:(NSString *)name
                 activityType:(NSInteger)activityType
                       details:(nullable NSString *)details
                          state:(nullable NSString *)state
                    startTimeMs:(long long)startTimeMs
                      endTimeMs:(long long)endTimeMs
                    largeImage:(nullable NSString *)largeImage
                     largeText:(nullable NSString *)largeText
                    smallImage:(nullable NSString *)smallImage
                     smallText:(nullable NSString *)smallText
                       buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *)buttons;
- (void)clearActivity;
- (void)disconnect;
@end

NS_ASSUME_NONNULL_END
