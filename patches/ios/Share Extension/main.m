//  main.m
//  Share Extension entry point.
//
//  The linker is invoked with `-e _NSExtensionMain`; this file forces a
//  reference to Foundation's NSExtensionMain. The runtime entry point itself
//  is provided by Foundation, exactly as in the original appex.
//
//  Configure the project's "Main Interface" / Info.plist as an extension
//  entry point if a future Xcode target needs an explicit principal class;
//  here we link directly to NSExtensionMain like the original binary.

#import <Foundation/Foundation.h>

extern int NSExtensionMain(int argc, char * _Nullable argv[_Nonnull]);

__attribute__((used))
static int (* const LANDropNSExtensionMainReference)(int, char * _Nullable[_Nonnull]) = &NSExtensionMain;
