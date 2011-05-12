//
//  MSShairportServer.m
//  MacShairport
//
//  Created by Josh Abernathy on 4/22/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import "MSShairportServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import "NSData+Base64.h"
#import "SSCrypto.h"
#import "NSString+MSExtensions.h"
#import "NSData+MSExtensions.h"

static void serverAcceptCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

static const int MSShairportServerPort = 5000;

// The MAC address doesn't actually have to be right, just has to be a valid format.
static NSString * const MSShairportServerMACAddress = @"fe:dc:ba:98:75:50";

static SSCrypto *crypto = nil;

@interface MSShairportServer ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, retain) NSMutableArray *connections;
@property (nonatomic, retain) NSNetService *netService;

- (BOOL)createServer;
- (BOOL)publishService;
- (void)unpublishService;
- (void)shutdownServer;
- (NSDictionary *)responseDictionaryFromRawString:(NSString *)string;
- (void)respondToRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection;
- (void)handleAnnounceRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection;
- (void)handleSetupRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection response:(NSMutableDictionary *)response;
- (void)handleSetParameterRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection;
- (NSString *)generateAppleResponseFromChallenge:(NSString *)challenge connection:(MSShairportConnection *)connection;
- (NSString *)MACAddressToRawString;
- (NSArray *)MACAddressComponents;
@end


@implementation MSShairportServer

- (void)finalize {
	if(listeningSocket != NULL) {
		CFRelease(listeningSocket);
	}
	
	[super finalize];
}

+ (void)initialize {
	if(self == [MSShairportServer class]) {
		NSString *path = [[NSBundle mainBundle] pathForResource:@"airport_rsa" ofType:@""];
		NSData *key = [[NSData alloc] initWithContentsOfFile:path];
		crypto = [[SSCrypto alloc] initWithPrivateKey:key];
	}
}


#pragma mark MSShairportConnectionDelegate

- (void)connection:(MSShairportConnection *)connection didReceiveData:(NSData *)data {
	NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	DebugLog(@"Raw request: %@", contents);
	
	NSDictionary *request = [self responseDictionaryFromRawString:contents];
	
	DebugLog(@"Parsed request: %@", request);
	
	[self respondToRequest:request connection:connection];
}

- (void)connectionDidClose:(MSShairportConnection *)connection {
	DebugLog(@"Connection closed: %@", connection);
	
	[self.connections removeObject:connection];
}


#pragma mark NSNetServiceDelegate

- (void)netServiceDidPublish:(NSNetService *)sender {
	DebugLog(@"Published: %@: %lu", [sender type], [sender port]);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
	[self stop];
		
	[self.delegate shairportServerDidEncounterError:[NSError errorWithDomain:[errorDict objectForKey:NSNetServicesErrorDomain] code:[[errorDict objectForKey:NSNetServicesErrorCode] integerValue] userInfo:nil] fatal:YES];
}


#pragma mark API

@synthesize name;
@synthesize password;
@synthesize connections;
@synthesize netService;
@synthesize delegate;

+ (MSShairportServer *)serverWithName:(NSString *)name password:(NSString *)password {
	MSShairportServer *server = [[[self alloc] init] autorelease];
	server.name = name;
	server.password = password;
	return server;
}

- (id)init {
	self = [super init];
	if(self == nil) return nil;
	
	self.connections = [NSMutableArray array];
	
	return self;
}

- (BOOL)start:(NSError **)error {
	BOOL success = [self createServer];
	if(!success) {
		if(error != NULL) *error = [NSError errorWithDomain:NSStringFromClass([self class]) code:MSShairportServerCreateServerErrorCode userInfo:nil];
		return NO;
	}
	
	success = [self publishService];
	if(!success) {
		if(error != NULL) *error = [NSError errorWithDomain:NSStringFromClass([self class]) code:MSShairportServerPublishServiceErrorCode userInfo:nil];
		return NO;
	}
	
	return YES;
}

