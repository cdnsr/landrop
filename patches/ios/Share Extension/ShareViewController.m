//  ShareViewController.m
//  Share Extension replacement for LANDrop 2.8.2 / flutter_sharing_intent 1.1.1.
//
//  The original Swift extension only asked for `public.image` through
//  `loadItem` and force-cast the result to NSURL. Photos hands back a file URL,
//  but the screenshot markup editor hands back an in-memory UIImage (or a
//  NSKeyedArchiver archive of one), so the cast failed, the extension raised
//  its "Error loading data" alert for a single frame and dismissed itself: the
//  share sheet flashed and nothing was ever sent.
//
//  This implementation tries file, data and legacy item representations in
//  order for every provider, repairs archive-shaped screenshot payloads into
//  real PNG bytes, copies payloads into the App Group inside the callback,
//  then writes the exact legacy JSON / UserDefaults / URL scheme expected by
//  the already compiled host plugin.
//
//  Pure Objective-C avoids Swift ABI / compatibility-library mismatches. The
//  runtime class name matches the original NIB's UIClassSwapper string.

#import "ShareExtension.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdarg.h>
#import <string.h>

static NSString * const kSchemePrefix = @"SharingMedia";
static NSString * const kUserDefaultsKey = @"SharingKey";
static NSString * const kTimestampKey = @"SharingTimestamp";
static NSString * const kHostReadyKey = @"SharingHostReady";
static NSString * const kAppGroupIdKey = @"AppGroupId";
static NSString * const kFallbackHostBundleId = @"app.landrop.landrop-flutter";
static NSString * const kLogFileName = @"landrop-share.log";

static NSString *gAppGroupId = nil;

#pragma mark - Diagnostics

// The extension can be terminated without a visible error, so every interesting
// decision is also appended to a small bounded log inside the App Group. That
// file is readable from Filza / any file manager without a jailbreak, which is
// what makes a field failure diagnosable at all.
static void LANDropLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void LANDropLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LANDropShare] %@", message);

    @try {
        if (gAppGroupId.length == 0) return;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:gAppGroupId];
        if (!container) return;
        NSURL *dir = [container URLByAppendingPathComponent:@"Library/Logs" isDirectory:YES];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *file = [dir URLByAppendingPathComponent:kLogFileName];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file.path];
        if (!handle || [handle seekToEndOfFile] > 64 * 1024) {
            [handle closeFile];
            [line writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            return;
        }
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        // Logging must never take the extension down with it.
    }
}

#pragma mark - Type identifiers

static NSString *LANDropUTTypeImage(void) {
    if (@available(iOS 14.0, *)) return UTTypeImage.identifier;
    return (NSString *)kUTTypeImage;
}
static NSString *LANDropUTTypePNG(void) {
    if (@available(iOS 14.0, *)) return UTTypePNG.identifier;
    return (NSString *)kUTTypePNG;
}
static NSString *LANDropUTTypeJPEG(void) {
    if (@available(iOS 14.0, *)) return UTTypeJPEG.identifier;
    return (NSString *)kUTTypeJPEG;
}
static NSString *LANDropUTTypeMovie(void) {
    if (@available(iOS 14.0, *)) return UTTypeMovie.identifier;
    return (NSString *)kUTTypeMovie;
}
static NSString *LANDropUTTypeFileURL(void) {
    if (@available(iOS 14.0, *)) return UTTypeFileURL.identifier;
    return (NSString *)kUTTypeFileURL;
}
static NSString *LANDropUTTypeURL(void) {
    if (@available(iOS 14.0, *)) return UTTypeURL.identifier;
    return (NSString *)kUTTypeURL;
}
static NSString *LANDropUTTypeText(void) {
    if (@available(iOS 14.0, *)) return UTTypeText.identifier;
    return (NSString *)kUTTypeText;
}
static NSString *LANDropUTTypePlainText(void) {
    if (@available(iOS 14.0, *)) return UTTypePlainText.identifier;
    return (NSString *)kUTTypePlainText;
}
static NSString *LANDropUTTypeData(void) {
    if (@available(iOS 14.0, *)) return UTTypeData.identifier;
    return (NSString *)kUTTypeData;
}
static NSString *LANDropUTTypeItem(void) {
    if (@available(iOS 14.0, *)) return UTTypeItem.identifier;
    return (NSString *)kUTTypeItem;
}

static NSArray<NSString *> *LANDropImageTypes(void) {
    return @[LANDropUTTypePNG(), LANDropUTTypeJPEG(),
             @"public.heic", @"public.heif", @"public.tiff", @"public.gif",
             @"public.webp", LANDropUTTypeImage()];
}
static NSArray<NSString *> *LANDropMovieTypes(void) {
    return @[LANDropUTTypeMovie(), @"public.mpeg-4", @"public.quicktime-movie"];
}
static NSArray<NSString *> *LANDropFileTypes(void) {
    return @[LANDropUTTypeFileURL(), LANDropUTTypeData(), LANDropUTTypeItem()];
}

