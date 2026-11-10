//  ShareViewController.m
//  Share Extension replacement for LANDrop 2.8.2 / flutter_sharing_intent 1.1.1.
//
//  The original Swift extension only accepted `public.image` via loadItem and
//  force-cast the result to NSURL. Screenshot providers commonly return
//  UIImage/NSData or concrete UTIs, so the cast fails and the extension closes
//  immediately ("flashes"). This implementation tries file, data and legacy
//  item representations in order, copies payloads into the App Group inside
//  the callback, then writes the exact legacy JSON / UserDefaults / URL scheme
//  expected by the already compiled host plugin.
//
//  Pure Objective-C avoids Swift ABI / compatibility-library mismatches. The
//  runtime class name matches the original NIB's UIClassSwapper string.

#import "ShareExtension.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

static NSString * const kSchemePrefix = @"SharingMedia";
static NSString * const kUserDefaultsKey = @"SharingKey";
static NSString * const kAppGroupIdKey = @"AppGroupId";
static NSString * const kFallbackHostBundleId = @"app.landrop.landrop-flutter";

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
             LANDropUTTypeImage()];
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
    if ([uti isEqualToString:LANDropUTTypeMovie()] ||
        [uti isEqualToString:@"public.quicktime-movie"]) return @"mov";
    if ([uti isEqualToString:@"public.mpeg-4"]) return @"mp4";
    return fallback;
}

#pragma mark - Post-copy screenshot archive repair

static BOOL LANDropIsArchivedPlist(NSData *data) {
    return data.length >= 8 && memcmp(data.bytes, "bplist00", 8) == 0;
}

// The screenshot markup editor can register an in-memory UIImage as
// public.png. Its file representation is a bplist00 NSKeyedArchiver archive,
// while the copy destination has a .png name. Repair exactly that file after
// it has already been copied to the App Group. This never changes the loading,
// UserDefaults or openURL path that makes the host select the attachment.
static void LANDropRepairArchivedPNGAtURL(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!LANDropIsArchivedPlist(data)) return;
    NSError *error = nil;
    id object = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                 [NSSet setWithObjects:UIImage.class, NSData.class, NSURL.class,
                  NSString.class, NSNumber.class, NSArray.class,
                  NSDictionary.class, nil]
                 fromData:data error:&error];
    UIImage *image = nil;
    if ([object isKindOfClass:UIImage.class]) {
        image = (UIImage *)object;
    } else if ([object isKindOfClass:NSData.class]) {
        image = [UIImage imageWithData:(NSData *)object];
    }
    NSData *png = image ? UIImagePNGRepresentation(image) : nil;
    if (png.length && !error) [png writeToURL:url options:NSDataWritingAtomic error:NULL];
}

#pragma mark - Thread-safe completion

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
@end

#pragma mark - Controller

@interface _TtC15Share_Extension19ShareViewController ()
@property (nonatomic, copy) NSString *hostAppBundleIdentifier;
@property (nonatomic, copy) NSString *appGroupId;
@property (nonatomic, strong) LANDropShareState *state;
@property (nonatomic, assign) BOOL hasStarted;
@property (nonatomic, assign) BOOL hasFinished;
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
    if (providers.count == 0) {
        [self finish:NO];
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    for (NSItemProvider *provider in providers) {
        dispatch_group_enter(group);
        [self processProvider:provider completion:^{
            dispatch_group_leave(group);
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [weakSelf saveAndRedirect];
    });
}

- (void)processProvider:(NSItemProvider *)provider completion:(void (^)(void))completion {
    __block BOOL done = NO;
    void (^finish)(BOOL) = ^(BOOL success) {
        if (done) return;
        done = YES;
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
    NSString *name = candidate.lastPathComponent ?: @"";
    if (name.length == 0 || [name isEqualToString:@"/"]) {
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
    LANDropRepairArchivedPNGAtURL(destination);
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
    if (!container) return nil;
    NSURL *destination = [container
        URLByAppendingPathComponent:[self uniqueName:url.absoluteString
                                    defaultExtension:defaultExtension]];

    BOOL accessed = url.isFileURL && [url startAccessingSecurityScopedResource];
    __block BOOL copied = NO;
    NSFileCoordinator *coordinator = [NSFileCoordinator new];
    NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges
                                       error:&coordinationError
                                  byAccessor:^(NSURL *source) {
        NSError *error = nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:destination.path]) [fm removeItemAtURL:destination error:&error];
        if (!error) copied = [fm copyItemAtURL:source toURL:destination error:&error];
    }];
    if (accessed) [url stopAccessingSecurityScopedResource];
    if (coordinationError || !copied) return nil;
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

- (void)writeSharedObject:(id)value forKey:(NSString *)key {
    // Standard App Group suite path.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:self.appGroupId];
    [defaults setObject:value forKey:key];
    [defaults synchronize];

    // TrollStore registers App Group containers manually. CFPrefs can resolve
    // suite domains through either the registered group container or the
    // process HOME; on some iOS/TrollStore combinations these differ between
    // the host app and the extension. Also write the exact plist that
    // UserDefaults(suiteName:) would read, in both candidate locations.
    NSURL *group = [self containerURL];
    NSArray<NSURL *> *roots = group
        ? @[group, [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]]
        : @[[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]];
    for (NSURL *root in roots) {
        NSURL *dir = [root URLByAppendingPathComponent:@"Library/Preferences" isDirectory:YES];
        NSURL *file = [dir URLByAppendingPathComponent:
                       [self.appGroupId stringByAppendingPathExtension:@"plist"]];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error] || error) continue;
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfURL:file].mutableCopy;
        if (!plist) plist = [NSMutableDictionary dictionary];
        plist[key] = value;
        [plist writeToURL:file atomically:YES];
    }
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
            [self writeSharedObject:json forKey:kUserDefaultsKey];
            succeeded = YES;
        }
    } else if (texts.count > 0) {
        [self writeSharedObject:texts forKey:kUserDefaultsKey];
        succeeded = YES;
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
    // Match flutter_sharing_intent 1.1.1 exactly: call openURL on every
    // responder that implements it (do not break after the first), synchronously,
    // then completeRequest. Deferring openURL to a later runloop turn allowed
    // the extension to be killed before the host received the URL.
    SEL selector = sel_registerName("openURL:");
    UIResponder *responder = self;
    while (responder) {
        if ([responder respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [responder performSelector:selector withObject:url];
#pragma clang diagnostic pop
        }
        responder = responder.nextResponder;
    }
    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
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
            NSError *error = [NSError errorWithDomain:@"app.landrop.share-extension"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        @"Unable to load shared content"}];
            [self.extensionContext cancelRequestWithError:error];
        }
    });
}

@end
