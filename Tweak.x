#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include "sodium_seal.h"

static UIWindow *ucWindow = nil;
static UIButton *ucButton = nil;
static UILabel *ucToastLabel = nil;
static BOOL hasCapturedOnce = NO;

// 手动抓取后归档的 Cookie
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *capturedCookies = nil;
// 静默请求头缓存
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *silentHeaderCache = nil;
// GitHub 仓库列表内存缓存（避免返回上一步或切换 Cookie 时重复网络请求）
static NSArray<NSDictionary *> *cachedRepos = nil;

@interface UCPassthroughWindow : UIWindow
@end

@implementation UCPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;
    if (self.rootViewController.presentedViewController != nil) {
        return [super hitTest:point withEvent:event];
    }
    if (ucButton && !ucButton.hidden) {
        CGPoint btnPoint = [self convertPoint:point toView:ucButton];
        if ([ucButton pointInside:btnPoint withEvent:event]) {
            return ucButton;
        }
    }
    return nil;
}
@end

@interface CookieGroupItem : NSObject
@property (nonatomic, copy) NSString *rootDomain;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *cookieString;
@property (nonatomic, assign) BOOL isAuthRelated;
@property (nonatomic, assign) NSInteger priorityScore;
@end

@implementation CookieGroupItem
@end

@interface UniversalCookieManager : NSObject
+ (instancetype)shared;
- (void)ensureUI;
- (void)cacheSilentRequest:(NSURLRequest *)request;
- (void)performManualCaptureWithCompletion:(void (^)(void))completion;
@end

@implementation UniversalCookieManager

+ (instancetype)shared {
    static UniversalCookieManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[UniversalCookieManager alloc] init];
        capturedCookies = [NSMutableDictionary dictionary];
        silentHeaderCache = [NSMutableDictionary dictionary];
    });
    return instance;
}

#pragma mark - 零冲突弹窗接力与无阻塞 HUD 提示

// 安全弹出菜单：如果上一个菜单还在关闭动画中，自动收起并接力弹出，绝不丢弃弹窗
- (void)presentAlert:(UIAlertController *)alert {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ucWindow || !ucWindow.rootViewController) return;
        UIViewController *root = ucWindow.rootViewController;
        [ucWindow makeKeyWindow];
        
        if (root.presentedViewController) {
            [root dismissViewControllerAnimated:NO completion:^{
                [root presentViewController:alert animated:YES completion:nil];
            }];
        } else {
            [root presentViewController:alert animated:YES completion:nil];
        }
    });
}

// 纯 UIView 悬浮胶囊提示：不占用 UIAlertController 通道，彻底杜绝与菜单弹窗撞车
- (void)showToast:(NSString *)msg duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ucWindow || !ucWindow.rootViewController) return;
        UIView *parentView = ucWindow.rootViewController.view;
        
        if (!ucToastLabel) {
            ucToastLabel = [[UILabel alloc] init];
            ucToastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
            ucToastLabel.textColor = [UIColor whiteColor];
            ucToastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            ucToastLabel.textAlignment = NSTextAlignmentCenter;
            ucToastLabel.numberOfLines = 0;
            ucToastLabel.layer.cornerRadius = 12;
            ucToastLabel.layer.masksToBounds = YES;
            ucToastLabel.userInteractionEnabled = NO;
            ucToastLabel.alpha = 0.0;
            [parentView addSubview:ucToastLabel];
        }
        
        ucToastLabel.text = msg;
        CGFloat maxWidth = [UIScreen mainScreen].bounds.size.width - 60;
        CGSize fitSize = [ucToastLabel sizeThatFits:CGSizeMake(maxWidth - 32, 300)];
        CGFloat w = MIN(maxWidth, MAX(160, fitSize.width + 32));
        CGFloat h = MAX(44, fitSize.height + 20);
        ucToastLabel.frame = CGRectMake(([UIScreen mainScreen].bounds.size.width - w) / 2.0, 110, w, h);
        [parentView bringSubviewToFront:ucToastLabel];
        
        // 使用递增标记防止连续 Toast 提前消失
        static NSInteger toastToken = 0;
        toastToken++;
        NSInteger currentToken = toastToken;
        
        [UIView animateWithDuration:0.2 animations:^{
            ucToastLabel.alpha = 1.0;
        }];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (currentToken == toastToken) {
                [UIView animateWithDuration:0.25 animations:^{
                    ucToastLabel.alpha = 0.0;
                }];
            }
        });
    });
}