static NSString *LANDropExtensionForType(NSString *uti, NSString *fallback) {
    if ([uti isEqualToString:LANDropUTTypePNG()] || [uti isEqualToString:@"public.png"]) return @"png";
    if ([uti isEqualToString:LANDropUTTypeJPEG()] || [uti isEqualToString:@"public.jpeg"]) return @"jpg";
    if ([uti isEqualToString:@"public.heic"] || [uti isEqualToString:@"public.heif"]) return @"heic";
    if ([uti isEqualToString:@"public.tiff"]) return @"tiff";
    if ([uti isEqualToString:@"public.gif"]) return @"gif";
    if ([uti isEqualToString:@"public.webp"]) return @"webp";
    if ([uti isEqualToString:LANDropUTTypeMovie()] ||
        [uti isEqualToString:@"public.quicktime-movie"]) return @"mov";
    if ([uti isEqualToString:@"public.mpeg-4"]) return @"mp4";
    return fallback;
}

#pragma mark - Image payload normalisation

// True when the bytes start with a signature the receiving app can actually
// open. Used to reject archive blobs that merely carry an image file name.
static BOOL LANDropDataLooksLikeImage(NSData *data) {
    if (data.length < 12) return NO;
    const unsigned char *b = data.bytes;
    if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return YES;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return YES;
    if (b[0] == 'G' && b[1] == 'I' && b[2] == 'F' && b[3] == '8') return YES;
    if (b[0] == 'I' && b[1] == 'I' && b[2] == 0x2A && b[3] == 0x00) return YES;
    if (b[0] == 'M' && b[1] == 'M' && b[2] == 0x00 && b[3] == 0x2A) return YES;
    if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') return YES;
    if (b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F') return YES;
    return NO;
}

// Screenshot markup registers an in-memory UIImage as `public.png`, and the
// system then serialises that object into an NSKeyedArchiver bplist when a file
// representation is requested. Depending on the iOS build the archive contains
// the PNG data outright or only a UIImage wrapper. Both shapes are handled:
// first a real unarchive, then a signature scan of the raw archive bytes.
static NSData *LANDropImageDataFromArchive(NSData *data) {
    id object = nil;
    @try {
        NSSet *classes = [NSSet setWithObjects:
                          UIImage.class, NSData.class, NSMutableData.class,
                          NSURL.class, NSString.class, NSNumber.class,
                          NSArray.class, NSMutableArray.class,
                          NSDictionary.class, NSMutableDictionary.class,
                          NSUUID.class, NSDate.class, nil];
        object = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                     fromData:data error:NULL];
    } @catch (__unused NSException *exception) {
        object = nil;
    }

    if ([object isKindOfClass:UIImage.class]) {
        NSData *png = UIImagePNGRepresentation((UIImage *)object);
        if (png.length > 0) return png;
    }
    if ([object isKindOfClass:NSData.class] &&
        LANDropDataLooksLikeImage((NSData *)object)) {
        return (NSData *)object;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id element in (NSArray *)object) {
            if ([element isKindOfClass:UIImage.class]) {
                NSData *png = UIImagePNGRepresentation((UIImage *)element);
                if (png.length > 0) return png;
            }
            if ([element isKindOfClass:NSData.class] &&
                LANDropDataLooksLikeImage((NSData *)element)) {
                return (NSData *)element;
            }
        }
    }

    const unsigned char *b = data.bytes;
    NSUInteger n = data.length;
    static const unsigned char pngSignature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    for (NSUInteger i = 0; i + 8 < n; i++) {
        if (memcmp(b + i, pngSignature, 8) != 0) continue;
        for (NSUInteger j = i + 8; j + 4 <= n; j++) {
            if (memcmp(b + j, "IEND", 4) != 0) continue;
            NSUInteger end = MIN(j + 8, n);
            return [data subdataWithRange:NSMakeRange(i, end - i)];
        }
        return [data subdataWithRange:NSMakeRange(i, n - i)];
    }
    for (NSUInteger i = 0; i + 3 < n; i++) {
        if (!(b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF)) continue;
        for (NSUInteger j = n; j > i + 4; j--) {
            if (b[j - 2] == 0xFF && b[j - 1] == 0xD9) {
                return [data subdataWithRange:NSMakeRange(i, j - i)];
            }
        }
        return [data subdataWithRange:NSMakeRange(i, n - i)];
    }
    return nil;
}

