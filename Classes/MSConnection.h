//
//  MSConnection.h
//  MacShairport
//
//  Created by Josh Abernathy on 4/18/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class MSConnection;

@protocol MSConnectionDelegate <NSObject>
- (void)connection:(MSConnection *)connection didReceiveData:(NSData *)data;
- (void)connectionDidClose:(MSConnection *)connection;
@end


@interface MSConnection : NSObject {}

@property (nonatomic, assign) __weak id<MSConnectionDelegate> delegate;
@property (nonatomic, copy, readonly) NSString *remoteIP;

+ (MSConnection *)connectionWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData;

- (BOOL)open;

- (void)sendResponse:(NSData *)data;

@end
