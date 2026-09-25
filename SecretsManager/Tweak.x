#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include "sodium_seal.h"

static UIWindow *smWindow = nil;
static UIButton *smFloatBtn = nil;
static UIImageView *smFloatIcon = nil;
static UILabel *smFloatLabel = nil;
static UIView *smModalBackdrop = nil;
static NSLayoutConstraint *smCardBottomConstraint = nil;
static UILabel *smToastLabel = nil;
static BOOL hasCapturedOnce = NO;

static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *capturedCookies = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *silentHeaderCache = nil;
static NSArray<NSDictionary *> *cachedRepos = nil;

#pragma mark - 数据模型

@interface SMCookieGroupItem : NSObject
@property (nonatomic, copy) NSString *rootDomain;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *subtitleText;
@property (nonatomic, copy) NSString *cookieString;
@property (nonatomic, assign) BOOL isAuthRelated;
@property (nonatomic, assign) NSInteger priorityScore;
@end

@implementation SMCookieGroupItem
@end

#pragma mark - 穿透型顶层窗口

@interface SMPassthroughWindow : UIWindow
@end

@implementation SMPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;
    if (smModalBackdrop && !smModalBackdrop.hidden && smModalBackdrop.alpha > 0.05) {
        return [super hitTest:point withEvent:event];
    }
    if (smFloatBtn && !smFloatBtn.hidden) {
        CGPoint btnPoint = [self convertPoint:point toView:smFloatBtn];
        if ([smFloatBtn pointInside:btnPoint withEvent:event]) {
            return smFloatBtn;
        }
    }
    return nil;
}
@end

#pragma mark - 管理器声明

@interface SecretsManager : NSObject
+ (instancetype)shared;
- (void)ensureUIAndUnhide:(BOOL)unhide;
- (void)unhideFloatingBallWithToast:(BOOL)showToast;
- (void)cacheSilentRequest:(NSURLRequest *)request;
- (void)performManualCaptureClearCache:(BOOL)clearCache completion:(void (^)(void))completion;
@end

@implementation SecretsManager

+ (instancetype)shared {
    static SecretsManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SecretsManager alloc] init];
        capturedCookies = [NSMutableDictionary dictionary];
        silentHeaderCache = [NSMutableDictionary dictionary];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    }
    return self;
}

#pragma mark - 键盘平滑避让（保持所有弹窗默认底部统一位置）

- (void)onKeyboardWillShow:(NSNotification *)note {
    if (!smModalBackdrop || !smCardBottomConstraint) return;
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    smCardBottomConstraint.constant = -(kbFrame.size.height + 10.0);
    [UIView animateWithDuration:(dur > 0 ? dur : 0.25) animations:^{
        [smModalBackdrop layoutIfNeeded];
    }];
}

- (void)onKeyboardWillHide:(NSNotification *)note {
    if (!smModalBackdrop || !smCardBottomConstraint) return;
    NSTimeInterval dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    smCardBottomConstraint.constant = -34.0;
    [UIView animateWithDuration:(dur > 0 ? dur : 0.25) animations:^{
        [smModalBackdrop layoutIfNeeded];
    }];
}

#pragma mark - SF Symbols 辅助生成

- (UIImage *)sfSymbol:(NSString *)name color:(UIColor *)color size:(CGFloat)ptSize weight:(UIImageSymbolWeight)weight {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:ptSize weight:weight];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!img) {
        img = [UIImage systemImageNamed:@"circle.grid.cross.fill" withConfiguration:cfg];
    }
    return [img imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark - 悬浮胶囊 HUD 提示

- (void)showToast:(NSString *)msg duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!smWindow || !smWindow.rootViewController) return;
        UIView *parentView = smWindow.rootViewController.view;
        
        if (!smToastLabel) {
            smToastLabel = [[UILabel alloc] init];
            smToastLabel.backgroundColor = [[UIColor colorWithWhite:0.12 alpha:0.92] colorWithAlphaComponent:0.92];
            smToastLabel.textColor = [UIColor whiteColor];
            smToastLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
            smToastLabel.textAlignment = NSTextAlignmentCenter;
            smToastLabel.numberOfLines = 0;
            smToastLabel.layer.cornerRadius = 14;
            smToastLabel.layer.masksToBounds = YES;
            smToastLabel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
            smToastLabel.layer.borderWidth = 0.8;
            smToastLabel.userInteractionEnabled = NO;
            smToastLabel.alpha = 0.0;
            [parentView addSubview:smToastLabel];
        }
        
        smToastLabel.text = msg;
        CGFloat maxW = [UIScreen mainScreen].bounds.size.width - 50;
        CGSize fit = [smToastLabel sizeThatFits:CGSizeMake(maxW - 32, 260)];
        CGFloat w = MIN(maxW, MAX(150, fit.width + 32));
        CGFloat h = MAX(42, fit.height + 20);
        smToastLabel.frame = CGRectMake(([UIScreen mainScreen].bounds.size.width - w) / 2.0, 96, w, h);
        [parentView bringSubviewToFront:smToastLabel];
        
        static NSInteger toastToken = 0;
        toastToken++;
        NSInteger cur = toastToken;
        
        [UIView animateWithDuration:0.2 animations:^{
            smToastLabel.alpha = 1.0;
        }];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (cur == toastToken) {
                [UIView animateWithDuration:0.25 animations:^{
                    smToastLabel.alpha = 0.0;
                }];
            }
        });
    });
}

