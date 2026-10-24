//
//  DiscordSocialBridge.mm
//  Trop
//
//  Created by 686udjie on 24/20/2026.
//

#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>

#import "DiscordSocialBridge.h"

#include <memory>
#include <string>

using discordpp::Client;

static NSString *DiscordString(const std::string &value) {
    return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

@interface DiscordSocialBridge () {
    std::unique_ptr<Client> _client;
    std::optional<discordpp::AuthorizationCodeVerifier> _verifier;
    NSTimer *_callbackTimer;
    NSTimer *_authorizationTimeoutTimer;
}
- (void)pumpCallbacks;
- (void)authorizationTimedOut;
@end

@implementation DiscordSocialBridge

+ (instancetype)shared {
    static DiscordSocialBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bridge = [DiscordSocialBridge new]; });
    return bridge;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _client = std::make_unique<Client>();
        _client->SetApplicationId(1563551993652445258ULL);
        _client->SetStatusChangedCallback([weakSelf = self](Client::Status status,
                                                              Client::Error,
                                                              int32_t errorDetail) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DiscordSocialBridge *strongSelf = weakSelf;
                if (!strongSelf) return;
                NSLog(@"[DiscordSocialSDK] status=%d errorDetail=%d", (int)status, errorDetail);
                [strongSelf.delegate discordSocialStatusChanged:(NSInteger)status];
            });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_callbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                                      target:self
                                                                    selector:@selector(pumpCallbacks)
                                                                    userInfo:nil
                                                                     repeats:YES];
            NSLog(@"[DiscordSocialSDK] callback pump started");
        });
    }
    return self;
}

- (void)authorize {
    if (!_client) return;

    _verifier = _client->CreateAuthorizationCodeVerifier();
    if (!_verifier || !_verifier->Challenge()) {
        [self fail:"Discord SDK could not create a PKCE verifier"];
        return;
    }
    discordpp::AuthorizationArgs args;
    args.SetClientId(1563551993652445258ULL);
    args.SetScopes(Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(_verifier->Challenge());
    args.SetCustomSchemeParam("discord-1563551993652445258");

    NSLog(@"[DiscordSocialSDK] authorize scopes=%s redirect=discord-1563551993652445258:/authorize/callback",
          args.Scopes().c_str());
    _client->Authorize(std::move(args), [weakSelf = self](discordpp::ClientResult result,
                                                          std::string code,
                                                          std::string redirectUri) {
        DiscordSocialBridge *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!result.Successful() || code.empty()) {
            [strongSelf fail:result.ToString()];
            return;
        }

        NSLog(@"[DiscordSocialSDK] authorize returned code redirect=%s", redirectUri.c_str());
        strongSelf->_client->GetToken(1563551993652445258ULL,
                                      code,
                                      strongSelf->_verifier->Verifier(),
                                      redirectUri,
                                      [weakSelf](discordpp::ClientResult tokenResult,
                                                 std::string accessToken,
                                                 std::string refreshToken,
                                                 discordpp::AuthorizationTokenType,
                                                 int32_t expiresIn,
                                                 std::string scopes) {
            DiscordSocialBridge *self = weakSelf;
            if (!self) return;
            if (!tokenResult.Successful() || accessToken.empty()) {
                [self fail:tokenResult.ToString()];
                return;
            }
            NSLog(@"[DiscordSocialSDK] token exchange succeeded expiresIn=%d", expiresIn);
            self->_client->UpdateToken(discordpp::AuthorizationTokenType::Bearer,
                                       accessToken,
                                       [self, accessToken, refreshToken, expiresIn, scopes](discordpp::ClientResult updateResult) {
                if (!updateResult.Successful()) {
                    [self fail:updateResult.ToString()];
                    return;
                }
                [self->_authorizationTimeoutTimer invalidate];
                self->_authorizationTimeoutTimer = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate discordSocialAuthorizationSucceededWithAccessToken:DiscordString(accessToken)
                                                                           refreshToken:DiscordString(refreshToken)
                                                                             expiresIn:expiresIn
                                                                                  scope:DiscordString(scopes)];
                });
                self->_client->Connect();
            });
        });
    });
    NSLog(@"[DiscordSocialSDK] authorize request submitted");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_authorizationTimeoutTimer invalidate];
        self->_authorizationTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                                            target:self
                                                                          selector:@selector(authorizationTimedOut)
                                                                          userInfo:nil
                                                                           repeats:NO];
    });
}