#pragma mark - 一级主域名提取与垃圾过滤

- (NSString *)extractRootDomain:(NSString *)domain {
    if (!domain || domain.length == 0) return @"unknown";
    NSString *d = [[domain lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([d hasPrefix:@"."]) d = [d substringFromIndex:1];
    
    NSArray<NSString *> *parts = [d componentsSeparatedByString:@"."];
    if (parts.count <= 2) return d;
    
    NSString *lastTwo = [NSString stringWithFormat:@"%@.%@", parts[parts.count - 2], parts.lastObject];
    NSSet *doubleTLDs = [NSSet setWithObjects:@"com.cn", @"net.cn", @"org.cn", @"gov.cn", @"edu.cn", @"com.hk", nil];
    if ([doubleTLDs containsObject:lastTwo] && parts.count >= 3) {
        return [NSString stringWithFormat:@"%@.%@", parts[parts.count - 3], lastTwo];
    }
    return lastTwo;
}

- (BOOL)isJunkDomain:(NSString *)rootDomain {
    NSArray<NSString *> *junkList = @[
        @"mmstat.com", @"alicdn.com", @"atanx.com", @"effirst.com", @"360buyimg.com",
        @"umeng.com", @"umengcloud.com", @"sensorsdata.cn", @"growingio.com", @"geetest.com",
        @"shuzilm.cn", @"tingyun.com", @"bugly.qq.com", @"doubleclick.net", @"googlesyndication.com",
        @"irs01.com", @"miaozhen.com", @"allyes.com", @"bdimg.com", @"baidustatic.com"
    ];
    for (NSString *junk in junkList) {
        if ([rootDomain isEqualToString:junk]) return YES;
    }
    return NO;
}

#pragma mark - 手动单次抓取逻辑

- (void)saveCookieName:(NSString *)name value:(NSString *)value domain:(NSString *)domain toDict:(NSMutableDictionary *)targetDict {
    if (!name || !value || name.length == 0 || value.length == 0) return;
    NSString *rootDomain = [self extractRootDomain:domain];
    if ([self isJunkDomain:rootDomain]) return;
    
    @synchronized (targetDict) {
        NSMutableDictionary *kv = targetDict[rootDomain];
        if (!kv) {
            kv = [NSMutableDictionary dictionary];
            targetDict[rootDomain] = kv;
        }
        kv[name] = value;
    }
}

- (void)cacheSilentRequest:(NSURLRequest *)request {
    if (!request || !request.URL.host) return;
    NSString *host = request.URL.host;
    if ([self isJunkDomain:[self extractRootDomain:host]]) return;
    
    NSDictionary *headers = request.allHTTPHeaderFields;
    for (NSString *key in headers.allKeys) {
        NSString *lowerKey = [key lowercaseString];
        NSString *val = headers[key];
        if ([lowerKey isEqualToString:@"cookie"]) {
            NSArray *pairs = [val componentsSeparatedByString:@";"];
            for (NSString *pair in pairs) {
                NSRange eqRange = [pair rangeOfString:@"="];
                if (eqRange.location != NSNotFound) {
                    NSString *k = [[pair substringToIndex:eqRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *v = [[pair substringFromIndex:eqRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    [self saveCookieName:k value:v domain:host toDict:silentHeaderCache];
                }
            }
        } else if ([lowerKey isEqualToString:@"authorization"] ||
                   [lowerKey isEqualToString:@"auth_token"] ||
                   [lowerKey isEqualToString:@"token"] ||
                   [lowerKey isEqualToString:@"x-csrftoken"]) {
            [self saveCookieName:key value:val domain:host toDict:silentHeaderCache];
        }
    }
}

- (void)performManualCaptureWithCompletion:(void (^)(void))completion {
    @synchronized (capturedCookies) {
        [capturedCookies removeAllObjects];
        @synchronized (silentHeaderCache) {
            for (NSString *d in silentHeaderCache.allKeys) {
                capturedCookies[d] = [silentHeaderCache[d] mutableCopy];
            }
        }
    }
    
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        [self saveCookieName:c.name value:c.value domain:c.domain toDict:capturedCookies];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 11.0, *)) {
            [[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> * _Nonnull wkCookies) {
                for (NSHTTPCookie *c in wkCookies) {
                    [self saveCookieName:c.name value:c.value domain:c.domain toDict:capturedCookies];
                }
                hasCapturedOnce = YES;
                [self updateFloatingButtonVisual];
                if (completion) completion();
            }];
        } else {
            hasCapturedOnce = YES;
            [self updateFloatingButtonVisual];
            if (completion) completion();
        }
    });
}

#pragma mark - 智能归类与高价值推荐

- (NSArray<CookieGroupItem *> *)buildCategorizedGroups {
    NSDictionary *snapshot = nil;
    @synchronized (capturedCookies) {
        snapshot = [capturedCookies copy];
    }
    if (snapshot.count == 0) return @[];

    NSArray<NSString *> *authKeywords = @[
        @"pt_key", @"pt_pin", @"auth", @"token", @"user", @"login",
        @"session", @"uid", @"cookie2", @"pin", @"sid", @"csrf", @"account", @"nick"
    ];

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *cookieToDomains = [NSMutableDictionary dictionary];
    for (NSString *rootDomain in snapshot.allKeys) {
        NSDictionary *kv = snapshot[rootDomain];
        if (!kv || kv.count == 0) continue;
        
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in [kv.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, kv[k]]];
        }
        NSString *fullStr = [parts componentsJoinedByString:@"; "];
        if (!cookieToDomains[fullStr]) {
            cookieToDomains[fullStr] = [NSMutableArray array];
        }
        [cookieToDomains[fullStr] addObject:rootDomain];
    }

    NSMutableArray<CookieGroupItem *> *items = [NSMutableArray array];

    for (NSString *cookieStr in cookieToDomains.allKeys) {
        NSArray<NSString *> *domains = cookieToDomains[cookieStr];
        NSString *primaryDomain = domains.firstObject;
        NSString *domainLabel = (domains.count > 1) ? [NSString stringWithFormat:@"%@ 等%lu个域名", primaryDomain, (unsigned long)domains.count] : primaryDomain;

        NSInteger score = 0;
        NSString *lowerCookie = [cookieStr lowercaseString];
        NSMutableArray<NSString *> *matchedTags = [NSMutableArray array];

        for (NSString *kw in authKeywords) {
            if ([lowerCookie containsString:kw]) {
                score += 20;
                if (![matchedTags containsObject:kw]) {
                    [matchedTags addObject:kw];
                }
            }
        }

        CookieGroupItem *item = [[CookieGroupItem alloc] init];
        item.rootDomain = primaryDomain;
        item.cookieString = cookieStr;
        item.priorityScore = score;
        item.isAuthRelated = (score > 0);

        NSUInteger fieldCount = [cookieStr componentsSeparatedByString:@";"].count;
        if (item.isAuthRelated && matchedTags.count > 0) {
            NSArray *subTags = [matchedTags subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, matchedTags.count))];
            NSString *tagStr = [subTags componentsJoinedByString:@","];
            item.displayName = [NSString stringWithFormat:@"🌟 %@ [含:%@] (%lu项)", domainLabel, tagStr, (unsigned long)fieldCount];
        } else {
            item.displayName = [NSString stringWithFormat:@"📄 %@ (%lu项)", domainLabel, (unsigned long)fieldCount];
        }

        [items addObject:item];
    }

    [items sortUsingComparator:^NSComparisonResult(CookieGroupItem *a, CookieGroupItem *b) {
        if (a.priorityScore > b.priorityScore) return NSOrderedAscending;
        if (a.priorityScore < b.priorityScore) return NSOrderedDescending;
        return [a.rootDomain compare:b.rootDomain];
    }];

    return items;
}