#pragma mark - 域名收敛与过滤（彻底屏蔽 github.com 自身请求）

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
    // 包含 github.com 与 githubusercontent.com，防止插件自身请求 GitHub API 时被抓入列表
    NSArray<NSString *> *junkList = @[
        @"github.com", @"githubusercontent.com", @"githubassets.com",
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
    NSString *host = [request.URL.host lowercaseString];
    // 直接忽略插件自身发往 GitHub 的 API 请求
    if ([host containsString:@"github.com"] || [self isJunkDomain:[self extractRootDomain:host]]) return;
    
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

// 支持选择是否彻底清空历史缓存后重新抓取
- (void)performManualCaptureClearCache:(BOOL)clearCache completion:(void (^)(void))completion {
    @synchronized (capturedCookies) {
        [capturedCookies removeAllObjects];
        @synchronized (silentHeaderCache) {
            if (clearCache) {
                // 彻底清空历史请求头残留缓存
                [silentHeaderCache removeAllObjects];
            } else {
                for (NSString *d in silentHeaderCache.allKeys) {
                    if (![self isJunkDomain:d]) {
                        capturedCookies[d] = [silentHeaderCache[d] mutableCopy];
                    }
                }
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

- (NSArray<SMCookieGroupItem *> *)buildCategorizedGroups {
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
        if ([self isJunkDomain:rootDomain]) continue;
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

    NSMutableArray<SMCookieGroupItem *> *items = [NSMutableArray array];

    for (NSString *cookieStr in cookieToDomains.allKeys) {
        NSArray<NSString *> *domains = cookieToDomains[cookieStr];
        NSString *primaryDomain = domains.firstObject;
        NSString *domainLabel = (domains.count > 1) ? [NSString stringWithFormat:@"%@ (+%lu同值)", primaryDomain, (unsigned long)domains.count - 1] : primaryDomain;

        NSInteger score = 0;
        NSString *lowerCookie = [cookieStr lowercaseString];
        NSMutableArray<NSString *> *matchedTags = [NSMutableArray array];

        for (NSString *kw in authKeywords) {
            if ([lowerCookie containsString:kw]) {
                score += 20;
                if (![matchedTags containsObject:kw]) [matchedTags addObject:kw];
            }
        }

        SMCookieGroupItem *item = [[SMCookieGroupItem alloc] init];
        item.rootDomain = primaryDomain;
        item.cookieString = cookieStr;
        item.priorityScore = score;
        item.isAuthRelated = (score > 0);

        NSUInteger fieldCount = [cookieStr componentsSeparatedByString:@";"].count;
        item.titleText = domainLabel;
        if (item.isAuthRelated && matchedTags.count > 0) {
            NSArray *subTags = [matchedTags subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)3, matchedTags.count))];
            item.subtitleText = [NSString stringWithFormat:@"推荐凭证 [含:%@] · 共%lu项", [subTags componentsJoinedByString:@", "], (unsigned long)fieldCount];
        } else {
            item.subtitleText = [NSString stringWithFormat:@"常规域名凭证 · 共%lu项", (unsigned long)fieldCount];
        }

        [items addObject:item];
    }

    [items sortUsingComparator:^NSComparisonResult(SMCookieGroupItem *a, SMCookieGroupItem *b) {
        if (a.priorityScore > b.priorityScore) return NSOrderedAscending;
        if (a.priorityScore < b.priorityScore) return NSOrderedDescending;
        return [a.rootDomain compare:b.rootDomain];
    }];

    return items;
}

#pragma mark - SF Symbol 悬浮球 UI 与显隐控制

- (void)updateFloatingButtonVisual {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!smFloatBtn) return;
        if (!hasCapturedOnce) {
            smFloatBtn.backgroundColor = [[UIColor colorWithRed:0.16 green:0.18 blue:0.22 alpha:0.90] colorWithAlphaComponent:0.90];
            smFloatIcon.image = [self sfSymbol:@"key.viewfinder" color:[UIColor whiteColor] size:20 weight:UIImageSymbolWeightSemibold];
            smFloatLabel.text = @"待抓取";
            return;
        }
        NSArray<SMCookieGroupItem *> *groups = [self buildCategorizedGroups];
        if (groups.count > 0) {
            smFloatBtn.backgroundColor = [[UIColor colorWithRed:0.12 green:0.68 blue:0.38 alpha:0.92] colorWithAlphaComponent:0.92];
            smFloatIcon.image = [self sfSymbol:@"checkmark.shield.fill" color:[UIColor whiteColor] size:20 weight:UIImageSymbolWeightSemibold];
            smFloatLabel.text = [NSString stringWithFormat:@"已抓(%lu)", (unsigned long)groups.count];
        } else {
            smFloatBtn.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.92];
            smFloatIcon.image = [self sfSymbol:@"exclamationmark.triangle.fill" color:[UIColor whiteColor] size:19 weight:UIImageSymbolWeightSemibold];
            smFloatLabel.text = @"未抓到";
        }
    });
}

- (void)unhideFloatingBallWithToast:(BOOL)showToast {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (smFloatBtn && smFloatBtn.hidden) {
            smFloatBtn.hidden = NO;
            smFloatBtn.transform = CGAffineTransformMakeScale(0.5, 0.5);
            [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0.8 options:0 animations:^{
                smFloatBtn.transform = CGAffineTransformIdentity;
            } completion:nil];
            if (showToast) {
                [self showToast:@"浮窗已复现" duration:1.3];
            }
        }
    });
}

- (void)ensureUIAndUnhide:(BOOL)unhide {
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
        
        if (smWindow) {
            if (activeScene && smWindow.windowScene != activeScene) smWindow.windowScene = activeScene;
            smWindow.windowLevel = UIWindowLevelStatusBar + 200;
            if (unhide && smFloatBtn) {
                smFloatBtn.hidden = NO;
            }
            return;
        }
        
        if (activeScene) {
            smWindow = [[SMPassthroughWindow alloc] initWithWindowScene:activeScene];
        } else {
            smWindow = [[SMPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        
        smWindow.frame = [UIScreen mainScreen].bounds;
        smWindow.windowLevel = UIWindowLevelStatusBar + 200;
        smWindow.backgroundColor = [UIColor clearColor];
        
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        smWindow.rootViewController = vc;
        
        smFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        smFloatBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 74, 165, 60, 60);
        smFloatBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.18 blue:0.22 alpha:0.90];
        smFloatBtn.layer.cornerRadius = 30;
        smFloatBtn.layer.masksToBounds = YES;
        smFloatBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        smFloatBtn.layer.borderWidth = 1.2;
        
        smFloatIcon = [[UIImageView alloc] initWithFrame:CGRectMake(18, 9, 24, 24)];
        smFloatIcon.contentMode = UIViewContentModeScaleAspectFit;
        smFloatIcon.image = [self sfSymbol:@"key.viewfinder" color:[UIColor whiteColor] size:20 weight:UIImageSymbolWeightSemibold];
        [smFloatBtn addSubview:smFloatIcon];
        
        smFloatLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 35, 56, 16)];
        smFloatLabel.text = @"待抓取";
        smFloatLabel.textColor = [UIColor whiteColor];
        smFloatLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold];
        smFloatLabel.textAlignment = NSTextAlignmentCenter;
        [smFloatBtn addSubview:smFloatLabel];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
        [smFloatBtn addGestureRecognizer:pan];
        
        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBtnClick)];
        singleTap.numberOfTapsRequired = 1;
        singleTap.numberOfTouchesRequired = 1;
        [smFloatBtn addGestureRecognizer:singleTap];
        
        [vc.view addSubview:smFloatBtn];
        smWindow.hidden = NO;
    });
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan translationInView:smWindow];
    smFloatBtn.center = CGPointMake(smFloatBtn.center.x + p.x, smFloatBtn.center.y + p.y);
    [pan setTranslation:CGPointZero inView:smWindow];
}

- (void)onBtnClick {
    smFloatBtn.userInteractionEnabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        smFloatBtn.userInteractionEnabled = YES;
    });
    
    [self performManualCaptureClearCache:NO completion:^{
        [self showMainMenu];
    }];
}

#pragma mark - 统一底部毛玻璃卡片引擎（所有弹窗 100% 位置一致）

- (void)dismissCustomModalWithCompletion:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        [smWindow endEditing:YES];
        if (!smModalBackdrop || smModalBackdrop.hidden) {
            smCardBottomConstraint = nil;
            if (completion) completion();
            return;
        }
        [UIView animateWithDuration:0.18 animations:^{
            smModalBackdrop.alpha = 0.0;
        } completion:^(BOOL finished) {
            [smModalBackdrop removeFromSuperview];
            smModalBackdrop = nil;
            smCardBottomConstraint = nil;
            if (completion) completion();
        }];
    });
}

- (void)onBackdropTap {
    [self dismissCustomModalWithCompletion:nil];
}

