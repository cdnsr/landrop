//  ShareExtension.h
//  Replacement controller for flutter_sharing_intent 1.1.1.
//
//  The compiled MainInterface.storyboardc NIB still asks UIClassSwapper for
//  the Swift-mangled name `_TtC15Share_Extension19ShareViewController`.
//  Defining an Objective-C class with exactly that runtime name lets the
//  original NIB instantiate this class without modifying the NIBArchive.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface _TtC15Share_Extension19ShareViewController : UIViewController
@end

// Keep exactly the integer values decoded by the compiled Dart AOT model:
// text=0, url=1, image=2, video=3, file=4.
typedef NS_ENUM(NSInteger, SharingFileType) {
    SharingFileTypeText = 0,
    SharingFileTypeURL = 1,
    SharingFileTypeImage = 2,
    SharingFileTypeVideo = 3,
    SharingFileTypeFile = 4,
};

NS_ASSUME_NONNULL_END