- (void)updateFloatingButtonVisual {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ucButton) return;
        if (!hasCapturedOnce) {
            ucButton.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
            [ucButton setTitle:@"点我抓取" forState:UIControlStateNormal];
            return;
        }
        NSArray<CookieGroupItem *> *groups = [self buildCategorizedGroups];
        if (groups.count > 0) {
            ucButton.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.92];
            [ucButton setTitle:[NSString stringWithFormat:@"已抓(%lu)", (unsigned long)groups.count] forState:UIControlStateNormal];
        } else {
            ucButton.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.9];
            [ucButton setTitle:@"未抓到" forState:UIControlStateNormal];
        }
    });
}

#pragma mark - 悬浮球 UI 初始化

- (void)ensureUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive || !activeScene) {
                    activeScene = ws;
                }
            }
        }
        
        if (ucWindow) {
            if (activeScene && ucWindow.windowScene != activeScene) ucWindow.windowScene = activeScene;
            ucWindow.windowLevel = UIWindowLevelStatusBar + 200;
            return;
        }
        
        if (activeScene) {
            ucWindow = [[UCPassthroughWindow alloc] initWithWindowScene:activeScene];
        } else {
            ucWindow = [[UCPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        
        ucWindow.frame = [UIScreen mainScreen].bounds;
        ucWindow.windowLevel = UIWindowLevelStatusBar + 200;
        ucWindow.backgroundColor = [UIColor clearColor];
        
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        ucWindow.rootViewController = vc;
        
        ucButton = [UIButton buttonWithType:UIButtonTypeCustom];
        ucButton.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 75, 160, 62, 62);
        ucButton.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
        [ucButton setTitle:@"点我抓取" forState:UIControlStateNormal];
        ucButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        ucButton.layer.cornerRadius = 31;
        ucButton.layer.masksToBounds = YES;
        ucButton.layer.borderColor = [UIColor whiteColor].CGColor;
        ucButton.layer.borderWidth = 1.5;
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
        [ucButton addGestureRecognizer:pan];
        
        UITapGestureRecognizer *twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTwoFingerTap)];
        twoFingerTap.numberOfTouchesRequired = 2;
        twoFingerTap.numberOfTapsRequired = 2;
        [ucButton addGestureRecognizer:twoFingerTap];
        
        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBtnClick)];
        singleTap.numberOfTapsRequired = 1;
        singleTap.numberOfTouchesRequired = 1;
        [ucButton addGestureRecognizer:singleTap];
        
        [vc.view addSubview:ucButton];
        ucWindow.hidden = NO;
    });
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan translationInView:ucWindow];
    ucButton.center = CGPointMake(ucButton.center.x + p.x, ucButton.center.y + p.y);
    [pan setTranslation:CGPointZero inView:ucWindow];
}