- (BOOL)createServer {
	CFSocketContext socketContext = {0, self, NULL, NULL, NULL};
	listeningSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET6, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, (CFSocketCallBack) &serverAcceptCallback, &socketContext);
	if(listeningSocket == NULL) {
		return NO;
	}
	
	int existingValue = 1;
	int fileDescriptor = CFSocketGetNative(listeningSocket);
	int err = setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, (void *) &existingValue, sizeof(existingValue));
	if(err != 0) {
		DebugLog(@"Unable to set socket address reuse.");
		
		CFRelease(listeningSocket);
		listeningSocket = NULL;
		
		return NO;
	}
	
	struct sockaddr_in6 address;
	address.sin6_len = sizeof(struct sockaddr_in6);
	address.sin6_family = AF_INET6;
	address.sin6_port = htons(MSShairportServerPort);
	address.sin6_flowinfo = 0;
	address.sin6_addr = in6addr_any;
	address.sin6_scope_id = 0;
	
	CFDataRef addressData = CFDataCreate(NULL, (const UInt8 *)&address, sizeof(address));
	[(id) addressData autorelease];
	
	CFSocketError error = CFSocketSetAddress(listeningSocket, addressData);
	if(error != kCFSocketSuccess) {
		DebugLog(@"Unable to set the socket address.");
		
		CFRelease(listeningSocket);
		listeningSocket = NULL;
		
		return NO;
	}
	
	CFRunLoopSourceRef runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, listeningSocket, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
	CFRelease(runLoopSource);
	
	return YES;
}

static void serverAcceptCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
	MSShairportServer *self = info;
	
	if(type != kCFSocketAcceptCallBack) {
		return;
	}
	
	NSData *addressData = (NSData *) address;
	CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *) data;
	
	MSShairportConnection *newConnection = [MSShairportConnection connectionWithSocketHandle:nativeSocketHandle addressData:addressData];
	[self.connections addObject:newConnection];
	newConnection.delegate = self;
	
	BOOL success = [newConnection open];
	if(!success) {
		DebugLog(@"Couldn't open new connection.");
		return;
	}
}

- (void)respondToRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection {
	NSMutableDictionary *response = [NSMutableDictionary dictionary];
	
	// we always respond with these regardless of the request
	[response setObject:[request objectForKey:@"CSeq"] forKey:@"CSeq"];
	[response setObject:@"connected; type=analog" forKey:@"Audio-Jack-Status"];
	
	NSString *challenge = [request objectForKey:@"Apple-Challenge"];
	if(challenge != nil) {
		NSString *challengeResponse = [self generateAppleResponseFromChallenge:challenge connection:connection];
		[response setObject:challengeResponse forKey:@"Apple-Response"];
	}
	
	if(self.password != nil) {
		// TODO: check auth
	}
	
	BOOL shouldClose = NO;
	NSString *method = [request objectForKey:@"Method"];
	if([method hasPrefix:@"OPTIONS"]) {
		[response setObject:@"ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER" forKey:@"Public"];
	} else if([method hasPrefix:@"ANNOUNCE"]) {
		[self handleAnnounceRequest:request connection:connection];
	} else if([method hasPrefix:@"SETUP"]) {
		[self handleSetupRequest:request connection:connection response:response];
	} else if([method hasPrefix:@"RECORD"]) {
		// RECORD means the stream has started with hairtunes but it doesn't require any special response from us
	} else if([method hasPrefix:@"FLUSH"]) {
		[connection.decoderInputFileHandle writeData:[@"flush\n" dataUsingEncoding:NSASCIIStringEncoding]];
	} else if([method hasPrefix:@"TEARDOWN"]) {
		[response setObject:@"close" forKey:@"Connection"];
		[connection.decoderInputFileHandle closeFile];
		shouldClose = YES;
	} else if([method hasPrefix:@"SET_PARAMETER"]) {
		[self handleSetParameterRequest:request connection:connection];
	} else if([method hasPrefix:@"GET_PARAMETER"]) {
		// TODO: it might be nice to return something here but shairtunes.pl doesn't
	} else if([method hasPrefix:@"DENIED"]) {
		// awww shit
	} else {
		DebugLog(@"Unknown method: %@", method);
	}
	
	static NSString * const responseHeader = @"RTSP/1.0 200 OK";
	NSMutableString *responseString = [NSMutableString stringWithFormat:@"%@\r\n", responseHeader];
	for(NSString *key in response) {
		NSString *value = [response objectForKey:key];
		[responseString appendFormat:@"%@: %@\r\n", key, value];
	}
	
	[responseString appendFormat:@"\r\n"];
	
	DebugLog(@"Response: %@", responseString);
	
	[connection sendResponse:[responseString dataUsingEncoding:NSUTF8StringEncoding]];
	
	if(shouldClose) {
		[connection close];
		[self.connections removeObject:connection];
	}
}

