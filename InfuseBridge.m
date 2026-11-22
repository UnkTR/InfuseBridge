#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *gLastPlayedURL = nil;
static NSString *gExpectedCallbackScheme = nil;

// infuse:// -> outplayer:// dönüştürücü
static NSURL *RewriteInfuseToOutplayer(NSURL *url) {
    if (!url || ![[url.scheme lowercaseString] isEqualToString:@"infuse"]) {
        return url;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    // Gelen parametrelerden video URL'sini ve callback şemasını kaydet
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"url"] && item.value.length > 0) {
            gLastPlayedURL = [item.value copy];
        } else if ([item.name isEqualToString:@"x-success"] && item.value.length > 0) {
            NSURL *cbURL = [NSURL URLWithString:item.value];
            if (cbURL.scheme.length > 0) {
                gExpectedCallbackScheme = [[cbURL.scheme lowercaseString] copy];
            }
        }
    }

    // Şemayı outplayer olarak değiştir (host: x-callback-url, path: /play ve query'ler korunur)
    components.scheme = @"outplayer";
    NSURL *rewritten = components.URL;

    NSLog(@"[InfuseBridge] Inbound: %@ -> %@", url.absoluteString, rewritten.absoluteString);
    return rewritten ?: url;
}

// Outplayer kapanış callback'ini Stremio'nun Infuse'tan beklediği formata uyarla
static NSURL *NormalizeCallbackForStremio(NSURL *url) {
    if (!url) return url;

    NSString *scheme = [url.scheme lowercaseString];
    BOOL isStremio = [scheme isEqualToString:@"stremio"] ||
                     (gExpectedCallbackScheme && [scheme isEqualToString:gExpectedCallbackScheme]);
    if (!isStremio) return url;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    BOOL hasPosition = NO;
    BOOL hasLastPlayed = NO;
    NSString *detectedPosition = nil;

    for (NSURLQueryItem *item in items) {
        NSString *key = [item.name lowercaseString];
        if ([key isEqualToString:@"position"]) {
            hasPosition = YES;
        } else if ([key isEqualToString:@"lastplayedurl"]) {
            hasLastPlayed = YES;
        } else if ([key isEqualToString:@"time"] ||
                   [key isEqualToString:@"currenttime"] ||
                   [key isEqualToString:@"playbackposition"] ||
                   [key isEqualToString:@"progress"]) {
            detectedPosition = item.value;
        }
    }

    // Outplayer farklı bir isimle süre döndürdüyse 'position' olarak ekle
    if (!hasPosition && detectedPosition.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"position" value:detectedPosition]];
    }

    // Stremio'nun beklediği lastPlayedUrl eksikse ekle
    if (!hasLastPlayed && gLastPlayedURL.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"lastPlayedUrl" value:gLastPlayedURL]];
    }

    components.queryItems = items;
    NSURL *finalURL = components.URL;

    NSLog(@"[InfuseBridge] Outbound: %@ -> %@", url.absoluteString, finalURL.absoluteString);
    return finalURL ?: url;
}

// --- 1. Modern Scene/SwiftUI Yakalayıcı (UIOpenURLContext.URL) ---
@implementation UIOpenURLContext (InfuseBridge)

- (NSURL *)ib_URL {
    NSURL *original = [self ib_URL];
    return RewriteInfuseToOutplayer(original);
}

@end

// --- 2. Outbound Callback Yakalayıcı (UIApplication.openURL:options:completionHandler:) ---
@implementation UIApplication (InfuseBridge)

- (void)ib_openURL:(NSURL *)url
           options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
 completionHandler:(void (^)(BOOL success))completion {
    NSURL *patched = NormalizeCallbackForStremio(url);
    [self ib_openURL:patched options:options completionHandler:completion];
}

// Eski AppDelegate kullanan durumlar için yedek hook
- (void)ib_setDelegate:(id<UIApplicationDelegate>)delegate {
    [self ib_setDelegate:delegate];
    if (!delegate) return;

    Class cls = [delegate class];
    SEL origSel = @selector(application:openURL:options:);
    if (class_getInstanceMethod(cls, origSel)) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Method origMethod = class_getInstanceMethod(cls, origSel);
            IMP origIMP = method_getImplementation(origMethod);
            typedef BOOL (*OpenURLFunc)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
            OpenURLFunc origFn = (OpenURLFunc)origIMP;

            IMP newIMP = imp_implementationWithBlock(^BOOL(id _self, UIApplication *app, NSURL *url, NSDictionary *opts) {
                NSURL *rewritten = RewriteInfuseToOutplayer(url);
                return origFn(_self, origSel, app, rewritten, opts);
            });
            method_setImplementation(origMethod, newIMP);
        });
    }
}

@end

// Dylib yüklendiğinde otomatik çalışır
__attribute__((constructor))
static void InfuseBridgeInit(void) {
    NSLog(@"[InfuseBridge] Loaded.");

    // UIOpenURLContext.URL swizzle
    Class ctxClass = NSClassFromString(@"UIOpenURLContext");
    if (ctxClass) {
        Method m1 = class_getInstanceMethod(ctxClass, @selector(URL));
        Method m2 = class_getInstanceMethod(ctxClass, @selector(ib_URL));
        if (m1 && m2) method_exchangeImplementations(m1, m2);
    }

    // UIApplication.openURL:options:completionHandler: swizzle
    Class appClass = [UIApplication class];
    Method o1 = class_getInstanceMethod(appClass, @selector(openURL:options:completionHandler:));
    Method o2 = class_getInstanceMethod(appClass, @selector(ib_openURL:options:completionHandler:));
    if (o1 && o2) method_exchangeImplementations(o1, o2);

    // UIApplication.setDelegate: swizzle
    Method d1 = class_getInstanceMethod(appClass, @selector(setDelegate:));
    Method d2 = class_getInstanceMethod(appClass, @selector(ib_setDelegate:));
    if (d1 && d2) method_exchangeImplementations(d1, d2);
}