// Repair the copied file in place. Every step is exception guarded: an
// uncaught Objective-C exception terminates the extension process, and the
// host app would then open with an empty attachment list.
//
// Returns YES when the file is worth handing to the host app. Unknown bytes are
// kept (the receiving side may still understand them), but an archive that
// cannot be turned back into image data is rejected so the caller can try the
// next representation instead of sending an unopenable file.
static BOOL LANDropNormalizeImageFileAtURL(NSURL *url) {
    @try {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data.length == 0) return NO;
        if (LANDropDataLooksLikeImage(data)) return YES;
        if (data.length < 8 || memcmp(data.bytes, "bplist00", 8) != 0) {
            LANDropLog(@"unrecognised image payload kept as-is (%lu bytes)",
                       (unsigned long)data.length);
            return YES;
        }

        NSData *image = LANDropImageDataFromArchive(data);
        if (image.length == 0) {
            LANDropLog(@"archive payload had no extractable image");
            return NO;
        }
        if (![image writeToURL:url options:NSDataWritingAtomic error:NULL]) {
            LANDropLog(@"could not write normalised image bytes");
            return NO;
        }
        LANDropLog(@"normalised archived screenshot payload (%lu -> %lu bytes)",
                   (unsigned long)data.length, (unsigned long)image.length);
        return YES;
    } @catch (NSException *exception) {
        LANDropLog(@"image normalisation raised %@", exception.name);
        return NO;
    }
}

#pragma mark - File copying

// Match the original extension's copy order: NSFileCoordinator first, then a
// plain copy as a fallback. Album photos hand back security-scoped URLs that
// the coordinator path is designed for, and that is the path that worked.
static BOOL LANDropCoordinatedCopyItemAtURL(NSURL *source, NSURL *destination) {
    if (!source.isFileURL || !destination) return NO;
    __block BOOL copied = NO;
    NSFileCoordinator *coordinator = [NSFileCoordinator new];
    NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges
                                       error:&coordinationError
                                  byAccessor:^(NSURL *coordinated) {
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtURL:destination error:NULL];
        copied = [fm copyItemAtURL:coordinated toURL:destination error:NULL];
    }];
    if (!copied) {
        LANDropLog(@"coordinated copy failed (%@): %@", source.lastPathComponent,
                   coordinationError.localizedDescription);
    }
    return copied;
}

static BOOL LANDropCopyItemAtURL(NSURL *source, NSURL *destination) {
    if (!source.isFileURL || !destination) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtURL:destination error:NULL];
    NSError *error = nil;
    if ([fm copyItemAtURL:source toURL:destination error:&error]) return YES;
    LANDropLog(@"direct copy failed (%@): %@", source.lastPathComponent,
               error.localizedDescription);
    return NO;
}

#pragma mark - Thread-safe completion

// Private but long-standing on NSExtensionContext; used only when the legacy
// responder-chain openURL: is unavailable.
@interface NSExtensionContext (LANDropOpenURL)
- (void)openURL:(NSURL *)URL completionHandler:(void (^)(BOOL success))completionHandler;
@end

typedef void (^LANDropProviderBlock)(NSItemProvider *provider, NSArray<NSString *> *types,
                                     NSUInteger index, SharingFileType fileType,
                                     NSString *defaultExtension,
                                     void (^done)(BOOL success));

static void LANDropTryTypes(NSItemProvider *provider,
                            NSArray<NSString *> *types,
                            NSUInteger index,
                            SharingFileType fileType,
                            NSString *defaultExtension,
                            LANDropProviderBlock attempt,
                            void (^done)(BOOL success)) {
    if (index >= types.count) {
        done(NO);
        return;
    }
    __block BOOL finished = NO;
    NSLock *lock = [NSLock new];
    void (^next)(BOOL) = ^(BOOL success) {
        [lock lock];
        if (finished) {
            [lock unlock];
            return;
        }
        finished = YES;
        [lock unlock];
        if (success) {
            done(YES);
        } else {
            LANDropTryTypes(provider, types, index + 1, fileType,
                            defaultExtension, attempt, done);
        }
    };
    attempt(provider, types, index, fileType, defaultExtension, next);
}

@interface LANDropShareState : NSObject
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *media;
@property (nonatomic, strong) NSMutableArray<NSString *> *texts;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, copy) NSString *fragment;
- (void)addMedia:(NSDictionary *)file;
- (void)addText:(NSString *)text fragment:(NSString *)fragment;
- (BOOL)isEmpty;
@end

@implementation LANDropShareState
- (instancetype)init {
    if ((self = [super init])) {
        _media = [NSMutableArray array];
        _texts = [NSMutableArray array];
        _lock = [NSLock new];
        _fragment = @"media";
    }
    return self;
}
- (void)addMedia:(NSDictionary *)file {
    [_lock lock];
    [_media addObject:file];
    [_lock unlock];
}
- (void)addText:(NSString *)text fragment:(NSString *)fragment {
    [_lock lock];
    [_texts addObject:text];
    if (_media.count > 0) _fragment = @"media";
    else _fragment = fragment;
    [_lock unlock];
}
- (BOOL)isEmpty {
    [_lock lock];
    BOOL empty = (_media.count == 0 && _texts.count == 0);
    [_lock unlock];
    return empty;
}
@end

#pragma mark - Controller

@interface _TtC15Share_Extension19ShareViewController ()
@property (nonatomic, copy) NSString *hostAppBundleIdentifier;
@property (nonatomic, copy) NSString *appGroupId;
@property (nonatomic, strong) LANDropShareState *state;
@property (nonatomic, assign) BOOL hasStarted;
@property (nonatomic, assign) BOOL hasFinished;
- (void)launchViaResponderChain:(NSURL *)url;
@end

