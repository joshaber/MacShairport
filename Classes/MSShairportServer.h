//
//  MSShairportServer.h
//  MacShairport
//
//  Created by Josh Abernathy on 4/22/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MSShairportConnection.h"

enum {
	MSShairportServerCreateServerErrorCode = -1,
	MSShairportServerPublishServiceErrorCode = -2,
};

@protocol MSShairportServerDelegate <NSObject>
// If fatal == YES then the server has already been stopped by the time the delegate receives this message.
- (void)shairportServerDidEncounterError:(NSError *)error fatal:(BOOL)fatal;
@end


@interface MSShairportServer : NSObject <NSNetServiceDelegate, MSShairportConnectionDelegate> {
	CFSocketRef listeningSocket;
}

@property (nonatomic, assign) __weak id<MSShairportServerDelegate> delegate;

+ (MSShairportServer *)serverWithName:(NSString *)name password:(NSString *)password;

- (BOOL)start:(NSError **)error;
- (void)stop;

@end
