#import "SceneDelegate.h"
#import "StreamFrameViewController.h"

API_AVAILABLE(ios(13.0))
@implementation SceneDelegate

static UIView *_sharedStreamVideoRenderView = nil;
static UIWindow *_externalSceneWindow = nil;

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    if ([session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        NSString *storyboardName;
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            storyboardName = @"iPad";
        } else {
            storyboardName = @"iPhone";
        }
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
        UIViewController *initialViewController = [storyboard instantiateInitialViewController];
        self.window.rootViewController = initialViewController;
        [self.window makeKeyAndVisible];
        Log(LOG_I, @"SceneDelegate: Main app scene connected.");

    } else if ([session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplay]) {
        Log(LOG_I, @"SceneDelegate: External display scene connecting for screen: %@", ((UIWindowScene *)scene).screen.description);
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        _externalSceneWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        UIViewController *externalVC = [[UIViewController alloc] init];
        externalVC.view.backgroundColor = [UIColor blackColor]; // Set a default background
        _externalSceneWindow.rootViewController = externalVC;

        if (_sharedStreamVideoRenderView) {
            _sharedStreamVideoRenderView.frame = _externalSceneWindow.bounds;
            [_externalSceneWindow.rootViewController.view addSubview:_sharedStreamVideoRenderView];
            Log(LOG_I, @"SceneDelegate: External display scene connected.");
        }
    }

    // Handle URL contexts (iOS 13+)
    if (connectionOptions.URLContexts.count > 0) {
        UIOpenURLContext *openURLContext = connectionOptions.URLContexts.allObjects.firstObject;
        NSURL *url = openURLContext.URL;
        if ([url.scheme.lowercaseString isEqualToString:@"voidlink"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSString *hostParam = nil;
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name.lowercaseString isEqualToString:@"host"]) {
                    hostParam = item.value;
                    break;
                }
            }
            if ([components.host.lowercaseString isEqualToString:@"auto-enter"] && hostParam.length > 0) {
                AppDelegate *delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
                if (@available(iOS 13.0, *)) {
                    delegate.autoEnterHostName = hostParam; // foreground delivery
                } else {
                    [[NSUserDefaults standardUserDefaults] setObject:hostParam forKey:@"AutoEnterDesktopHostName"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AutoEnterTriggered"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
    }
}

// Handle URL while app is running (iOS 13+)
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts API_AVAILABLE(ios(13.0))
{
    if (URLContexts.count == 0) return;
    UIOpenURLContext *openURLContext = URLContexts.allObjects.firstObject;
    NSURL *url = openURLContext.URL;
    if ([url.scheme.lowercaseString isEqualToString:@"voidlink"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *hostParam = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name.lowercaseString isEqualToString:@"host"]) {
                hostParam = item.value;
                break;
            }
        }
        if ([components.host.lowercaseString isEqualToString:@"auto-enter"] && hostParam.length > 0) {
            AppDelegate *delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
            delegate.autoEnterHostName = hostParam;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"VoidLinkAutoEnterRequested" object:nil userInfo:@{ @"host": hostParam }];
        }
    }
}

// Method for StreamFrameViewController to provide its render view
+ (void)setExternalDisplayRenderView:(UIView *)renderView {
    _sharedStreamVideoRenderView = renderView;
    if (_externalSceneWindow && _externalSceneWindow.rootViewController && _sharedStreamVideoRenderView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Ensure it's removed from any previous parent (should have been done by StreamFrameVC)
            [_sharedStreamVideoRenderView removeFromSuperview];
            _sharedStreamVideoRenderView.frame = _externalSceneWindow.bounds; // Set frame for external window
            [_externalSceneWindow.rootViewController.view addSubview:_sharedStreamVideoRenderView];
            _externalSceneWindow.hidden = NO;
            Log(LOG_I, @"SceneDelegate: Added render view to external window's root view.");
        });
    } else {
        Log(LOG_E, @"SceneDelegate: External display window or root view controller not available.");
    }
}

+ (void)clearExternalDisplayRenderView {
    if (_sharedStreamVideoRenderView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_sharedStreamVideoRenderView removeFromSuperview];
            Log(LOG_I, @"SceneDelegate: Removed render view from external display.");
        });
    }
    _sharedStreamVideoRenderView = nil;
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    Log(LOG_I, @"SceneDelegate: Scene disconnected: %@, role: %@", scene.title, scene.session.role);

    if ([scene.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplay]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (_externalSceneWindow == windowScene.windows.firstObject) { // Compare with the window from the disconnecting scene
                [SceneDelegate clearExternalDisplayRenderView]; // Clears the shared view
                _externalSceneWindow = nil;
                Log(LOG_I, @"SceneDelegate: External display scene fully disconnected and cleaned up.");
            } else {
                Log(LOG_W, @"SceneDelegate: Disconnecting scene is not the one holding our _externalSceneWindow.");
            }
        } else {
            Log(LOG_W, @"SceneDelegate: Disconnecting scene is not a UIWindowScene.");
        }
    }
}

@end