@implementation _TtC15Share_Extension19ShareViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadIds];
    self.state = [LANDropShareState new];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.hasStarted) return;
    self.hasStarted = YES;
    [self processAttachments];
}

- (void)loadIds {
    NSString *extensionId = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSRange dot = [extensionId rangeOfString:@"." options:NSBackwardsSearch];
    NSString *host = dot.location == NSNotFound
        ? kFallbackHostBundleId
        : [extensionId substringToIndex:dot.location];
    self.hostAppBundleIdentifier = host.length > 0 ? host : kFallbackHostBundleId;

    NSString *custom = [NSBundle.mainBundle objectForInfoDictionaryKey:kAppGroupIdKey];
    if ([custom isKindOfClass:NSString.class] && custom.length > 0 &&
        ![custom isEqualToString:@"$(CUSTOM_GROUP_ID)"]) {
        self.appGroupId = custom;
    } else {
        self.appGroupId = [@"group." stringByAppendingString:self.hostAppBundleIdentifier];
    }
    gAppGroupId = self.appGroupId;
}

#pragma mark - Attachment routing

- (void)processAttachments {
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (NSExtensionItem *item in self.extensionContext.inputItems ?: @[]) {
        if (![item isKindOfClass:NSExtensionItem.class]) continue;
        for (NSItemProvider *provider in item.attachments ?: @[]) {
            if ([provider isKindOfClass:NSItemProvider.class]) [providers addObject:provider];
        }
    }
    LANDropLog(@"extension started: %lu provider(s), group=%@ container=%@",
               (unsigned long)providers.count, self.appGroupId,
               ([self containerURL] ? @"ok" : @"missing"));
    if (providers.count == 0) {
        [self finish:NO];
        return;
    }
    [self loadProviders:providers attempt:1];
}

// Screenshot-sourced providers occasionally fail their first representation
// load (the payload is still being handed over by the markup process) and
// succeed on a second attempt. One retry is cheap insurance against a share
// sheet that silently closes.
- (void)loadProviders:(NSArray<NSItemProvider *> *)providers attempt:(NSUInteger)attempt {
    dispatch_group_t group = dispatch_group_create();
    for (NSItemProvider *provider in providers) {
        dispatch_group_enter(group);
        [self processProvider:provider completion:^{
            dispatch_group_leave(group);
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if ([self.state isEmpty] && attempt < 2) {
            LANDropLog(@"attempt %lu produced no payload; retrying", (unsigned long)attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self loadProviders:providers attempt:attempt + 1];
            });
            return;
        }
        [self saveAndRedirect];
    });
}

- (void)processProvider:(NSItemProvider *)provider completion:(void (^)(void))completion {
    __block BOOL done = NO;
    void (^finish)(BOOL) = ^(BOOL success) {
        if (done) return;
        done = YES;
        if (!success) {
            LANDropLog(@"provider gave up: %@", provider.registeredTypeIdentifiers);
        }
        completion();
    };

    NSArray * (^available)(NSArray *) = ^NSArray *(NSArray *candidates) {
        NSMutableArray *result = [NSMutableArray array];
        for (NSString *type in candidates) {
            if ([provider hasItemConformingToTypeIdentifier:type]) [result addObject:type];
        }
        return result;
    };

    NSArray *images = available(LANDropImageTypes());
    if (images.count > 0) {
        [self loadImageProvider:provider types:images completion:finish];
        return;
    }
    NSArray *movies = available(LANDropMovieTypes());
    if (movies.count > 0) {
        [self loadBinaryProvider:provider types:movies
                        fileType:SharingFileTypeVideo defaultExtension:@"mov"
                      completion:finish];
        return;
    }
    NSArray *files = available(LANDropFileTypes());
    if (files.count > 0) {
        [self loadBinaryProvider:provider types:files
                        fileType:SharingFileTypeFile defaultExtension:@"bin"
                      completion:finish];
        return;
    }
    NSArray *urls = available(@[LANDropUTTypeURL()]);
    if (urls.count > 0) {
        [self loadTextProvider:provider types:urls fragment:@"url" completion:finish];
        return;
    }
    NSArray *texts = available(@[LANDropUTTypePlainText(), LANDropUTTypeText()]);
    if (texts.count > 0) {
        [self loadTextProvider:provider types:texts fragment:@"text" completion:finish];
        return;
    }

    // Vendor-specific or private identifiers (screenshot services, third-party
    // apps) match none of the public types above. Load whatever the provider
    // does advertise and hand it over as a generic file instead of dropping it.
    NSMutableArray<NSString *> *registered = [NSMutableArray array];
    for (id identifier in provider.registeredTypeIdentifiers) {
        if ([identifier isKindOfClass:NSString.class]) [registered addObject:identifier];
    }
    if (registered.count > 0) {
        LANDropLog(@"falling back to registered identifiers: %@", registered);
        [self loadBinaryProvider:provider types:registered
                        fileType:SharingFileTypeFile defaultExtension:@"bin"
                      completion:finish];
        return;
    }
    finish(NO);
}