// 构建带 SF Symbol 的列表行按钮（超长文本自动尾部省略号截断）
- (UIView *)createActionRowWithSymbol:(NSString *)symbolName
                            tintColor:(UIColor *)tintColor
                                title:(NSString *)title
                             subtitle:(NSString *)subtitle
                               action:(void (^)(void))actionBlock {
    UIButton *rowBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    rowBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.09];
    rowBtn.layer.cornerRadius = 13;
    rowBtn.clipsToBounds = YES;
    rowBtn.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat rowHeight = (subtitle && subtitle.length > 0) ? 58.0 : 48.0;
    [rowBtn.heightAnchor constraintEqualToConstant:rowHeight].active = YES;
    
    UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(12, (rowHeight - 34) / 2.0, 34, 34)];
    iconBg.backgroundColor = [tintColor colorWithAlphaComponent:0.18];
    iconBg.layer.cornerRadius = 9;
    iconBg.userInteractionEnabled = NO;
    [rowBtn addSubview:iconBg];
    
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(5, 5, 24, 24)];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.image = [self sfSymbol:symbolName color:tintColor size:16 weight:UIImageSymbolWeightSemibold];
    [iconBg addSubview:iv];
    
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat cardW = MIN(screenW - 28, 390);
    CGFloat textMaxW = cardW - 32 - 56 - 28;
    
    if (subtitle && subtitle.length > 0) {
        UILabel *tLbl = [[UILabel alloc] initWithFrame:CGRectMake(56, 9, textMaxW, 20)];
        tLbl.text = [NSString stringWithFormat:@"%@", title ?: @""];
        tLbl.textColor = [UIColor whiteColor];
        tLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        tLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        tLbl.userInteractionEnabled = NO;
        [rowBtn addSubview:tLbl];
        
        UILabel *sLbl = [[UILabel alloc] initWithFrame:CGRectMake(56, 31, textMaxW, 17)];
        sLbl.text = [NSString stringWithFormat:@"%@", subtitle ?: @""];
        sLbl.textColor = [UIColor colorWithWhite:0.74 alpha:1.0];
        sLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        sLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        sLbl.userInteractionEnabled = NO;
        [rowBtn addSubview:sLbl];
    } else {
        UILabel *tLbl = [[UILabel alloc] initWithFrame:CGRectMake(56, (rowHeight - 20) / 2.0, textMaxW, 20)];
        tLbl.text = [NSString stringWithFormat:@"%@", title ?: @""];
        tLbl.textColor = [UIColor whiteColor];
        tLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        tLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        tLbl.userInteractionEnabled = NO;
        [rowBtn addSubview:tLbl];
    }
    
    UIImageView *chevron = [[UIImageView alloc] initWithFrame:CGRectMake(cardW - 32 - 22, (rowHeight - 14) / 2.0, 12, 14)];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.image = [self sfSymbol:@"chevron.right" color:[UIColor colorWithWhite:0.55 alpha:1.0] size:12 weight:UIImageSymbolWeightBold];
    chevron.userInteractionEnabled = NO;
    [rowBtn addSubview:chevron];
    
    objc_setAssociatedObject(rowBtn, "sm_action_block", actionBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [rowBtn addTarget:self action:@selector(onRowBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
    return rowBtn;
}

// 构建底部左右各半 (50% : 50%) 的并排按钮栏
- (UIView *)createDualBottomBarWithLeftSymbol:(NSString *)leftSym
                                    leftTitle:(NSString *)leftTitle
                                    leftColor:(UIColor *)leftColor
                                   leftAction:(void (^)(void))leftBlock
                                  rightSymbol:(NSString *)rightSym
                                   rightTitle:(NSString *)rightTitle
                                   rightColor:(UIColor *)rightColor
                                  rightAction:(void (^)(void))rightBlock {
    UIStackView *dualStack = [[UIStackView alloc] init];
    dualStack.axis = UILayoutConstraintAxisHorizontal;
    dualStack.distribution = UIStackViewDistributionFillEqually;
    dualStack.spacing = 10;
    dualStack.translatesAutoresizingMaskIntoConstraints = NO;
    [dualStack.heightAnchor constraintEqualToConstant:46.0].active = YES;
    
    UIButton * (^makeHalfBtn)(NSString *, NSString *, UIColor *, void (^)(void)) = ^UIButton *(NSString *sym, NSString *title, UIColor *color, void (^blk)(void)) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.backgroundColor = [color colorWithAlphaComponent:0.18];
        btn.layer.cornerRadius = 12;
        btn.layer.borderColor = [color colorWithAlphaComponent:0.35].CGColor;
        btn.layer.borderWidth = 0.8;
        [btn setTitle:[NSString stringWithFormat:@" %@", title] forState:UIControlStateNormal];
        [btn setTitleColor:color forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        btn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        UIImage *img = [self sfSymbol:sym color:color size:14 weight:UIImageSymbolWeightSemibold];
        [btn setImage:img forState:UIControlStateNormal];
        objc_setAssociatedObject(btn, "sm_action_block", blk, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [btn addTarget:self action:@selector(onRowBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
        return btn;
    };
    
    [dualStack addArrangedSubview:makeHalfBtn(leftSym, leftTitle, leftColor, leftBlock)];
    [dualStack addArrangedSubview:makeHalfBtn(rightSym, rightTitle, rightColor, rightBlock)];
    return dualStack;
}

- (void)onRowBtnTapped:(UIButton *)sender {
    void (^blk)(void) = objc_getAssociatedObject(sender, "sm_action_block");
    if (blk) blk();
}

// 统一底部弹窗容器（支持传入列表项或自定义输入视图，始终固定在屏幕中下方 -34）
- (void)presentBottomUnifiedCardWithSymbol:(NSString *)headerSym
                                headerTint:(UIColor *)headerTint
                                     title:(NSString *)title
                                  subtitle:(NSString *)subtitle
                                bodyView:(UIView *)bodyView
                                bottomView:(UIView *)bottomView {
    [self dismissCustomModalWithCompletion:^{
        UIView *rootView = smWindow.rootViewController.view;
        [smWindow makeKeyWindow];
        
        smModalBackdrop = [[UIView alloc] initWithFrame:rootView.bounds];
        smModalBackdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        smModalBackdrop.alpha = 0.0;
        [rootView addSubview:smModalBackdrop];
        
        UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBackdropTap)];
        UIView *bgTouchView = [[UIView alloc] initWithFrame:smModalBackdrop.bounds];
        [bgTouchView addGestureRecognizer:bgTap];
        [smModalBackdrop addSubview:bgTouchView];
        
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat cardW = MIN(screenW - 28, 390);
        
        UIVisualEffectView *cardView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        cardView.layer.cornerRadius = 22;
        cardView.layer.masksToBounds = YES;
        cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        cardView.layer.borderWidth = 1.0;
        cardView.translatesAutoresizingMaskIntoConstraints = NO;
        [smModalBackdrop addSubview:cardView];
        
        [cardView.centerXAnchor constraintEqualToAnchor:smModalBackdrop.centerXAnchor].active = YES;
        smCardBottomConstraint = [cardView.bottomAnchor constraintEqualToAnchor:smModalBackdrop.bottomAnchor constant:-34.0];
        smCardBottomConstraint.active = YES;
        [cardView.widthAnchor constraintEqualToConstant:cardW].active = YES;
        
        UIView *headerBox = [[UIView alloc] init];
        headerBox.translatesAutoresizingMaskIntoConstraints = NO;
        
        UIImageView *hIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 2, 22, 22)];
        hIcon.contentMode = UIViewContentModeScaleAspectFit;
        hIcon.image = [self sfSymbol:headerSym color:headerTint size:18 weight:UIImageSymbolWeightBold];
        [headerBox addSubview:hIcon];
        
        UILabel *hTitle = [[UILabel alloc] initWithFrame:CGRectMake(28, 0, cardW - 60, 24)];
        hTitle.text = title;
        hTitle.textColor = [UIColor whiteColor];
        hTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        hTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        [headerBox addSubview:hTitle];
        
        UILabel *hSub = [[UILabel alloc] initWithFrame:CGRectMake(0, 28, cardW - 32, 34)];
        hSub.text = subtitle;
        hSub.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
        hSub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        hSub.numberOfLines = 2;
        hSub.lineBreakMode = NSLineBreakByTruncatingTail;
        [headerBox addSubview:hSub];
        [headerBox.heightAnchor constraintEqualToConstant:62].active = YES;
        
        UIStackView *mainStack = [[UIStackView alloc] initWithArrangedSubviews:@[headerBox, bodyView, bottomView]];
        mainStack.axis = UILayoutConstraintAxisVertical;
        mainStack.spacing = 12;
        mainStack.translatesAutoresizingMaskIntoConstraints = NO;
        [cardView.contentView addSubview:mainStack];
        
        [mainStack.topAnchor constraintEqualToAnchor:cardView.contentView.topAnchor constant:16].active = YES;
        [mainStack.bottomAnchor constraintEqualToAnchor:cardView.contentView.bottomAnchor constant:-16].active = YES;
        [mainStack.leadingAnchor constraintEqualToAnchor:cardView.contentView.leadingAnchor constant:16].active = YES;
        [mainStack.trailingAnchor constraintEqualToAnchor:cardView.contentView.trailingAnchor constant:-16].active = YES;
        
        cardView.transform = CGAffineTransformMakeTranslation(0, 40);
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.8 options:0 animations:^{
            smModalBackdrop.alpha = 1.0;
            cardView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

- (void)presentCardWithHeaderSymbol:(NSString *)headerSym
                          headerTint:(UIColor *)headerTint
                               title:(NSString *)title
                            subtitle:(NSString *)subtitle
                            rowViews:(NSArray<UIView *> *)rowViews
                          bottomView:(UIView *)bottomView {
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsVerticalScrollIndicator = YES;
    
    UIStackView *listStack = [[UIStackView alloc] init];
    listStack.axis = UILayoutConstraintAxisVertical;
    listStack.spacing = 8;
    listStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:listStack];
    
    CGFloat estimatedListH = 0;
    for (UIView *rv in rowViews) {
        [listStack addArrangedSubview:rv];
        estimatedListH += 58.0;
    }
    if (rowViews.count > 1) estimatedListH += (rowViews.count - 1) * 8.0;
    CGFloat maxScrollH = MIN(estimatedListH, screenH * 0.46);
    
    [listStack.topAnchor constraintEqualToAnchor:scrollView.topAnchor].active = YES;
    [listStack.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor].active = YES;
    [listStack.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor].active = YES;
    [listStack.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor].active = YES;
    [listStack.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor].active = YES;
    [scrollView.heightAnchor constraintEqualToConstant:maxScrollH].active = YES;
    
    [self presentBottomUnifiedCardWithSymbol:headerSym
                                  headerTint:headerTint
                                       title:title
                                    subtitle:subtitle
                                    bodyView:scrollView
                                  bottomView:bottomView];
}

#pragma mark - 主菜单（带清除缓存重抓 + 隐藏与取消左右各半）

- (void)showMainMenu {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        NSString *boundDomain = [defs stringForKey:@"sm_bound_domain"];
        NSString *boundRepo = [defs stringForKey:@"sm_bound_repo"];
        NSString *boundSecret = [defs stringForKey:@"sm_bound_secret"];
        
        NSArray<SMCookieGroupItem *> *groups = [self buildCategorizedGroups];
        NSString *subMsg = [NSString stringWithFormat:@"当前页已归类 %lu 组主域名凭证 · 支持多账号换行同步", (unsigned long)groups.count];
        if (boundDomain && boundRepo && boundSecret) {
            subMsg = [NSString stringWithFormat:@"已绑定: [%@] ➔ %@ (%@)", boundDomain, boundRepo, boundSecret];
        }
        
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        
        if (boundDomain && boundRepo && boundSecret) {
            [rows addObject:[self createActionRowWithSymbol:@"bolt.fill"
                                                  tintColor:[UIColor systemOrangeColor]
                                                      title:[NSString stringWithFormat:@"一键直推 [%@] 最新凭证", boundDomain]
                                                   subtitle:[NSString stringWithFormat:@"目标: %@ ➔ %@", boundRepo, boundSecret]
                                                     action:^{
                NSString *targetCookie = nil;
                for (SMCookieGroupItem *item in groups) {
                    if ([item.rootDomain isEqualToString:boundDomain]) {
                        targetCookie = item.cookieString;
                        break;
                    }
                }
                if (!targetCookie && groups.count > 0) {
                    targetCookie = groups.firstObject.cookieString;
                }
                if (!targetCookie || targetCookie.length == 0) {
                    [self showToast:@"未抓到有效凭证，请先打开个人中心" duration:2.0];
                    return;
                }
                [self dismissCustomModalWithCompletion:^{
                    [self pushCookie:targetCookie sourceLabel:boundDomain toFullRepo:boundRepo secretName:boundSecret rememberBinding:YES];
                }];
            }]];
        }
        
        [rows addObject:[self createActionRowWithSymbol:@"paperplane.fill"
                                              tintColor:[UIColor colorWithRed:0.25 green:0.62 blue:1.0 alpha:1.0]
                                                  title:@"抓取结果归类 ➔ 同步至 GitHub"
                                               subtitle:[NSString stringWithFormat:@"查看当前抓取的 %lu 组凭证并选择目标 Secret", (unsigned long)groups.count]
                                                 action:^{
            [self showCookieGroupListForPush:YES];
        }]];
        
        [rows addObject:[self createActionRowWithSymbol:@"square.and.pencil"
                                              tintColor:[UIColor colorWithRed:0.68 green:0.45 blue:1.0 alpha:1.0]
                                                  title:@"手动输入 / 多账号换行同步"
                                               subtitle:@"支持多账号 Cookie 换行拼接，一键推送至 COOKIES 等变量"
                                                 action:^{
            [self showManualMultiAccountEditor];
        }]];
        
        [rows addObject:[self createActionRowWithSymbol:@"doc.on.doc.fill"
                                              tintColor:[UIColor colorWithRed:0.20 green:0.80 blue:0.70 alpha:1.0]
                                                  title:@"抓取结果归类 ➔ 复制到剪贴板"
                                               subtitle:@"单独提取某个主域名的 Cookie 字符串"
                                                 action:^{
            [self showCookieGroupListForPush:NO];
        }]];
        
        // 修改点2：清除已有缓存后重新抓取当前页
        [rows addObject:[self createActionRowWithSymbol:@"trash.slash.fill"
                                              tintColor:[UIColor systemGreenColor]
                                                  title:@"清除缓存并重新抓取当前页"
                                               subtitle:@"清空历史残留缓存，仅提取当前页面最新凭证"
                                                 action:^{
            [self performManualCaptureClearCache:YES completion:^{
                [self showMainMenu];
                [self showToast:@"已清空旧缓存并重新抓取当前页" duration:1.5];
            }];
        }]];
        
        [rows addObject:[self createActionRowWithSymbol:@"key.fill"
                                              tintColor:[UIColor systemYellowColor]
                                                  title:@"配置 GitHub 访问令牌 (PAT)"
                                               subtitle:@"设置或从剪贴板导入 ghp_ 令牌"
                                                 action:^{
            [self showTokenConfigModal];
        }]];
        
        UIView *bottomDual = [self createDualBottomBarWithLeftSymbol:@"eye.slash.fill"
                                                           leftTitle:@"隐藏 (双指双击复现)"
                                                           leftColor:[UIColor colorWithRed:1.0 green:0.62 blue:0.25 alpha:1.0]
                                                          leftAction:^{
            [self dismissCustomModalWithCompletion:^{
                smFloatBtn.hidden = YES;
                [self showToast:@"浮窗已隐藏\n屏幕双指双击或重开App即可复现" duration:2.2];
            }];
        }
                                                         rightSymbol:@"xmark.circle.fill"
                                                          rightTitle:@"取消"
                                                          rightColor:[UIColor colorWithWhite:0.82 alpha:1.0]
                                                         rightAction:^{
            [self dismissCustomModalWithCompletion:nil];
        }];
        
        [self presentCardWithHeaderSymbol:@"lock.shield.fill"
                               headerTint:[UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:1.0]
                                    title:@"Secrets 管理器"
                                 subtitle:subMsg
                                 rowViews:rows
                               bottomView:bottomDual];
    });
}

#pragma mark - 多账号 / 多行手动输入面板（与主菜单统一底部弹出，框内上下滑动查看）

- (void)showManualMultiAccountEditor {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIStackView *bodyStack = [[UIStackView alloc] init];
        bodyStack.axis = UILayoutConstraintAxisVertical;
        bodyStack.spacing = 10;
        bodyStack.translatesAutoresizingMaskIntoConstraints = NO;
        
        UILabel *statusLbl = [[UILabel alloc] init];
        statusLbl.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.68 alpha:1.0];
        statusLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        statusLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        statusLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [statusLbl.heightAnchor constraintEqualToConstant:16].active = YES;
        [bodyStack addArrangedSubview:statusLbl];
        
        // 固定高度多行编辑框，支持框内上下滚动查看超长 Cookie
        UITextView *tv = [[UITextView alloc] init];
        tv.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.78];
        tv.textColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.68 alpha:1.0];
        tv.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
        tv.layer.cornerRadius = 12;
        tv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        tv.layer.borderWidth = 0.8;
        tv.scrollEnabled = YES;
        tv.showsVerticalScrollIndicator = YES;
        tv.alwaysBounceVertical = YES;
        tv.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
        tv.autocorrectionType = UITextAutocorrectionTypeNo;
        tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tv.text = [[NSUserDefaults standardUserDefaults] stringForKey:@"sm_manual_draft"] ?: @"";
        tv.translatesAutoresizingMaskIntoConstraints = NO;
        [tv.heightAnchor constraintEqualToConstant:145.0].active = YES;
        [bodyStack addArrangedSubview:tv];
        
        void (^updateLineCounter)(void) = ^{
            NSString *raw = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (raw.length == 0) {
                statusLbl.text = @"当前为空 · 可框内滑动查看，支持追加抓取或剪贴板粘贴";
                return;
            }
            NSArray *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSUInteger validLines = 0;
            for (NSString *l in lines) {
                if ([l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 0) validLines++;
            }
            statusLbl.text = [NSString stringWithFormat:@"已填入 %lu 个账号行 (共 %lu 字符) · 框内可上下滑动查看", (unsigned long)validLines, (unsigned long)raw.length];
            [[NSUserDefaults standardUserDefaults] setObject:tv.text forKey:@"sm_manual_draft"];
        };
        updateLineCounter();
        
        UIStackView *toolStack = [[UIStackView alloc] init];
        toolStack.axis = UILayoutConstraintAxisHorizontal;
        toolStack.distribution = UIStackViewDistributionFillEqually;
        toolStack.spacing = 8;
        toolStack.translatesAutoresizingMaskIntoConstraints = NO;
        [toolStack.heightAnchor constraintEqualToConstant:38.0].active = YES;
        [bodyStack addArrangedSubview:toolStack];
        
        UIButton * (^makeToolBtn)(NSString *, NSString *, UIColor *, void (^)(void)) = ^UIButton *(NSString *sym, NSString *title, UIColor *c, void (^blk)(void)) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.backgroundColor = [c colorWithAlphaComponent:0.16];
            b.layer.cornerRadius = 9;
            [b setTitle:[NSString stringWithFormat:@" %@", title] forState:UIControlStateNormal];
            [b setTitleColor:c forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
            b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            [b setImage:[self sfSymbol:sym color:c size:12 weight:UIImageSymbolWeightSemibold] forState:UIControlStateNormal];
            objc_setAssociatedObject(b, "sm_action_block", blk, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [b addTarget:self action:@selector(onRowBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
            return b;
        };
        
        [toolStack addArrangedSubview:makeToolBtn(@"plus.viewfinder", @"追加当前抓取", [UIColor systemGreenColor], ^{
            NSArray<SMCookieGroupItem *> *groups = [self buildCategorizedGroups];
            if (groups.count == 0) {
                [self showToast:@"当前未抓到 Cookie，请先在个人中心抓取" duration:1.8];
                return;
            }
            NSString *bestCookie = groups.firstObject.cookieString;
            NSString *existing = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            tv.text = (existing.length > 0) ? [NSString stringWithFormat:@"%@\n%@", existing, bestCookie] : bestCookie;
            updateLineCounter();
            if (tv.text.length > 0) {
                [tv scrollRangeToVisible:NSMakeRange(tv.text.length - 1, 1)];
            }
            [self showToast:[NSString stringWithFormat:@"已换行追加 [%@] 凭证", groups.firstObject.rootDomain] duration:1.4];
        })];
        
        [toolStack addArrangedSubview:makeToolBtn(@"doc.on.clipboard.fill", @"粘贴并换行", [UIColor colorWithRed:0.35 green:0.72 blue:1.0 alpha:1.0], ^{
            NSString *clip = [[UIPasteboard generalPasteboard].string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!clip || clip.length == 0) {
                [self showToast:@"剪贴板为空" duration:1.4];
                return;
            }
            NSString *existing = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            tv.text = (existing.length > 0) ? [NSString stringWithFormat:@"%@\n%@", existing, clip] : clip;
            updateLineCounter();
            if (tv.text.length > 0) {
                [tv scrollRangeToVisible:NSMakeRange(tv.text.length - 1, 1)];
            }
            [self showToast:@"已从剪贴板换行追加" duration:1.3];
        })];
        
        [toolStack addArrangedSubview:makeToolBtn(@"trash.fill", @"清空内容", [UIColor systemRedColor], ^{
            tv.text = @"";
            [[NSUserDefaults standardUserDefaults] setObject:@"" forKey:@"sm_manual_draft"];
            updateLineCounter();
            [tv resignFirstResponder];
        })];
        
        UIView *bottomDual = [self createDualBottomBarWithLeftSymbol:@"arrow.uturn.backward.circle.fill"
                                                           leftTitle:@"返回主菜单"
                                                           leftColor:[UIColor colorWithWhite:0.85 alpha:1.0]
                                                          leftAction:^{
            [[NSUserDefaults standardUserDefaults] setObject:tv.text forKey:@"sm_manual_draft"];
            [self showMainMenu];
        }
                                                         rightSymbol:@"paperplane.fill"
                                                          rightTitle:@"选仓库并同步"
                                                          rightColor:[UIColor colorWithRed:0.30 green:0.88 blue:0.55 alpha:1.0]
                                                         rightAction:^{
            NSString *finalText = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [[NSUserDefaults standardUserDefaults] setObject:finalText forKey:@"sm_manual_draft"];
            if (finalText.length == 0) {
                [self showToast:@"请先输入或追加至少一行 Cookie 内容" duration:1.8];
                return;
            }
            NSUInteger linesCount = [finalText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]].count;
            NSString *label = [NSString stringWithFormat:@"多账号手动输入(%lu行)", (unsigned long)linesCount];
            [self showGitHubReposForCookie:finalText sourceLabel:label rememberBinding:NO forceRefresh:NO];
        }];
        
        [self presentBottomUnifiedCardWithSymbol:@"square.and.pencil"
                                      headerTint:[UIColor colorWithRed:0.68 green:0.45 blue:1.0 alpha:1.0]
                                           title:@"多账号 / 手动输入同步"
                                        subtitle:@"每行代表 1 个账号 Cookie，支持换行拼接同步至 COOKIES"
                                        bodyView:bodyStack
                                      bottomView:bottomDual];
    });
}