- (void)onTwoFingerTap {
    ucButton.hidden = YES;
}

- (void)onBtnClick {
    ucButton.userInteractionEnabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ucButton.userInteractionEnabled = YES;
    });
    
    [self performManualCaptureWithCompletion:^{
        [self showMainMenu];
    }];
}

#pragma mark - 多级联动菜单（带内存缓存与秒级返回）

- (void)showMainMenu {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *boundDomain = [defs stringForKey:@"uc_bound_domain"];
    NSString *boundRepo = [defs stringForKey:@"uc_bound_repo"];
    NSString *boundSecret = [defs stringForKey:@"uc_bound_secret"];
    
    NSArray<CookieGroupItem *> *groups = [self buildCategorizedGroups];
    NSString *subMsg = [NSString stringWithFormat:@"本次手动抓取归类出 %lu 组主域名凭证", (unsigned long)groups.count];
    if (boundDomain && boundRepo && boundSecret) {
        subMsg = [NSString stringWithFormat:@"本次抓取 %lu 组 | 已绑定:\n[%@] ➔ %@ (%@)", (unsigned long)groups.count, boundDomain, boundRepo, boundSecret];
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"通用 Cookie 助手 (手动模式)" message:subMsg preferredStyle:UIAlertControllerStyleActionSheet];
    
    if (boundDomain && boundRepo && boundSecret) {
        [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"⚡ 一键推送 [%@] 最新凭证", boundDomain] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            NSString *targetCookie = nil;
            for (CookieGroupItem *item in groups) {
                if ([item.rootDomain isEqualToString:boundDomain]) {
                    targetCookie = item.cookieString;
                    break;
                }
            }
            if (!targetCookie && groups.count > 0) {
                CookieGroupItem *first = groups.firstObject;
                targetCookie = first.cookieString;
            }
            if (!targetCookie || targetCookie.length == 0) {
                [self showToast:@"当前未抓到有效凭证，请先进入个人中心" duration:2.0];
                return;
            }
            [self pushCookie:targetCookie rootDomain:boundDomain toFullRepo:boundRepo secretName:boundSecret];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"🎯 查看抓取结果 ➔ 推送到 GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showCookieGroupListForPush:YES];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"📋 查看抓取结果 ➔ 复制到剪贴板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showCookieGroupListForPush:NO];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"🔄 重新手动抓取一次当前页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self performManualCaptureWithCompletion:^{
            [self showToast:@"已重新抓取当前页 Cookie ✅" duration:1.5];
        }];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"⚙️ 配置 GitHub 访问令牌 (PAT)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showTokenConfig];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"❌ 取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert];
}

