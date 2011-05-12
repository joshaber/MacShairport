//
//  MacShairportAppDelegate.h
//  MacShairport
//
//  Created by Josh Abernathy on 4/18/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MSShairportServer.h"


@interface MacShairportAppDelegate : NSObject <NSApplicationDelegate, MSShairportServerDelegate>
{
@private
    NSWindow *window;
}

@property (assign) IBOutlet NSWindow *window;

@end