#pragma mark - 三级联动选择面板

- (void)showCookieGroupListForPush:(BOOL)forPush {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<SMCookieGroupItem *> *groups = [self buildCategorizedGroups];
        if (groups.count == 0) {
            [self showToast:@"未抓到任何有效 Cookie\n请先点开『个人中心/我的』后再点悬浮球" duration:2.2];
            return;
        }
        
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        for (SMCookieGroupItem *item in groups) {
            NSString *sym = item.isAuthRelated ? @"star.fill" : @"doc.text.fill";
            UIColor *tint = item.isAuthRelated ? [UIColor systemYellowColor] : [UIColor colorWithWhite:0.75 alpha:1.0];
            
            [rows addObject:[self createActionRowWithSymbol:sym
                                                  tintColor:tint
                                                      title:item.titleText
                                                   subtitle:item.subtitleText
                                                     action:^{
                if (!forPush) {
                    [UIPasteboard generalPasteboard].string = item.cookieString;
                    [self dismissCustomModalWithCompletion:^{
                        [self showToast:[NSString stringWithFormat:@"已复制 [%@] 凭证 (%lu字符)", item.rootDomain, (unsigned long)item.cookieString.length] duration:1.8];
                    }];
                } else {
                    [self showGitHubReposForCookie:item.cookieString sourceLabel:item.rootDomain rememberBinding:YES forceRefresh:NO];
                }
            }]];
        }
        
        UIView *bottomDual = [self createDualBottomBarWithLeftSymbol:@"arrow.uturn.backward.circle.fill"
                                                           leftTitle:@"返回主菜单"
                                                           leftColor:[UIColor colorWithRed:0.40 green:0.75 blue:1.0 alpha:1.0]
                                                          leftAction:^{
            [self showMainMenu];
        }
                                                         rightSymbol:@"xmark.circle.fill"
                                                          rightTitle:@"取消"
                                                          rightColor:[UIColor colorWithWhite:0.82 alpha:1.0]
                                                         rightAction:^{
            [self dismissCustomModalWithCompletion:nil];
        }];
        
        [self presentCardWithHeaderSymbol:forPush ? @"1.circle.fill" : @"doc.on.doc.fill"
                               headerTint:[UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0]
                                    title:forPush ? @"选择要推送的域名凭证" : @"选择要复制的域名凭证"
                                 subtitle:@"已按一级主域名合并并过滤干扰项，高价值凭证已置顶"
                                 rowViews:rows
                               bottomView:bottomDual];
    });
}

