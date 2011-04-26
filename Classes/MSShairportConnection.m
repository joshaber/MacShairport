//
//  MSShairportConnection.m
//  MacShairport
//
//  Created by Josh Abernathy on 4/18/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import "MSShairportConnection.h"
#import <netdb.h>

void readStreamEventHandler(CFReadStreamRef stream, CFStreamEventType eventType, void *info);
void writeStreamEventHandler(CFWriteStreamRef stream, CFStreamEventType eventType, void *info);

@interface MSShairportConnection ()
@property (nonatomic, retain) NSMutableData *outgoingData;
@property (nonatomic, assign) BOOL readStreamOpen;
@property (nonatomic, assign) BOOL writeStreamOpen;
@property (nonatomic, copy) NSString *remoteIP;

- (id)initWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData;
- (void)readStreamHandleEvent:(CFStreamEventType)event;
- (void)readFromStreamIntoIncomingBuffer;
- (void)writeStreamHandleEvent:(CFStreamEventType)event;
- (void)writeOutgoingBufferToStream;
@end


@implementation MSShairportConnection


#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> remoteIP: %@", NSStringFromClass([self class]), self, self.remoteIP];
}


#pragma mark API

@synthesize delegate;
@synthesize outgoingData;
@synthesize readStreamOpen;
@synthesize writeStreamOpen;
@synthesize remoteIP;
@synthesize aesIV;
@synthesize aesKey;
@synthesize fmtp;
@synthesize decoderInputFileHandle;

+ (MSShairportConnection *)connectionWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData {
	return [[[self alloc] initWithSocketHandle:handle addressData:addressData] autorelease];
}

- (void)finalize {
	if(readStream != NULL) {
		CFRelease(readStream);
	}
	
	if(writeStream != NULL) {
		CFRelease(writeStream);
	}
	
	[super finalize];
}

- (id)initWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData {
	self = [super init];
	if(self == nil) return nil;
		
	socketHandle = handle;
		
	if([addressData length] >= sizeof(struct sockaddr_in6)) {
		char hostStr[NI_MAXHOST];
		char servStr[NI_MAXSERV];
		
		int error = getnameinfo([addressData bytes], (socklen_t) [addressData length], hostStr, sizeof(hostStr), servStr, sizeof(servStr), NI_NUMERICHOST | NI_NUMERICSERV);
		NSString *hostString = [NSString stringWithCString:hostStr encoding:NSASCIIStringEncoding];
		// fe80::5a55:caff:fef3:1499%en0
		if(error == 0) {
			// we don't want the interface (en0) part
			self.remoteIP = [hostString substringToIndex:[hostString length] - 4];
		}
	}
	
	return self;
}

- (BOOL)open {
	CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream);
	
	self.outgoingData = [NSMutableData data];
	
	CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
	CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
	
	CFOptionFlags registeredEvents = kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventCanAcceptBytes | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred;
	CFStreamClientContext context = {0, self, NULL, NULL, NULL};
	CFReadStreamSetClient(readStream, registeredEvents, readStreamEventHandler, &context);
	CFWriteStreamSetClient(writeStream, registeredEvents, writeStreamEventHandler, &context);
	
	CFReadStreamScheduleWithRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
	CFWriteStreamScheduleWithRunLoop(writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
	
	Boolean success = CFReadStreamOpen(readStream);
	if(!success) {
		return NO;
	}
	
	success = CFWriteStreamOpen(writeStream);
	if(!success) {
		return NO;
	}
	
	return YES;
}

- (void)close {	
	if(readStream != nil) {
		CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
		CFReadStreamClose(readStream);
		CFRelease(readStream);
		readStream = NULL;
	}
	
	if(writeStream != nil) {
		CFWriteStreamUnscheduleFromRunLoop(writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
		CFWriteStreamClose(writeStream);
		CFRelease(writeStream);
		writeStream = NULL;
	}
	
	self.outgoingData = nil;
}

- (void)sendResponse:(NSData *)data {
	[self.outgoingData appendData:data];
	
	// Try to actually write the data to the stream. If it fails then we can assume we'll get a kCFStreamEventCanAcceptBytes callback later on.
	[self writeOutgoingBufferToStream];
}

void readStreamEventHandler(CFReadStreamRef stream, CFStreamEventType eventType, void *info) {
	id self = info;
	[self readStreamHandleEvent:eventType];
}

- (void)readStreamHandleEvent:(CFStreamEventType)event {
	if(event == kCFStreamEventOpenCompleted) {
		self.readStreamOpen = YES;
	} else if(event == kCFStreamEventHasBytesAvailable) {
		[self readFromStreamIntoIncomingBuffer];
	} else if(event == kCFStreamEventEndEncountered || event == kCFStreamEventErrorOccurred) {
		[self close];		
		[self.delegate connectionDidClose:self];
	}
}

- (void)readFromStreamIntoIncomingBuffer {
	NSMutableData *incomingData = [NSMutableData dataWithCapacity:512];
	while(CFReadStreamHasBytesAvailable(readStream)) {
		UInt8 buffer[512];
		CFIndex length = CFReadStreamRead(readStream, buffer, sizeof(buffer));
		if(length <= 0) {
			[self close];
			[self.delegate connectionDidClose:self];
			return;
		}
		
		[incomingData appendBytes:buffer length:(NSUInteger) length];
	}
	
	[self.delegate connection:self didReceiveData:incomingData];
}

void writeStreamEventHandler(CFWriteStreamRef stream, CFStreamEventType eventType, void *info) {
	MSShairportConnection *self = info;
	[self writeStreamHandleEvent:eventType];
}

- (void)writeStreamHandleEvent:(CFStreamEventType)event {
	if(event == kCFStreamEventOpenCompleted) {
		self.writeStreamOpen = YES;
	} else if(event == kCFStreamEventCanAcceptBytes) {
		[self writeOutgoingBufferToStream];
	} else if(event == kCFStreamEventEndEncountered || event == kCFStreamEventErrorOccurred) {
		[self close];
		[self.delegate connectionDidClose:self];
	}
}

- (void)writeOutgoingBufferToStream {
	if(!self.readStreamOpen || !self.writeStreamOpen) {
		return;
	}
	
	if([self.outgoingData length] == 0) {
		return;
	}
	
	if(!CFWriteStreamCanAcceptBytes(writeStream)) { 
		return;
	}
	
	CFIndex writtenBytes = CFWriteStreamWrite(writeStream, [self.outgoingData bytes], (CFIndex) [self.outgoingData length]);
	if(writtenBytes == -1) {
		[self close];
		[self.delegate connectionDidClose:self];
		return;
	}
	
	NSRange range = {0, (NSUInteger) writtenBytes};
	[self.outgoingData replaceBytesInRange:range withBytes:NULL length:0];
}

@end
