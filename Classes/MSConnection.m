//
//  MSConnection.m
//  MacShairport
//
//  Created by Josh Abernathy on 4/18/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import "MSConnection.h"
#import <netdb.h>

void readStreamEventHandler(CFReadStreamRef stream, CFStreamEventType eventType, void *info);
void writeStreamEventHandler(CFWriteStreamRef stream, CFStreamEventType eventType, void *info);

@interface MSConnection ()
@property (nonatomic, assign) CFSocketNativeHandle socketHandle;
@property (nonatomic, retain) NSMutableData *incomingData;
@property (nonatomic, retain) NSMutableData *outgoingData;
@property (nonatomic, assign) CFReadStreamRef readStream;
@property (nonatomic, assign) CFWriteStreamRef writeStream;
@property (nonatomic, assign) BOOL readStreamOpen;
@property (nonatomic, assign) BOOL writeStreamOpen;
@property (nonatomic, copy) NSString *remoteIP;

- (id)initWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData;
- (void)close;
- (void)readStreamHandleEvent:(CFStreamEventType)event;
- (void)readFromStreamIntoIncomingBuffer;
- (void)writeStreamHandleEvent:(CFStreamEventType)event;
- (void)writeOutgoingBufferToStream;
@end


@implementation MSConnection


#pragma mark API

@synthesize delegate;
@synthesize socketHandle;
@synthesize readStream;
@synthesize writeStream;
@synthesize incomingData;
@synthesize outgoingData;
@synthesize readStreamOpen;
@synthesize writeStreamOpen;
@synthesize remoteIP;

+ (MSConnection *)connectionWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData {
	return [[[self alloc] initWithSocketHandle:handle addressData:addressData] autorelease];
}

- (id)initWithSocketHandle:(CFSocketNativeHandle)handle addressData:(NSData *)addressData {
	self = [super init];
	if(self == nil) return nil;
		
	self.socketHandle = handle;
		
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
	CFStreamCreatePairWithSocket(kCFAllocatorDefault, self.socketHandle, &readStream, &writeStream);
	
	self.incomingData = [NSMutableData data];
	self.outgoingData = [NSMutableData data];
	
	CFReadStreamSetProperty(self.readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
	CFWriteStreamSetProperty(self.writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
	
	NSMakeCollectable(self.readStream);
	NSMakeCollectable(self.writeStream);
	
	CFOptionFlags registeredEvents = kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventCanAcceptBytes | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred;
	CFStreamClientContext context = {0, self, NULL, NULL, NULL};
	CFReadStreamSetClient(self.readStream, registeredEvents, readStreamEventHandler, &context);
	CFWriteStreamSetClient(self.writeStream, registeredEvents, writeStreamEventHandler, &context);
	
	CFReadStreamScheduleWithRunLoop(self.readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
	CFWriteStreamScheduleWithRunLoop(self.writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
	
	Boolean success = CFReadStreamOpen(self.readStream);
	if(!success) {
		return NO;
	}
	
	success = CFWriteStreamOpen(self.writeStream);
	if(!success) {
		return NO;
	}
	
	return YES;
}

- (void)close {	
	if(self.readStream != nil) {
		CFReadStreamUnscheduleFromRunLoop(self.readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
		CFReadStreamClose(self.readStream);
		self.readStream = NULL;
	}
	
	if(writeStream != nil) {
		CFWriteStreamUnscheduleFromRunLoop(self.writeStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
		CFWriteStreamClose(self.writeStream);
		self.writeStream = NULL;
	}
	
	self.incomingData = nil;
	self.outgoingData = nil;
}

- (void)sendResponse:(NSData *)data {
	[self.outgoingData appendData:data];
}

void readStreamEventHandler(CFReadStreamRef stream, CFStreamEventType eventType, void *info) {
	MSConnection *connection = info;
	[connection readStreamHandleEvent:eventType];
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
	while(CFReadStreamHasBytesAvailable(self.readStream)) {
		UInt8 buffer[1024];
		CFIndex length = CFReadStreamRead(readStream, buffer, sizeof(buffer));
		if(length <= 0) {
			[self close];
			[self.delegate connectionDidClose:self];
			return;
		}
		
		[self.incomingData appendBytes:buffer length:(NSUInteger) length];
	}
	
	[self.delegate connection:self didReceiveData:self.incomingData];
	
	self.incomingData = [NSMutableData data];
}

void writeStreamEventHandler(CFWriteStreamRef stream, CFStreamEventType eventType, void *info) {
	MSConnection *connection = info;
	[connection writeStreamHandleEvent:eventType];
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
	
	if(!CFWriteStreamCanAcceptBytes(self.writeStream)) { 
		return;
	}
	
	CFIndex writtenBytes = CFWriteStreamWrite(self.writeStream, [self.outgoingData bytes], (CFIndex) [self.outgoingData length]);
	if(writtenBytes == -1) {
		[self close];
		[self.delegate connectionDidClose:self];
		return;
	}
	
	NSRange range = {0, (NSUInteger) writtenBytes};
	[self.outgoingData replaceBytesInRange:range withBytes:NULL length:0];
}

@end