// 第 1 步：选择归类后的主域名凭证
- (void)showCookieGroupListForPush:(BOOL)forPush {
    NSArray<CookieGroupItem *> *groups = [self buildCategorizedGroups];
    if (groups.count == 0) {
        [self showToast:@"当前未抓到任何有效 Cookie\n请先点开 App『个人中心/我的』后再点悬浮球" duration:2.5];
        return;
    }
    
    NSString *title = forPush ? @"第 1 步: 选择要推送的凭证" : @"选择要复制的凭证";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:@"已按一级主域名合并，🌟为含登录特征的高价值凭证" preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (CookieGroupItem *item in groups) {
        [alert addAction:[UIAlertAction actionWithTitle:item.displayName style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (!forPush) {
                [UIPasteboard generalPasteboard].string = item.cookieString;
                [self showToast:[NSString stringWithFormat:@"已复制 [%@] ✅\n共 %lu 字符", item.rootDomain, (unsigned long)item.cookieString.length] duration:1.8];
            } else {
                [self showGitHubReposForCookie:item.cookieString rootDomain:item.rootDomain forceRefresh:NO];
            }
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"🔙 返回主菜单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showMainMenu];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"❌ 取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert];
}

// 渲染仓库选择列表弹窗
- (void)presentRepoAlertWithRepos:(NSArray<NSDictionary *> *)repos cookie:(NSString *)cookieStr rootDomain:(NSString *)rootDomain {
    UIAlertController *repoAlert = [UIAlertController alertControllerWithTitle:@"第 2 步: 选择目标仓库" message:[NSString stringWithFormat:@"已选域名: [%@] (共 %lu 个仓库)", rootDomain, (unsigned long)repos.count] preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSDictionary *repoDict in repos) {
        NSString *fullName = repoDict[@"full_name"];
        NSString *repoName = repoDict[@"name"];
        BOOL isPrivate = [repoDict[@"private"] boolValue];
        NSString *label = [NSString stringWithFormat:@"%@ %@", isPrivate ? @"🔒" : @"📦", repoName];
        
        [repoAlert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self fetchSecretsForFullRepo:fullName cookie:cookieStr rootDomain:rootDomain];
        }]];
    }
    
    [repoAlert addAction:[UIAlertAction actionWithTitle:@"🔄 刷新仓库列表" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showGitHubReposForCookie:cookieStr rootDomain:rootDomain forceRefresh:YES];
    }]];
    
    [repoAlert addAction:[UIAlertAction actionWithTitle:@"🔙 返回上一步 (重新选凭证)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showCookieGroupListForPush:YES];
    }]];
    [repoAlert addAction:[UIAlertAction actionWithTitle:@"❌ 取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:repoAlert];
}

// 第 2 步：选择 GitHub 仓库（优先使用内存缓存秒开，彻底解决返回不显示的问题）
- (void)showGitHubReposForCookie:(NSString *)cookieStr rootDomain:(NSString *)rootDomain forceRefresh:(BOOL)forceRefresh {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"uc_gh_token"];
    if (!token || token.length == 0) {
        [self showTokenConfig];
        return;
    }
    
    // 如果已有缓存且非强制刷新，0 延迟直接弹出仓库列表！
    if (cachedRepos && cachedRepos.count > 0 && !forceRefresh) {
        [self presentRepoAlertWithRepos:cachedRepos cookie:cookieStr rootDomain:rootDomain];
        return;
    }
    
    [self showToast:@"正在拉取 GitHub 仓库列表..." duration:1.2];
    
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/user/repos?per_page=100&sort=updated&affiliation=owner"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (error || httpResp.statusCode != 200 || !data) {
            [self showToast:[NSString stringWithFormat:@"拉取仓库失败 (HTTP %ld)\n%@", (long)httpResp.statusCode, error.localizedDescription ?: @""] duration:2.5];
            return;
        }
        
        NSArray *repos = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![repos isKindOfClass:[NSArray class]] || repos.count == 0) {
            [self showToast:@"您的账号下未找到任何仓库" duration:2.0];
            return;
        }
        
        cachedRepos = repos;
        [self presentRepoAlertWithRepos:repos cookie:cookieStr rootDomain:rootDomain];
    }] resume];
}