- (void)handleAnnounceRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection {
	NSString *bodyString = [request objectForKey:@"Body"];
	NSMutableDictionary *body = [NSMutableDictionary dictionary];
	[bodyString enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
		NSArray *pieces = [line componentsSeparatedByString:@"="];
		if(pieces.count >= 2) {				
			NSMutableArray *remainingPieces = [pieces mutableCopy];
			[remainingPieces removeObjectAtIndex:0];
			NSString *value = [remainingPieces componentsJoinedByString:@""];
			pieces = [value componentsSeparatedByString:@":"];
			
			if(pieces.count >= 2) {
				[body setObject:[pieces objectAtIndex:1] forKey:[pieces objectAtIndex:0]];
			}
		}
	}];
	
	NSString *aesIV = [body objectForKey:@"aesiv"];
	NSParameterAssert(aesIV != nil);
	connection.aesIV = [NSData dataFromBase64String:aesIV];
	
	NSString *rsaaesKey = [body objectForKey:@"rsaaeskey"];
	NSParameterAssert(rsaaesKey != nil);
	
	rsaaesKey = [[NSString alloc] initWithData:[NSData dataFromBase64String:rsaaesKey] encoding:NSISOLatin1StringEncoding];
	[crypto setCipherText:[rsaaesKey dataUsingEncoding:NSISOLatin1StringEncoding]];
	NSData *aesKey = [crypto decrypt];
	NSParameterAssert(aesKey != nil);
	connection.aesKey = aesKey;
	
	connection.fmtp = [body objectForKey:@"fmtp"];
}

- (void)handleSetupRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection response:(NSMutableDictionary *)response {
	NSString *transport = [request objectForKey:@"Transport"];
	
	// RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=6001;timing_port=6002
	NSArray *pieces = [transport componentsSeparatedByString:@";"];
	NSMutableDictionary *transportValues = [NSMutableDictionary dictionary];
	for(NSString *piece in pieces) {
		NSArray *pair = [piece componentsSeparatedByString:@"="];
		if(pair.count >= 2) {
			[transportValues setObject:[pair objectAtIndex:1] forKey:[pair objectAtIndex:0]];
		}
	}
	
	NSString *cport = [transportValues objectForKey:@"control_port"];
	NSString *tport = [transportValues objectForKey:@"timing_port"];
	NSString *dport = [transportValues objectForKey:@"server_port"];
	if(dport == nil) {
		dport = tport;
	}
	
	NSString *iv = [connection.aesIV stringWithHexBytes];
	NSString *key = [connection.aesKey stringWithHexBytes];
	
	NSString *path = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"hairtunes"];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath:path];
	
	NSArray *arguments = [NSArray arrayWithObjects:@"tport", tport, @"iv", iv, @"cport", cport, @"fmtp", connection.fmtp, @"dport", dport, @"key", key, nil];
	[task setArguments:arguments];
	
	NSPipe *outputPipe = [NSPipe pipe];
	[task setStandardOutput:outputPipe];
	NSFileHandle *outputFileHandle = [outputPipe fileHandleForReading];
	
	NSPipe *inputPipe = [NSPipe pipe];
	[task setStandardInput:inputPipe];
	NSFileHandle *inputFileHandle = [inputPipe fileHandleForWriting];
	
	connection.decoderInputFileHandle = inputFileHandle;
	
	[task launch];
	
	__block NSString *serverPort = @"";
	while(YES) {
		NSData *data = [outputFileHandle availableData];
		NSString *output = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
		__block BOOL done = NO;
		[output enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
			if([line hasPrefix:@"port: "]) {
				NSString *portString = [line stringByReplacingOccurrencesOfString:@"port: " withString:@""];
				serverPort = [portString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				done = YES;
				*stop = YES;
			}
		}];
		
		if(done) break;
		
		if(![task isRunning]) {
			break;
		}
		
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate distantPast]];
	}
		
	[response setObject:@"DEADBEEF" forKey:@"Session"];
	[response setObject:[NSString stringWithFormat:@"%@;server_port=%@", transport, serverPort] forKey:@"Transport"];
}