#pragma mark - Representation loaders

- (void)loadImageProvider:(NSItemProvider *)provider
                    types:(NSArray<NSString *> *)types
               completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType fileType,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *type = all[index];
        if ([p respondsToSelector:@selector(loadFileRepresentationForTypeIdentifier:completionHandler:)]) {
            [p loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || error || !url) { next(NO); return; }
                NSDictionary *stored = [self storeURL:url type:SharingFileTypeImage
                                     defaultExtension:LANDropExtensionForType(type, @"png")];
                if (stored) { [self.state addMedia:stored]; next(YES); }
                else next(NO);
            }];
            return;
        }
        next(NO);
    };
    LANDropTryTypes(provider, types, 0, SharingFileTypeImage, @"png", attempt,
                    ^(BOOL success) {
        if (success) { completion(YES); return; }
        [weakSelf loadImageInPlace:provider types:types completion:completion];
    });
}

// Screenshot and markup providers hand the bytes over in place: the URL is
// only readable inside the callback and must be copied immediately. Providers
// that refuse to materialise a temporary file for `loadFileRepresentation`
// (which is exactly the screenshot case) still support this one.
- (void)loadImageInPlace:(NSItemProvider *)provider
                   types:(NSArray<NSString *> *)types
              completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType fileType,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *type = all[index];
        if ([p respondsToSelector:@selector(loadInPlaceFileRepresentationForTypeIdentifier:completionHandler:)]) {
            [p loadInPlaceFileRepresentationForTypeIdentifier:type
                                            completionHandler:^(NSURL * _Nullable url, BOOL isInPlace, NSError * _Nullable error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || error || !url) { next(NO); return; }
                NSDictionary *stored = [self storeURL:url type:SharingFileTypeImage
                                     defaultExtension:LANDropExtensionForType(type, @"png")];
                if (stored) { [self.state addMedia:stored]; next(YES); }
                else next(NO);
            }];
            return;
        }
        next(NO);
    };
    LANDropTryTypes(provider, types, 0, SharingFileTypeImage, @"png", attempt,
                    ^(BOOL success) {
        if (success) { completion(YES); return; }
        [weakSelf loadImageData:provider types:types completion:completion];
    });
}

- (void)loadImageData:(NSItemProvider *)provider
                types:(NSArray<NSString *> *)types
           completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType fileType,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *type = all[index];
        if ([p respondsToSelector:@selector(loadDataRepresentationForTypeIdentifier:completionHandler:)]) {
            [p loadDataRepresentationForTypeIdentifier:type completionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || error || !data) { next(NO); return; }
                NSDictionary *stored = [self storeData:data type:SharingFileTypeImage
                                      defaultExtension:LANDropExtensionForType(type, @"png")];
                if (stored) { [self.state addMedia:stored]; next(YES); }
                else next(NO);
            }];
            return;
        }
        next(NO);
    };
    LANDropTryTypes(provider, types, 0, SharingFileTypeImage, @"png", attempt,
                    ^(BOOL success) {
        if (success) { completion(YES); return; }
        [weakSelf loadImageLegacy:provider types:types completion:completion];
    });
}

- (void)loadImageLegacy:(NSItemProvider *)provider
                  types:(NSArray<NSString *> *)types
             completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType fileType,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *type = all[index];
        [p loadItemForTypeIdentifier:type options:nil completionHandler:^(id _Nullable item, NSError * _Nullable error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || error || !item) { next(NO); return; }
            NSDictionary *stored = nil;
            if ([item isKindOfClass:NSURL.class]) {
                stored = [self storeURL:(NSURL *)item type:SharingFileTypeImage
                       defaultExtension:LANDropExtensionForType(type, @"png")];
            } else if ([item isKindOfClass:UIImage.class]) {
                NSData *data = UIImagePNGRepresentation((UIImage *)item);
                if (data) stored = [self storeData:data type:SharingFileTypeImage
                                  defaultExtension:@"png"];
            } else if ([item isKindOfClass:NSData.class]) {
                stored = [self storeData:(NSData *)item type:SharingFileTypeImage
                        defaultExtension:LANDropExtensionForType(type, @"png")];
            } else if ([item isKindOfClass:NSString.class] &&
                       [NSURL URLWithString:(NSString *)item]) {
                stored = [self storeURL:[NSURL URLWithString:(NSString *)item]
                                   type:SharingFileTypeImage defaultExtension:@"png"];
            }
            if (stored) { [self.state addMedia:stored]; next(YES); }
            else next(NO);
        }];
    };
    LANDropTryTypes(provider, types, 0, SharingFileTypeImage, @"png", attempt, completion);
}