// 第 3 步：选择对应仓库下的 Secret
- (void)fetchSecretsForFullRepo:(NSString *)fullRepo cookie:(NSString *)cookieStr rootDomain:(NSString *)rootDomain {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"uc_gh_token"];
    [self showToast:[NSString stringWithFormat:@"正在读取 [%@] 的 Secrets...", fullRepo] duration:1.0];
    
    NSString *urlStr = [NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/secrets", fullRepo];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (error || httpResp.statusCode != 200 || !data) {
            [self showToast:[NSString stringWithFormat:@"读取 Secrets 失败 (HTTP %ld)", (long)httpResp.statusCode] duration:2.5];
            return;
        }
        
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *secrets = json[@"secrets"];
        
        UIAlertController *secAlert = [UIAlertController alertControllerWithTitle:@"第 3 步: 选择要更新的 Secret" message:[NSString stringWithFormat:@"目标仓库: %@", fullRepo] preferredStyle:UIAlertControllerStyleActionSheet];
        
        if ([secrets isKindOfClass:[NSArray class]] && secrets.count > 0) {
            for (NSDictionary *secDict in secrets) {
                NSString *secName = secDict[@"name"];
                [secAlert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"🔑 %@", secName] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self pushCookie:cookieStr rootDomain:rootDomain toFullRepo:fullRepo secretName:secName];
                }]];
            }
        }
        
        [secAlert addAction:[UIAlertAction actionWithTitle:@"➕ 新建自定义名称的 Secret..." style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self promptNewSecretForFullRepo:fullRepo cookie:cookieStr rootDomain:rootDomain];
        }]];
        
        // 返回上一步：直接调用带缓存的仓库列表，瞬间弹出！
        [secAlert addAction:[UIAlertAction actionWithTitle:@"🔙 返回上一步 (重新选仓库)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showGitHubReposForCookie:cookieStr rootDomain:rootDomain forceRefresh:NO];
        }]];
        [secAlert addAction:[UIAlertAction actionWithTitle:@"❌ 取消" style:UIAlertActionStyleCancel handler:nil]];
        
        [self presentAlert:secAlert];
    }] resume];
}

- (void)promptNewSecretForFullRepo:(NSString *)fullRepo cookie:(NSString *)cookieStr rootDomain:(NSString *)rootDomain {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建 Secret" message:[NSString stringWithFormat:@"将在 %@ 中创建", fullRepo] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"输入变量名，如 JD_COOKIE";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存并推送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *secName = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (secName.length > 0) {
            [self pushCookie:cookieStr rootDomain:rootDomain toFullRepo:fullRepo secretName:secName];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"🔙 返回上一步" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self fetchSecretsForFullRepo:fullRepo cookie:cookieStr rootDomain:rootDomain];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"❌ 取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentAlert:alert];
}

#pragma mark - 本地加密与直推 GitHub