- (void)pumpCallbacks {
    discordpp::RunCallbacks();
}

- (void)authorizationTimedOut {
    NSLog(@"[DiscordSocialSDK] authorization timed out waiting for callback");
    [self fail:"Discord authorization timed out. Check Discord installation and the callback URL scheme."];
}

- (void)connectWithAccessToken:(NSString *)accessToken {
    if (!_client || accessToken.length == 0) return;
    std::string token = accessToken.UTF8String ?: "";
    _client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, token,
                         [weakSelf = self](discordpp::ClientResult result) {
        DiscordSocialBridge *self = weakSelf;
        if (!self) return;
        if (!result.Successful()) {
            [self fail:result.ToString()];
            return;
        }
        NSLog(@"[DiscordSocialSDK] stored token accepted; connecting");
        self->_client->Connect();
    });
}

- (void)updateActivityWithName:(NSString *)name
                 activityType:(NSInteger)activityType
                       details:(NSString *)details
                          state:(NSString *)state
                    startTimeMs:(long long)startTimeMs
                      endTimeMs:(long long)endTimeMs
                    largeImage:(NSString *)largeImage
                     largeText:(NSString *)largeText
                    smallImage:(NSString *)smallImage
                     smallText:(NSString *)smallText
                       buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *)buttons {
    if (!_client) return;
    discordpp::Activity activity;
    discordpp::ActivityTypes sdkType = discordpp::ActivityTypes::Playing;
    switch (activityType) {
        case 1: sdkType = discordpp::ActivityTypes::Streaming; break;
        case 2: sdkType = discordpp::ActivityTypes::Listening; break;
        case 3: sdkType = discordpp::ActivityTypes::Watching; break;
        case 4: sdkType = discordpp::ActivityTypes::CustomStatus; break;
        case 5: sdkType = discordpp::ActivityTypes::Competing; break;
        default: break;
    }
    activity.SetType(sdkType);
    NSLog(@"[DiscordSocialSDK] sending activity type=%ld", (long)activityType);
    activity.SetName(name.UTF8String ?: "Trop");
    if (details.length) activity.SetDetails(details.UTF8String);
    if (state.length) activity.SetState(state.UTF8String);
    if (largeImage.length || smallImage.length) {
        discordpp::ActivityAssets assets;
        if (largeImage.length) assets.SetLargeImage(largeImage.UTF8String);
        if (largeText.length) assets.SetLargeText(largeText.UTF8String);
        if (smallImage.length) assets.SetSmallImage(smallImage.UTF8String);
        if (smallText.length) assets.SetSmallText(smallText.UTF8String);
        activity.SetAssets(assets);
    }
    for (NSDictionary<NSString *, NSString *> *buttonData in buttons) {
        NSString *label = buttonData[@"label"];
        NSString *url = buttonData[@"url"];
        if (!label.length || !url.length) continue;
        discordpp::ActivityButton button;
        button.SetLabel(label.UTF8String);
        button.SetUrl(url.UTF8String);
        activity.AddButton(std::move(button));
    }
    if (startTimeMs > 0 || endTimeMs > 0) {
        discordpp::ActivityTimestamps timestamps;
        if (startTimeMs > 0) timestamps.SetStart(static_cast<uint64_t>(startTimeMs));
        if (endTimeMs > 0) timestamps.SetEnd(static_cast<uint64_t>(endTimeMs));
        activity.SetTimestamps(timestamps);
    }
    _client->UpdateRichPresence(std::move(activity), [](discordpp::ClientResult result) {
        if (!result.Successful()) NSLog(@"[DiscordSocialSDK] presence failed: %@", DiscordString(result.ToString()));
    });
}

- (void)clearActivity {
    if (!_client) return;
    _client->UpdateRichPresence(discordpp::Activity{}, [](discordpp::ClientResult) {});
}

- (void)disconnect {
    if (_client) _client->Disconnect();
}

- (void)fail:(const std::string &)message {
    [_authorizationTimeoutTimer invalidate];
    _authorizationTimeoutTimer = nil;
    NSString *value = DiscordString(message);
    NSLog(@"[DiscordSocialSDK] error=%@", value);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate discordSocialAuthorizationFailed:value];
    });
}

@end
