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

//char nibbleToHex(int nibble);
//char upperToHex(int byteVal);
//char upperToHex(int byteVal)
//{
//    int i = (byteVal & 0xF0) >> 4;
//    return nibbleToHex(i);
//}
//
//char lowerToHex(int byteVal);
//char lowerToHex(int byteVal)
//{
//    int i = (byteVal & 0x0F);
//    return nibbleToHex(i);
//}
//
//char nibbleToHex(int nibble)
//{
//    const int ascii_zero = 48;
//    const int ascii_a = 65;
//	
//    if((nibble >= 0) && (nibble <= 9))
//    {
//        return (char) (nibble + ascii_zero);
//    }
//    if((nibble >= 10) && (nibble <= 15))
//    {
//        return (char) (nibble - 10 + ascii_a);
//    }
//    return '?';
//}


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
	
//	NSString *key = [[NSString alloc] initWithContentsOfFile:@"/Users/joshaber/Desktop/key.txt" encoding:NSISOLatin1StringEncoding error:NULL];
//	NSString *target = @"0634edb7889908902c8fd2dad999873c";
//	
//	NSMutableString *generated = [NSMutableString string];
//	
//	const char *str = [key cStringUsingEncoding:NSASCIIStringEncoding];
//	NSUInteger len = [key lengthOfBytesUsingEncoding:NSASCIIStringEncoding];
//	
//	for(NSUInteger i = 0; i < len; i++) {
//		char chu = upperToHex(str[i]);
//		char chl = lowerToHex(str[i]);
//		[generated appendFormat:@"%c%c", chu, chl];
//	}
//		
////	for(NSUInteger i = 0; i < [key length]; i++) {
////		unichar c = [key characterAtIndex:i];
////		
////		[generated appendFormat:@"%02x", c];
////	}
//	
//	NSLog(@"generated: %@", generated);
//	if([generated isEqualToString:target]) {
//		NSLog(@"works!");
//	} else {
//		NSLog(@"nope :(");
//	}
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