- (void)pushCookie:(NSString *)cookieStr rootDomain:(NSString *)rootDomain toFullRepo:(NSString *)fullRepo secretName:(NSString *)secretName {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"uc_gh_token"];
    if (!token || token.length == 0) {
        [self showTokenConfig];
        return;
    }
    
    [self showToast:@"正在加密并推送至 GitHub..." duration:1.5];
    
    NSString *pkUrlStr = [NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/secrets/public-key", fullRepo];
    NSMutableURLRequest *pkReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pkUrlStr] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [pkReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [pkReq setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:pkReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (error || httpResp.statusCode != 200 || !data) {
            [self showToast:[NSString stringWithFormat:@"获取公钥失败 (HTTP %ld)", (long)httpResp.statusCode] duration:2.5];
            return;
        }
        
        NSDictionary *keyData = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *b64PubKey = keyData[@"key"];
        NSString *keyId = keyData[@"key_id"];
        NSData *pubKeyBytes = [[NSData alloc] initWithBase64EncodedString:b64PubKey options:0];
        
        if (!pubKeyBytes || pubKeyBytes.length != 32 || !keyId) {
            [self showToast:@"公钥解析异常" duration:2.0];
            return;
        }
        
        NSData *msgBytes = [cookieStr dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *sealedData = [NSMutableData dataWithLength:msgBytes.length + 48];
        sodium_crypto_box_seal((u8 *)sealedData.mutableBytes, (const u8 *)msgBytes.bytes, msgBytes.length, (const u8 *)pubKeyBytes.bytes);
        NSString *encryptedBase64 = [sealedData base64EncodedStringWithOptions:0];
        
        NSString *putUrlStr = [NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/secrets/%@", fullRepo, secretName];
        NSMutableURLRequest *putReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:putUrlStr] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
        putReq.HTTPMethod = @"PUT";
        [putReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [putReq setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
        [putReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        
        NSDictionary *body = @{ @"encrypted_value": encryptedBase64, @"key_id": keyId };
        putReq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        
        [[[NSURLSession sharedSession] dataTaskWithRequest:putReq completionHandler:^(NSData *pData, NSURLResponse *pResp, NSError *pErr) {
            NSHTTPURLResponse *putHttpResp = (NSHTTPURLResponse *)pResp;
            if (!pErr && (putHttpResp.statusCode == 201 || putHttpResp.statusCode == 204)) {
                NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                [defs setObject:rootDomain forKey:@"uc_bound_domain"];
                [defs setObject:fullRepo forKey:@"uc_bound_repo"];
                [defs setObject:secretName forKey:@"uc_bound_secret"];
                [defs synchronize];
                
                [self showToast:[NSString stringWithFormat:@"🚀 精准推送成功！\n域名: %@\n仓库: %@\n变量: %@", rootDomain, fullRepo, secretName] duration:2.8];
            } else {
                [self showToast:[NSString stringWithFormat:@"写入失败 (HTTP %ld)", (long)putHttpResp.statusCode] duration:3.0];
            }
        }] resume];
    }] resume];
}

- (void)showTokenConfig {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"配置 GitHub 访问令牌" message:@"填入拥有 repo 权限的 PAT Token" preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"ghp_xxxxxxxxxxxxxxxx";
        tf.text = [defs stringForKey:@"uc_gh_token"];
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"保存 Token" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *t = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [defs setObject:t forKey:@"uc_gh_token"];
        [defs synchronize];
        cachedRepos = nil; // 更换 Token 后清空旧缓存
        [self showToast:@"Token 已保存 ✅" duration:1.5];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"📋 直接从剪贴板读取并保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *clip = [[UIPasteboard generalPasteboard].string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (clip.length > 10) {
            [defs setObject:clip forKey:@"uc_gh_token"];
            [defs synchronize];
            cachedRepos = nil;
            [self showToast:@"已从剪贴板保存 Token ✅" duration:1.5];
        } else {
            [self showToast:@"剪贴板内没有有效 Token" duration:1.5];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"🔙 返回主菜单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showMainMenu];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"❌ 取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentAlert:alert];
}

@end

#pragma mark - 静默请求头缓存

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    [[UniversalCookieManager shared] cacheSilentRequest:request];
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    [[UniversalCookieManager shared] cacheSilentRequest:request];
    return %orig;
}
%end

%group SessionClusterHook
%hook __NSURLSessionLocal
- (id)dataTaskWithRequest:(NSURLRequest *)request {
    [[UniversalCookieManager shared] cacheSilentRequest:request];
    return %orig;
}
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(id)completionHandler {
    [[UniversalCookieManager shared] cacheSilentRequest:request];
    return %orig;
}
%end
%end

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath] ?: @"";
    if ([bundleID isEqualToString:@"com.apple.springboard"] ||
        ([bundleID hasPrefix:@"com.apple."] && [bundlePath rangeOfString:@"Application"].location == NSNotFound)) {
        return;
    }
    
    %init;
    if (objc_getClass("__NSURLSessionLocal")) {
        %init(SessionClusterHook);
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int i = 1; i <= 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[UniversalCookieManager shared] ensureUI];
            });
        }
    });
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UniversalCookieManager shared] ensureUI];
        });
    }];
}