- (void)loadBinaryProvider:(NSItemProvider *)provider
                     types:(NSArray<NSString *> *)types
                  fileType:(SharingFileType)fileType
          defaultExtension:(NSString *)defaultExtension
                completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType type,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *uti = all[index];
        if ([p respondsToSelector:@selector(loadFileRepresentationForTypeIdentifier:completionHandler:)]) {
            [p loadFileRepresentationForTypeIdentifier:uti completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || error || !url) { next(NO); return; }
                NSDictionary *stored = [self storeURL:url type:type defaultExtension:ext];
                if (stored) { [self.state addMedia:stored]; next(YES); }
                else next(NO);
            }];
            return;
        }
        next(NO);
    };
    LANDropTryTypes(provider, types, 0, fileType, defaultExtension, attempt,
                    ^(BOOL success) {
        if (success) { completion(YES); return; }
        [weakSelf loadBinaryData:provider types:types fileType:fileType
               defaultExtension:defaultExtension completion:completion];
    });
}

- (void)loadBinaryData:(NSItemProvider *)provider
                 types:(NSArray<NSString *> *)types
              fileType:(SharingFileType)fileType
      defaultExtension:(NSString *)defaultExtension
            completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType type,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *uti = all[index];
        if ([p respondsToSelector:@selector(loadDataRepresentationForTypeIdentifier:completionHandler:)]) {
            [p loadDataRepresentationForTypeIdentifier:uti completionHandler:^(NSData * _Nullable data, NSError * _Nullable error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || error || !data) { next(NO); return; }
                NSDictionary *stored = [self storeData:data type:type defaultExtension:ext];
                if (stored) { [self.state addMedia:stored]; next(YES); }
                else next(NO);
            }];
            return;
        }
        next(NO);
    };
    LANDropTryTypes(provider, types, 0, fileType, defaultExtension, attempt,
                    ^(BOOL success) {
        if (success) { completion(YES); return; }
        [weakSelf loadBinaryLegacy:provider types:types fileType:fileType
                  defaultExtension:defaultExtension completion:completion];
    });
}

- (void)loadBinaryLegacy:(NSItemProvider *)provider
                   types:(NSArray<NSString *> *)types
                fileType:(SharingFileType)fileType
        defaultExtension:(NSString *)defaultExtension
              completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType type,
                                     NSString *ext, void (^next)(BOOL)) {
        NSString *uti = all[index];
        [p loadItemForTypeIdentifier:uti options:nil completionHandler:^(id _Nullable item, NSError * _Nullable error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || error || !item) { next(NO); return; }
            NSDictionary *stored = nil;
            if ([item isKindOfClass:NSURL.class]) {
                stored = [self storeURL:(NSURL *)item type:type defaultExtension:ext];
            } else if ([item isKindOfClass:UIImage.class]) {
                NSData *data = UIImagePNGRepresentation((UIImage *)item);
                if (data) stored = [self storeData:data type:type defaultExtension:@"png"];
            } else if ([item isKindOfClass:NSData.class]) {
                stored = [self storeData:(NSData *)item type:type defaultExtension:ext];
            } else if ([item isKindOfClass:NSString.class] &&
                       [NSURL URLWithString:(NSString *)item]) {
                stored = [self storeURL:[NSURL URLWithString:(NSString *)item]
                                   type:type defaultExtension:ext];
            }
            if (stored) { [self.state addMedia:stored]; next(YES); }
            else next(NO);
        }];
    };
    LANDropTryTypes(provider, types, 0, fileType, defaultExtension, attempt, completion);
}

- (void)loadTextProvider:(NSItemProvider *)provider
                   types:(NSArray<NSString *> *)types
                fragment:(NSString *)fragment
              completion:(void (^)(BOOL))completion {
    __weak typeof(self) weakSelf = self;
    LANDropProviderBlock attempt = ^(NSItemProvider *p, NSArray<NSString *> *all,
                                     NSUInteger index, SharingFileType type,
                                     NSString *ext, void (^next)(BOOL)) {
        [p loadItemForTypeIdentifier:all[index] options:nil
                   completionHandler:^(id _Nullable item, NSError * _Nullable error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || error || !item) { next(NO); return; }
            NSString *value = nil;
            if ([item isKindOfClass:NSString.class]) value = (NSString *)item;
            else if ([item isKindOfClass:NSURL.class]) value = ((NSURL *)item).absoluteString;
            if (value.length > 0) {
                [self.state addText:value fragment:fragment];
                next(YES);
            } else {
                next(NO);
            }
        }];
    };
    LANDropTryTypes(provider, types, 0, SharingFileTypeText, @"txt", attempt, completion);
}

#pragma mark - Storage

- (NSURL *)containerURL {
    return [NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:self.appGroupId];
}

