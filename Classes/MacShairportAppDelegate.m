//
//  MacShairportAppDelegate.m
//  MacShairport
//
//  Created by Josh Abernathy on 4/18/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import "MacShairportAppDelegate.h"

static NSString * const MacShairportAppDelegateDefaultPassword = nil;

@interface MacShairportAppDelegate ()
@property (nonatomic, retain) MSShairportServer *server;
@end


@implementation MacShairportAppDelegate


#pragma mark NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	NSString *computerName = NSMakeCollectable(SCDynamicStoreCopyComputerName(NULL, NULL));
	self.server = [MSShairportServer serverWithName:computerName password:MacShairportAppDelegateDefaultPassword];
	self.server.delegate = self;
	
	NSError *error = nil;
	BOOL success = [self.server start:&error];
	if(!success) {
		[NSApp presentError:error];
	}
}

- (void)applicationWillTerminate:(NSNotification *)notification {
	[self.server stop];
}


#pragma mark MSShairportServerDelegate

- (void)shairportServerDidEncounterError:(NSError *)error fatal:(BOOL)fatal {
	[NSApp presentError:error];
}


#pragma mark API

@synthesize window;
@synthesize server;

@end