- (void)presentRepoCardWithRepos:(NSArray<NSDictionary *> *)repos cookie:(NSString *)cookieStr sourceLabel:(NSString *)sourceLabel rememberBinding:(BOOL)remember {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        
        for (NSDictionary *repoDict in repos) {
            NSString *fullName = [NSString stringWithFormat:@"%@", repoDict[@"full_name"] ?: @""];
            NSString *repoName = [NSString stringWithFormat:@"%@", repoDict[@"name"] ?: fullName];
            BOOL isPrivate = [repoDict[@"private"] boolValue];
            NSString *sym = isPrivate ? @"lock.fill" : @"folder.fill";
            UIColor *tint = isPrivate ? [UIColor systemOrangeColor] : [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0];
            
            [rows addObject:[self createActionRowWithSymbol:sym
                                                  tintColor:tint
                                                      title:repoName
                                                   subtitle:fullName
                                                     action:^{
                [self fetchSecretsForFullRepo:fullName cookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember];
            }]];
        }
        
        [rows addObject:[self createActionRowWithSymbol:@"arrow.clockwise"
                                              tintColor:[UIColor systemGreenColor]
                                                  title:@"刷新 GitHub 仓库列表"
                                               subtitle:@"重新从云端拉取最新创建的仓库"
                                                 action:^{
            [self showGitHubReposForCookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember forceRefresh:YES];
        }]];
        
        UIView *bottomDual = [self createDualBottomBarWithLeftSymbol:@"arrow.uturn.backward.circle.fill"
                                                           leftTitle:@"返回上一步"
                                                           leftColor:[UIColor colorWithRed:0.40 green:0.75 blue:1.0 alpha:1.0]
                                                          leftAction:^{
            if (remember) {
                [self showCookieGroupListForPush:YES];
            } else {
                [self showManualMultiAccountEditor];
            }
        }
                                                         rightSymbol:@"xmark.circle.fill"
                                                          rightTitle:@"取消"
                                                          rightColor:[UIColor colorWithWhite:0.82 alpha:1.0]
                                                         rightAction:^{
            [self dismissCustomModalWithCompletion:nil];
        }];
        
        [self presentCardWithHeaderSymbol:@"2.circle.fill"
                               headerTint:[UIColor systemOrangeColor]
                                    title:@"选择目标 GitHub 仓库"
                                 subtitle:[NSString stringWithFormat:@"来源: [%@] · 共 %lu 个仓库", sourceLabel, (unsigned long)repos.count]
                                 rowViews:rows
                               bottomView:bottomDual];
    });
}