- (NSString *)uniqueName:(NSString *)candidate defaultExtension:(NSString *)ext {
    // The host plugin turns `file://<path>` back into a plain path by string
    // replacement, without percent-decoding. A copied name containing spaces or
    // non-ASCII characters would therefore resolve to a nonexistent file and the
    // shared item would be silently dropped. Keep only characters that need no
    // encoding in a URL path.
    NSString *original = candidate.lastPathComponent ?: @"";
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < original.length; i++) {
        unichar c = [original characterAtIndex:i];
        BOOL allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                       (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
        [safe appendFormat:@"%C", allowed ? c : (unichar)'_'];
    }
    NSString *name = safe;
    if (name.length == 0 || [name isEqualToString:@"_"]) {
        return [NSString stringWithFormat:@"LANDrop-%@.%@", NSUUID.UUID.UUIDString, ext];
    }
    if (name.pathExtension.length == 0) {
        return [name stringByAppendingPathExtension:ext];
    }
    // Avoid collisions when the same filename is shared repeatedly.
    NSString *base = name.stringByDeletingPathExtension;
    return [NSString stringWithFormat:@"%@-%@.%@", base,
            [NSUUID.UUID.UUIDString substringToIndex:8], name.pathExtension];
}

- (NSDictionary *)storedFileAt:(NSURL *)destination type:(SharingFileType)type {
    BOOL isImage = (type == SharingFileTypeImage);
    if (isImage && !LANDropNormalizeImageFileAtURL(destination)) {
        // A file with an image name but unreadable bytes would be handed to the
        // host app as a broken image, so try the next representation instead.
        [NSFileManager.defaultManager removeItemAtURL:destination error:NULL];
        return nil;
    }
    // Match Swift JSONEncoder's output for the host plugin's Codable model:
    // required keys only; optional nil fields are omitted, not NSNull.
    // Swift `decodeIfPresent` treats an explicit NSNull as an invalid type for
    // the optional String/Int properties and aborts decoding of the whole array.
    return @{@"value": destination.absoluteString,
             @"type": @(type)};
}

- (NSDictionary *)storeURL:(NSURL *)url
                      type:(SharingFileType)type
          defaultExtension:(NSString *)defaultExtension {
    NSURL *container = [self containerURL];
    if (!container || !url) return nil;
    NSURL *destination = [container
        URLByAppendingPathComponent:[self uniqueName:url.absoluteString
                                    defaultExtension:defaultExtension]];

    BOOL accessed = url.isFileURL && [url startAccessingSecurityScopedResource];
    BOOL copied = LANDropCoordinatedCopyItemAtURL(url, destination);
    if (!copied) copied = LANDropCopyItemAtURL(url, destination);
    if (accessed) [url stopAccessingSecurityScopedResource];
    if (!copied) return nil;
    return [self storedFileAt:destination type:type];
}

- (NSDictionary *)storeData:(NSData *)data
                       type:(SharingFileType)type
           defaultExtension:(NSString *)defaultExtension {
    NSURL *container = [self containerURL];
    if (!container || data.length == 0) return nil;
    NSString *name = [NSString stringWithFormat:@"LANDrop-%@.%@",
                      NSUUID.UUID.UUIDString, defaultExtension];
    NSURL *destination = [container URLByAppendingPathComponent:name];
    NSError *error = nil;
    if (![data writeToURL:destination options:NSDataWritingAtomic error:&error] || error) return nil;
    return [self storedFileAt:destination type:type];
}

- (BOOL)writeSharedObject:(id)value forKey:(NSString *)key {
    // Exactly what flutter_sharing_intent 1.1.1 does, and nothing more: one
    // write through the App Group suite, then synchronize. Do not also write
    // the backing plist by hand — that file is owned by cfprefsd, which flushes
    // its own cached copy over it, and the host app then reads a domain without
    // the key and opens with nothing selected.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:self.appGroupId];
    if (!defaults) {
        LANDropLog(@"could not open App Group suite %@", self.appGroupId);
        return NO;
    }
    [defaults setObject:value forKey:key];
    // The host plugin reads this timestamp to tell a fresh share from a stale
    // one, so it can consume the payload exactly once.
    [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:kTimestampKey];
    [defaults synchronize];

    // Read back through the same API the host plugin uses, so a broken handoff
    // shows up in the log instead of as an app that opens with nothing selected.
    id stored = [defaults objectForKey:key];
    if (stored == nil) {
        LANDropLog(@"suite %@ dropped key %@ (container=%@)", self.appGroupId, key,
                   [self containerURL] ? @"ok" : @"missing");
        return NO;
    }
    NSUInteger length = [stored isKindOfClass:NSData.class] ? [(NSData *)stored length] : 0;
    LANDropLog(@"stored key %@ (%lu bytes) in suite %@ (container=%@)", key,
               (unsigned long)length, self.appGroupId,
               [self containerURL] ? @"ok" : @"missing");
    return YES;
}

#pragma mark - Completion

- (void)saveAndRedirect {
    if (self.hasFinished) return;
    NSString *fragment = @"media";
    BOOL succeeded = NO;
    [self.state.lock lock];
    NSArray *media = [self.state.media copy];
    NSArray *texts = [self.state.texts copy];
    if (media.count == 0 && texts.count > 0) fragment = self.state.fragment;
    [self.state.lock unlock];

    if (media.count > 0) {
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:media options:0 error:&error];
        if (json && !error) {
            succeeded = [self writeSharedObject:json forKey:kUserDefaultsKey];
        }
        LANDropLog(@"handing off %lu media item(s), %lu byte(s) of JSON (stored=%d)",
                   (unsigned long)media.count, (unsigned long)json.length, succeeded);
    } else if (texts.count > 0) {
        succeeded = [self writeSharedObject:texts forKey:kUserDefaultsKey];
        LANDropLog(@"handing off %lu text item(s) (stored=%d)",
                   (unsigned long)texts.count, succeeded);
    }
    if (succeeded) [self openHostAppFragment:fragment];
    else [self finish:NO];
}