- (void)handleSetParameterRequest:(NSDictionary *)request connection:(MSShairportConnection *)connection {
	NSString *bodyString = [request objectForKey:@"Body"];
	NSMutableDictionary *body = [NSMutableDictionary dictionary];
	[bodyString enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
		NSArray *pieces = [line componentsSeparatedByString:@": "];
		if(pieces.count >= 2) {				
			[body setObject:[pieces objectAtIndex:1] forKey:[pieces objectAtIndex:0]];
		}
	}];
	
	[connection.decoderInputFileHandle writeData:[[NSString stringWithFormat:@"vol: %f\n", [[body objectForKey:@"volume"] floatValue]] dataUsingEncoding:NSASCIIStringEncoding]];
}

- (void)stop {
	for(MSShairportConnection *connection in self.connections) {
		[connection close];
		[self.connections removeObject:connection];
	}
	
	[self shutdownServer];
	[self unpublishService];
}

- (NSDictionary *)responseDictionaryFromRawString:(NSString *)string {
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
	NSMutableString *body = [NSMutableString string];
	
	__block BOOL firstLine = YES;
	__block BOOL isBody = NO;
	[string enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
		line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		
		if(firstLine) {
			[dictionary setObject:line forKey:@"Method"];
			
			firstLine = NO;
		} else {
			if(!isBody) {
				if(line.length < 1) {
					isBody = YES;
					return;
				}
				
				NSArray *components = [line componentsSeparatedByString:@":"];
				if(components.count > 1) {
					NSString *key = [[components objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
					NSString *value = [[components objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
					[dictionary setObject:value forKey:key];
				} else {
					DebugLog(@"Cannot parse: %@", line);
				}
			} else {
				[body appendFormat:@"%@\r\n", line];
			}
		}
	}];
	
	[dictionary setObject:body forKey:@"Body"];
	
	return dictionary;
}

- (NSString *)generateAppleResponseFromChallenge:(NSString *)challenge connection:(MSShairportConnection *)connection {
	NSData *challengeData = [NSData dataFromBase64String:challenge];
	NSMutableString *challengeString = [[[NSString alloc] initWithData:challengeData encoding:NSISOLatin1StringEncoding] mutableCopy];
	
	// connection.remoteIP = fe80::5a55:caff:fef3:1499
    if ([connection.remoteIP hasPrefix:@"::ffff:"]) {
        NSString* ip4 = [[connection.remoteIP substringFromIndex:7] autorelease];
        NSArray* pieces = [[ip4 componentsSeparatedByString:@"."] autorelease];
        for(NSString* piece in pieces) {
            unsigned short value = (unsigned short)[piece integerValue]; 
            [challengeString appendFormat: @"%C", value];
        }
    } else {
        NSArray *ipPieces = [[connection.remoteIP componentsSeparatedByString:@"::"] autorelease];
        // ipPieces = [fe80, 5a55:caff:fef3:1499
        
        NSArray *leftPieces = [[[ipPieces objectAtIndex:0] componentsSeparatedByString:@":"] autorelease];
        NSArray *rightPieces = [[[ipPieces objectAtIndex:1] componentsSeparatedByString:@":"] autorelease];
        // left = [fe80], right = [5a55, caff, fef3, 1499]
        
        // most IPv6 address will be abbreviated, iTunes wants the full address so we'll expand it out
        NSMutableArray *paddingPieces = [[NSMutableArray array] autorelease];
        NSUInteger padding = 8 - (leftPieces.count + rightPieces.count);
        for(NSUInteger i = 0; i < padding; i++) {
            [paddingPieces addObject:@"0x0"];
        }
        
        NSMutableArray *allPieces = [[NSMutableArray array] autorelease];
        [allPieces addObjectsFromArray:leftPieces];
        [allPieces addObjectsFromArray:paddingPieces];
        [allPieces addObjectsFromArray:rightPieces];
        
        for(NSString *piece in allPieces) {
            unsigned short value = (unsigned short) [piece decimalValueFromHex];
            value = (unsigned short) CFSwapInt16HostToBig(value);
            [challengeString appendFormat:[[NSString alloc] initWithData:[NSData dataWithBytes:&value length:sizeof(value)] encoding:NSISOLatin1StringEncoding]];
        }
    }
    
	NSArray *macComponents = [[self MACAddressComponents] autorelease];
	for(NSString *component in macComponents) {
		[challengeString appendFormat:@"%C", [component decimalValueFromHex]];
	}
    
    NSUInteger len = 32 - [challengeString length];
    while (len > 0) {
        --len;
        [challengeString appendFormat:@"%C", 0];
    }
    
	[crypto setClearTextWithData:[challengeString dataUsingEncoding:NSISOLatin1StringEncoding]];
	NSData *encryptedTextData = [crypto sign];
	
	NSString *encryptedString = [[encryptedTextData base64EncodedString] autorelease];
	encryptedString = [encryptedString stringByReplacingOccurrencesOfString:@"\r\n" withString:@""];
	encryptedString = [encryptedString stringByReplacingOccurrencesOfString:@"=" withString:@""];
	return encryptedString;
}


- (void)shutdownServer {
	if(listeningSocket != NULL) {
		CFSocketInvalidate(listeningSocket);
		CFRelease(listeningSocket);
		listeningSocket = NULL;
	}
}

- (BOOL)publishService {
 	self.netService = [[NSNetService alloc] initWithDomain:@"" type:@"_raop._tcp" name:[NSString stringWithFormat:@"%@@%@", [self MACAddressToRawString], self.name] port:MSShairportServerPort];
	if(self.netService == nil) return NO;
	
	// "tp=UDP","sm=false","sv=false","ek=1","et=0,1","cn=0,1","ch=2","ss=16","sr=44100","pw=false","vn=3","txtvers=1"
	NSMutableDictionary *txtData = [NSMutableDictionary dictionary];
	[txtData setObject:@"UDP" forKey:@"tp"];
	[txtData setObject:@"false" forKey:@"sm"];
	[txtData setObject:@"false" forKey:@"sv"];
	[txtData setObject:@"1" forKey:@"ek"];
	[txtData setObject:@"0,1" forKey:@"et"];
	[txtData setObject:@"0,1" forKey:@"cn"];
	[txtData setObject:@"2" forKey:@"ch"];
	[txtData setObject:@"16" forKey:@"ss"];
	[txtData setObject:@"44100" forKey:@"sr"];
	[txtData setObject:@"false" forKey:@"pw"];
	[txtData setObject:@"3" forKey:@"vn"];
	[txtData setObject:@"1" forKey:@"txtvers"];
	
	[self.netService setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txtData]];
	
	[self.netService scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	[self.netService setDelegate:self];
	[self.netService publish];
	
	return YES;
}

- (void)unpublishService {
	[self.netService stop];
	[self.netService removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	self.netService = nil;
}

- (NSString *)MACAddressToRawString {
	return [MSShairportServerMACAddress stringByReplacingOccurrencesOfString:@":" withString:@""];
}

- (NSArray *)MACAddressComponents {
	return [MSShairportServerMACAddress componentsSeparatedByString:@":"];
}

@end