- (void)showGitHubReposForCookie:(NSString *)cookieStr sourceLabel:(NSString *)sourceLabel rememberBinding:(BOOL)remember forceRefresh:(BOOL)forceRefresh {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *token = [defs stringForKey:@"sm_gh_token"] ?: [defs stringForKey:@"uc_gh_token"];
    if (!token || token.length == 0) {
        [self showTokenConfigModal];
        return;
    }
    
    if (cachedRepos && cachedRepos.count > 0 && !forceRefresh) {
        [self presentRepoCardWithRepos:cachedRepos cookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember];
        return;
    }
    
    [self showToast:@"正在加载 GitHub 仓库列表..." duration:1.2];
    
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/user/repos?per_page=100&sort=updated&affiliation=owner"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (error || httpResp.statusCode != 200 || !data) {
                [self showToast:[NSString stringWithFormat:@"加载仓库失败 (HTTP %ld)", (long)httpResp.statusCode] duration:2.5];
                return;
            }
            
            NSArray *repos = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![repos isKindOfClass:[NSArray class]] || repos.count == 0) {
                [self showToast:@"未找到任何仓库" duration:2.0];
                return;
            }
            
            cachedRepos = repos;
            [self presentRepoCardWithRepos:repos cookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember];
        });
    }] resume];
}