- (void)openHostAppFragment:(NSString *)fragment {
    [self loadIds];
    // Host plugin checks `hasPrefix("SharingMedia-<bundle id>")`, then reads
    // url.host?.components(separatedBy: "=").last as the UserDefaults key and
    // url.fragment as the payload type. Keep this exact legacy format.
    NSString *raw = [NSString stringWithFormat:@"%@-%@://dataUrl=%@#%@",
                     kSchemePrefix, self.hostAppBundleIdentifier,
                     kUserDefaultsKey, fragment];
    NSURL *url = [NSURL URLWithString:raw];
    if (!url) { [self finish:NO]; return; }

    self.hasFinished = YES;
    LANDropLog(@"opening host app: %@", raw);

    NSExtensionContext *context = self.extensionContext;
    __block BOOL completed = NO;
    void (^completeOnce)(void) = ^{
        if (completed) return;
        completed = YES;
        [context completeRequestReturningItems:@[] completionHandler:nil];
    };

    // The documented context API reports failure on this system every time
    // (`success=0`), so the private responder-chain openURL: is the only path
    // that actually works. A single request is also unreliable: the system
    // sometimes discards it, leaving the host spawned in the background with
    // `url received` but no `app became active`, and the process is then
    // reclaimed — the share sheet just closes.
    //
    // Blind retries are worse than useless here: each one spawns another host
    // process, and a request still queued when the sheet closes fires later at
    // an unrelated moment (opening LANDrop out of nowhere). So retry only until
    // the host reports it reached the foreground for this share, which the host
    // plugin records in `SharingHostReady`.
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:self.appGroupId];
    double shareStamp = [shared doubleForKey:kTimestampKey];
    LANDropLog(@"waiting for host readiness (shareStamp=%.6f)", shareStamp);

    const NSTimeInterval budget = 8.0;
    // A launch request that is already being serviced must not be interrupted.
    // The host needs a moment to bring itself forward, and asking again during
    // that window spawns a second process which replaces the first one — the
    // "album share cold-starts even though the app was already running" symptom.
    // So send once, then only re-send if the host has shown no sign of life for
    // a while, and check readiness on a much faster cadence than that.
    const NSTimeInterval resendAfter = 2.5;
    const NSTimeInterval pollInterval = 0.2;
    NSDate *started = [NSDate date];
    NSDate *lastRequest = [NSDate date];
    __block int attempt = 0;
    __block void (^attemptBlock)(void) = nil;
    attemptBlock = ^{
        if (completed) return;

        // The host has answered for this share: close the sheet immediately.
        // Waiting longer keeps the user staring at a spinner after the app is
        // already usable.
        double ready = [[[NSUserDefaults alloc] initWithSuiteName:self.appGroupId]
                        doubleForKey:kHostReadyKey];
        if (shareStamp > 0 && ready >= shareStamp) {
            LANDropLog(@"host ready after %d attempt(s); closing sheet", attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), completeOnce);
            return;
        }

        NSTimeInterval elapsed = -[started timeIntervalSinceNow];
        if (elapsed >= budget) {
            LANDropLog(@"host not ready after %.1fs and %d attempt(s); closing sheet",
                       elapsed, attempt);
            completeOnce();
            return;
        }

        NSTimeInterval sinceRequest = -[lastRequest timeIntervalSinceNow];
        if (attempt == 0 || sinceRequest >= resendAfter) {
            attempt += 1;
            lastRequest = [NSDate date];
            [self launchViaResponderChain:url];
            LANDropLog(@"launch attempt %d (elapsed=%.1fs)", attempt, elapsed);
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), attemptBlock);
    };
    attemptBlock();
}

/// Legacy launch path: the private openURL: on the responder chain, exactly
/// once. The original plugin called it on every responder, which issues several
/// launches that cancel each other out.
- (void)launchViaResponderChain:(NSURL *)url {
    SEL selector = sel_registerName("openURL:");
    UIResponder *responder = self;
    while (responder) {
        if ([responder respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [responder performSelector:selector withObject:url];
#pragma clang diagnostic pop
            LANDropLog(@"host app launch requested (responderChain=1)");
            return;
        }
        responder = responder.nextResponder;
    }
    LANDropLog(@"host app launch requested (responderChain=0)");
}

- (void)finish:(BOOL)success {
    if (self.hasFinished) return;
    self.hasFinished = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (success) {
            [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
        } else {
            LANDropLog(@"no shareable content; cancelling request");
            NSError *error = [NSError errorWithDomain:@"app.landrop.share-extension"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        @"Unable to load shared content"}];
            [self.extensionContext cancelRequestWithError:error];
        }
    });
}

@end
