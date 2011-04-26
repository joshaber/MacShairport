//
//  MSShairportConnection.h
//  MacShairport
//
//  Created by Josh Abernathy on 4/18/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class MSShairportConnection;

@protocol MSShairportConnectionDelegate <NSObject>
- (void)connection:(MSShairportConnection *)connection didReceiveData:(NSData *)data;
- (void)connectionDidClose:(MSShairportConnection *)connection;
@end


@interface MSShairportConnection : NSObject {
	CFSocketNativeHandle socketHandle;
	CFReadStreamRef readStream;
	CFWriteStreamRef writeStream;
}

@property (nonatomic, assign) __weak id<MSShairportConnectionDelegate> delegate;
@property (nonatomic, copy, readonly) NSString *remoteIP;
@property (nonatomic, retain) NSData *aesIV;
@property (nonatomic, retain) NSData *aesKey;
@property (nonatomic, copy) NSString *fmtp;
@property (nonatomic, retain) NSFileHandle *decoderInputFileHandle;

+ (MSShairportConnection *)connectionWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData;

- (BOOL)open;
- (void)close;

- (void)sendResponse:(NSData *)data;

@end