- (void)fetchSecretsForFullRepo:(NSString *)fullRepo cookie:(NSString *)cookieStr sourceLabel:(NSString *)sourceLabel rememberBinding:(BOOL)remember {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *token = [defs stringForKey:@"sm_gh_token"] ?: [defs stringForKey:@"uc_gh_token"];
    [self showToast:[NSString stringWithFormat:@"正在读取 [%@] 的 Secrets...", fullRepo] duration:1.0];
    
    NSString *urlStr = [NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/secrets", fullRepo];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (error || httpResp.statusCode != 200 || !data) {
                [self showToast:[NSString stringWithFormat:@"读取 Secrets 失败 (HTTP %ld)", (long)httpResp.statusCode] duration:2.5];
                return;
            }
            
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *secrets = json[@"secrets"];
            
            NSMutableArray<UIView *> *rows = [NSMutableArray array];
            BOOL hasCookiesSecret = NO;
            
            if ([secrets isKindOfClass:[NSArray class]] && secrets.count > 0) {
                for (NSDictionary *secDict in secrets) {
                    NSString *secName = [NSString stringWithFormat:@"%@", secDict[@"name"] ?: @""];
                    if ([secName isEqualToString:@"COOKIES"]) hasCookiesSecret = YES;
                    NSString *updatedAt = [NSString stringWithFormat:@"%@", secDict[@"updated_at"] ?: @""];
                    if (updatedAt.length >= 10) updatedAt = [updatedAt substringToIndex:10];
                    
                    [rows addObject:[self createActionRowWithSymbol:@"key.fill"
                                                          tintColor:[UIColor systemGreenColor]
                                                              title:secName
                                                           subtitle:[NSString stringWithFormat:@"已有变量 · 最近更新: %@", updatedAt]
                                                             action:^{
                        [self dismissCustomModalWithCompletion:^{
                            [self pushCookie:cookieStr sourceLabel:sourceLabel toFullRepo:fullRepo secretName:secName rememberBinding:remember];
                        }];
                    }]];
                }
            }
            
            if (!hasCookiesSecret) {
                [rows addObject:[self createActionRowWithSymbol:@"sparkles"
                                                      tintColor:[UIColor systemYellowColor]
                                                          title:@"一键创建并推送至: COOKIES"
                                                       subtitle:@"多账号脚本常用默认 Secret 名称"
                                                         action:^{
                    [self dismissCustomModalWithCompletion:^{
                        [self pushCookie:cookieStr sourceLabel:sourceLabel toFullRepo:fullRepo secretName:@"COOKIES" rememberBinding:remember];
                    }];
                }]];
            }
            
            [rows addObject:[self createActionRowWithSymbol:@"plus.circle.fill"
                                                  tintColor:[UIColor colorWithRed:0.68 green:0.45 blue:1.0 alpha:1.0]
                                                      title:@"新建自定义名称的 Secret..."
                                                   subtitle:@"手动输入大写变量名并加密写入"
                                                     action:^{
                [self showNewSecretModalForFullRepo:fullRepo cookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember];
            }]];
            
            UIView *bottomDual = [self createDualBottomBarWithLeftSymbol:@"arrow.uturn.backward.circle.fill"
                                                               leftTitle:@"返回选仓库"
                                                               leftColor:[UIColor colorWithRed:0.40 green:0.75 blue:1.0 alpha:1.0]
                                                              leftAction:^{
                [self showGitHubReposForCookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember forceRefresh:NO];
            }
                                                             rightSymbol:@"xmark.circle.fill"
                                                              rightTitle:@"取消"
                                                              rightColor:[UIColor colorWithWhite:0.82 alpha:1.0]
                                                             rightAction:^{
                [self dismissCustomModalWithCompletion:nil];
            }];
            
            [self presentCardWithHeaderSymbol:@"3.circle.fill"
                                   headerTint:[UIColor systemGreenColor]
                                        title:@"选择要更新的 Secret"
                                     subtitle:[NSString stringWithFormat:@"目标仓库: %@", fullRepo]
                                     rowViews:rows
                                   bottomView:bottomDual];
        });
    }] resume];
}

#pragma mark - 新建 Secret 名称与配置 Token 弹窗（与主菜单统一底部弹出）

- (void)showNewSecretModalForFullRepo:(NSString *)fullRepo cookie:(NSString *)cookieStr sourceLabel:(NSString *)sourceLabel rememberBinding:(BOOL)remember {
    dispatch_async(dispatch_get_main_queue(), ^{
        UITextField *tf = [[UITextField alloc] init];
        tf.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
        tf.textColor = [UIColor whiteColor];
        tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
        tf.placeholder = @"点击输入名称，如 COOKIES";
        tf.layer.cornerRadius = 11;
        tf.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        tf.layer.borderWidth = 0.8;
        tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
        tf.leftViewMode = UITextFieldViewModeAlways;
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [tf.heightAnchor constraintEqualToConstant:44.0].active = YES;
        
        UIView *dual = [self createDualBottomBarWithLeftSymbol:@"arrow.uturn.backward.circle.fill"
                                                     leftTitle:@"返回上一步"
                                                     leftColor:[UIColor colorWithWhite:0.82 alpha:1.0]
                                                    leftAction:^{
            [self fetchSecretsForFullRepo:fullRepo cookie:cookieStr sourceLabel:sourceLabel rememberBinding:remember];
        }
                                                   rightSymbol:@"checkmark.circle.fill"
                                                    rightTitle:@"创建并推送"
                                                    rightColor:[UIColor systemGreenColor]
                                                   rightAction:^{
            NSString *secName = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (secName.length == 0) {
                [self showToast:@"请输入有效的 Secret 变量名" duration:1.5];
                return;
            }
            [self dismissCustomModalWithCompletion:^{
                [self pushCookie:cookieStr sourceLabel:sourceLabel toFullRepo:fullRepo secretName:secName rememberBinding:remember];
            }];
        }];
        
        [self presentBottomUnifiedCardWithSymbol:@"plus.circle.fill"
                                      headerTint:[UIColor colorWithRed:0.68 green:0.45 blue:1.0 alpha:1.0]
                                           title:@"新建自定义 Secret"
                                        subtitle:[NSString stringWithFormat:@"将在目标仓库 [%@] 中创建新变量", fullRepo]
                                        bodyView:tf
                                      bottomView:dual];
    });
}

- (void)showTokenConfigModal {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        
        UIStackView *bodyStack = [[UIStackView alloc] init];
        bodyStack.axis = UILayoutConstraintAxisVertical;
        bodyStack.spacing = 10;
        bodyStack.translatesAutoresizingMaskIntoConstraints = NO;
        
        UITextField *tf = [[UITextField alloc] init];
        tf.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
        tf.textColor = [UIColor systemYellowColor];
        tf.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        tf.placeholder = @"ghp_xxxxxxxxxxxxxxxxxxxx";
        tf.text = [defs stringForKey:@"sm_gh_token"] ?: [defs stringForKey:@"uc_gh_token"];
        tf.layer.cornerRadius = 11;
        tf.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        tf.layer.borderWidth = 0.8;
        tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
        tf.leftViewMode = UITextFieldViewModeAlways;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [tf.heightAnchor constraintEqualToConstant:44.0].active = YES;
        [bodyStack addArrangedSubview:tf];
        
        UIButton *clipBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        clipBtn.backgroundColor = [[UIColor colorWithRed:0.30 green:0.70 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.18];
        clipBtn.layer.cornerRadius = 11;
        [clipBtn setTitle:@" 直接从剪贴板读取并保存" forState:UIControlStateNormal];
        [clipBtn setTitleColor:[UIColor colorWithRed:0.40 green:0.80 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        clipBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        [clipBtn setImage:[self sfSymbol:@"doc.on.clipboard.fill" color:[UIColor colorWithRed:0.40 green:0.80 blue:1.0 alpha:1.0] size:14 weight:UIImageSymbolWeightSemibold] forState:UIControlStateNormal];
        clipBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [clipBtn.heightAnchor constraintEqualToConstant:42.0].active = YES;
        objc_setAssociatedObject(clipBtn, "sm_action_block", ^{
            NSString *clip = [[UIPasteboard generalPasteboard].string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (clip.length > 10) {
                [defs setObject:clip forKey:@"sm_gh_token"];
                [defs synchronize];
                cachedRepos = nil;
                [self showMainMenu];
                [self showToast:@"已从剪贴板保存 Token" duration:1.5];
            } else {
                [self showToast:@"剪贴板内无有效 Token" duration:1.5];
            }
        }, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [clipBtn addTarget:self action:@selector(onRowBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
        [bodyStack addArrangedSubview:clipBtn];
        
        UIView *dual = [self createDualBottomBarWithLeftSymbol:@"arrow.uturn.backward.circle.fill"
                                                     leftTitle:@"返回主菜单"
                                                     leftColor:[UIColor colorWithWhite:0.82 alpha:1.0]
                                                    leftAction:^{
            [self showMainMenu];
        }
                                                   rightSymbol:@"checkmark.circle.fill"
                                                    rightTitle:@"保存令牌"
                                                    rightColor:[UIColor systemGreenColor]
                                                   rightAction:^{
            NSString *t = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [defs setObject:t forKey:@"sm_gh_token"];
            [defs synchronize];
            cachedRepos = nil;
            [self showMainMenu];
            [self showToast:@"Token 已保存" duration:1.4];
        }];
        
        [self presentBottomUnifiedCardWithSymbol:@"key.fill"
                                      headerTint:[UIColor systemYellowColor]
                                           title:@"配置 GitHub 访问令牌 (PAT)"
                                        subtitle:@"需具备 repo 权限以读取仓库列表并加密更新 Secrets"
                                        bodyView:bodyStack
                                      bottomView:dual];
    });
}

#pragma mark - 本地 SealedBox 加密与 PUT 直推

- (void)pushCookie:(NSString *)cookieStr sourceLabel:(NSString *)sourceLabel toFullRepo:(NSString *)fullRepo secretName:(NSString *)secretName rememberBinding:(BOOL)remember {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *token = [defs stringForKey:@"sm_gh_token"] ?: [defs stringForKey:@"uc_gh_token"];
    if (!token || token.length == 0) {
        [self showTokenConfigModal];
        return;
    }
    
    [self showToast:@"正在本地公钥加密并推送至 GitHub..." duration:1.5];
    
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
            [self showToast:@"仓库公钥解析异常" duration:2.0];
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
            dispatch_async(dispatch_get_main_queue(), ^{
                NSHTTPURLResponse *putHttpResp = (NSHTTPURLResponse *)pResp;
                if (!pErr && (putHttpResp.statusCode == 201 || putHttpResp.statusCode == 204)) {
                    if (remember) {
                        [defs setObject:sourceLabel forKey:@"sm_bound_domain"];
                        [defs setObject:fullRepo forKey:@"sm_bound_repo"];
                        [defs setObject:secretName forKey:@"sm_bound_secret"];
                        [defs synchronize];
                    }
                    [self showToast:[NSString stringWithFormat:@"推送成功！\n仓库: %@\nSecret: %@\n来源: %@", fullRepo, secretName, sourceLabel] duration:2.8];
                } else {
                    [self showToast:[NSString stringWithFormat:@"写入 Secret 失败 (HTTP %ld)", (long)putHttpResp.statusCode] duration:3.0];
                }
            });
        }] resume];
    }] resume];
}

@end

#pragma mark - 全局双指双击复现监听 & 静默请求头缓存

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (smFloatBtn && smFloatBtn.hidden && event.type == UIEventTypeTouches) {
        NSSet<UITouch *> *touches = [event allTouches];
        if (touches.count == 2) {
            for (UITouch *t in touches) {
                if (t.phase == UITouchPhaseEnded && t.tapCount >= 2) {
                    [[SecretsManager shared] unhideFloatingBallWithToast:YES];
                    break;
                }
            }
        }
    }
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    [[SecretsManager shared] cacheSilentRequest:request];
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    [[SecretsManager shared] cacheSilentRequest:request];
    return %orig;
}
%end

%group SessionClusterHook
%hook __NSURLSessionLocal
- (id)dataTaskWithRequest:(NSURLRequest *)request {
    [[SecretsManager shared] cacheSilentRequest:request];
    return %orig;
}
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(id)completionHandler {
    [[SecretsManager shared] cacheSilentRequest:request];
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
                [[SecretsManager shared] ensureUIAndUnhide:NO];
            });
        }
    });
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[SecretsManager shared] ensureUIAndUnhide:YES];
        });
    }];
}
