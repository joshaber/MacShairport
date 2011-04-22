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

static void serverAcceptCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

static const int MSShairportServerPort = 5000;

// The MAC address doesn't actually have to be right, just has to be a valid format.
static NSString * const MSShairportServerMACAddress = @"fe:dc:ba:98:76:53";

@interface MSShairportServer ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, retain) NSMutableArray *connections;
@property (nonatomic, retain) NSNetService *netService;
@property (nonatomic, assign) CFSocketRef listeningSocket;

- (BOOL)createServer;
- (BOOL)publishService;
- (void)unpublishService;
- (void)shutdownServer;
- (NSDictionary *)responseDictionaryFromRawString:(NSString *)string;
- (void)respondToRequest:(NSDictionary *)request connection:(MSConnection *)connection;
- (NSString *)generateAppleResponseFromChallenge:(NSString *)challenge connection:(MSConnection *)connection;
- (NSString *)MACAddressToRawString;
- (NSArray *)MACAddressComponents;
@end


@implementation MSShairportServer


#pragma mark MSConnectionDelegate

- (void)connection:(MSConnection *)connection didReceiveData:(NSData *)data {
	NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	DebugLog(@"Raw request: %@", contents);
	
	NSDictionary *request = [self responseDictionaryFromRawString:contents];
	
	DebugLog(@"Parsed request: %@", request);
	
	[self respondToRequest:request connection:connection];
}

- (void)connectionDidClose:(MSConnection *)connection {	
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
@synthesize listeningSocket;

+ (MSShairportServer *)serverWithName:(NSString *)name password:(NSString *)password {
	MSShairportServer *server = [[[self alloc] init] autorelease];
	server.name = name;
	server.password = password;
	return server;
}

- (BOOL)start:(NSError **)error {
	BOOL success = [self createServer];
	if(!success) {
		if(error != NULL) *error = [NSError errorWithDomain:NSStringFromClass([self class]) code:-1 userInfo:nil];
		return NO;
	}
	
	success = [self publishService];
	if(!success) {
		if(error != NULL) *error = [NSError errorWithDomain:NSStringFromClass([self class]) code:-1 userInfo:nil];
		return NO;
	}
	
	return YES;
}

- (BOOL)createServer {
	CFSocketContext socketContext = {0, self, NULL, NULL, NULL};
	self.listeningSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET6, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, (CFSocketCallBack) &serverAcceptCallback, &socketContext);
	NSMakeCollectable(self.listeningSocket);
	if(self.listeningSocket == NULL) {
		return NO;
	}
	
	int existingValue = 1;
	int fileDescriptor = CFSocketGetNative(self.listeningSocket);
	int err = setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, (void *) &existingValue, sizeof(existingValue));
	if(err != 0) {
		DebugLog(@"Wasn't able to set socket options");
		
		self.listeningSocket = NULL;
		
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
	
	CFSocketError error = CFSocketSetAddress(self.listeningSocket, addressData);
	if(error != kCFSocketSuccess) {
		DebugLog(@"Unable to set the socket address.");
		
		self.listeningSocket = NULL;
		
		return NO;
	}
	
	CFRunLoopSourceRef runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, self.listeningSocket, 0);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
	CFRelease(runLoopSource);
	
	return YES;
}

static void serverAcceptCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
	MSShairportServer *server = info;
	
	if(type != kCFSocketAcceptCallBack) {
		return;
	}
	
	NSData *addressData = (NSData *) address;
	CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;
	
	MSConnection *newConnection = [MSConnection connectionWithSocketHandle:nativeSocketHandle addressData:addressData];
	[server.connections addObject:newConnection];
	newConnection.delegate = server;
	
	BOOL success = [newConnection open];
	if(!success) {
		DebugLog(@"Couldn't open new connection.");
		return;
	}
}

- (void)respondToRequest:(NSDictionary *)request connection:(MSConnection *)connection {
	NSString *responseHeader = @"RTSP/1.0 200 OK";
	
	NSMutableDictionary *response = [NSMutableDictionary dictionary];
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
	
	NSString *method = [request objectForKey:@"Method"];
	if([method hasPrefix:@"OPTIONS"]) {
		[response setObject:@"ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER" forKey:@"Public"];
	} else if([method hasPrefix:@"ANNOUNCE"]) {
		// TODO: parse AESIV and AESKEY
	} else if([method hasPrefix:@"SETUP"]) {
		// TODO: parse transport settings and spawn hairtunes
	} else if([method hasPrefix:@"RECORD"]) {
		// TODO: umm... nothing?
	} else if([method hasPrefix:@"FLUSH"]) {
		// TODO: flush hairtunes
	} else if([method hasPrefix:@"TEARDOWN"]) {
		// TODO: close connections
	} else if([method hasPrefix:@"SET_PARAMETER"]) {
		// TODO: pass along to hairtunes
	} else if([method hasPrefix:@"GET_PARAMETER"]) {
		// TODO: nothing?
	} else if([method hasPrefix:@"DENIED"]) {
		// shit
	} else {
		DebugLog(@"Unknown method: %@", method);
	}
	
	DebugLog(@"Body: %@", [request objectForKey:@"Body"]);
	
	NSMutableString *responseString = [NSMutableString stringWithFormat:@"%@\r\n", responseHeader];
	for(NSString *key in response) {
		NSString *value = [response objectForKey:key];
		[responseString appendFormat:@"%@: %@\r\n", key, value];
	}
	
	[responseString appendFormat:@"\r\n"];
	
	DebugLog(@"Response: %@", responseString);
	
	[connection sendResponse:[responseString dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)stop {
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

- (NSString *)generateAppleResponseFromChallenge:(NSString *)challenge connection:(MSConnection *)connection {
	NSData *challengeData = [NSData dataFromBase64String:challenge];
	NSMutableString *challengeString = [[[NSString alloc] initWithData:challengeData encoding:NSISOLatin1StringEncoding] mutableCopy];
	
	// connection.remoteIP = fe80::5a55:caff:fef3:1499
	NSArray *ipPieces = [connection.remoteIP componentsSeparatedByString:@"::"];
	// ipPieces = [fe80, 5a55:caff:fef3:1499
	
	NSArray *leftPieces = [[ipPieces objectAtIndex:0] componentsSeparatedByString:@":"];
	NSArray *rightPieces = [[ipPieces objectAtIndex:1] componentsSeparatedByString:@":"];
	// left = [fe80], right = [5a55, caff, fef3, 1499]
	
	NSMutableArray *paddingPieces = [NSMutableArray array];
	NSUInteger padding = 8 - (leftPieces.count + rightPieces.count);
	for(NSUInteger i = 0; i < padding; i++) {
		[paddingPieces addObject:@"0x0"];
	}
	
	NSMutableArray *allPieces = [NSMutableArray array];
	[allPieces addObjectsFromArray:leftPieces];
	[allPieces addObjectsFromArray:paddingPieces];
	[allPieces addObjectsFromArray:rightPieces];
	
	for(NSString *piece in allPieces) {
		unsigned short value = (unsigned short) [piece decimalValueFromHex];
		value = (unsigned short) CFSwapInt16HostToBig(value);
		[challengeString appendFormat:[[NSString alloc] initWithData:[NSData dataWithBytes:&value length:sizeof(value)] encoding:NSISOLatin1StringEncoding]];
	}
	
	NSArray *macComponents = [self MACAddressComponents];
	for(NSString *component in macComponents) {
		[challengeString appendFormat:@"%C", [component decimalValueFromHex]];
	}
	
	NSString *path = [[NSBundle mainBundle] pathForResource:@"airport_rsa" ofType:@""];
	NSData *key = [[NSData alloc] initWithContentsOfFile:path];
	
	SSCrypto *crypto = [[SSCrypto alloc] initWithPrivateKey:key];
	[crypto setClearTextWithData:[challengeString dataUsingEncoding:NSISOLatin1StringEncoding]];
	NSData *encryptedTextData = [crypto sign];
	
	NSString *encryptedString = [encryptedTextData base64EncodedString];
	encryptedString = [encryptedString stringByReplacingOccurrencesOfString:@"\r\n" withString:@""];
	encryptedString = [encryptedString stringByReplacingOccurrencesOfString:@"=" withString:@""];
	return encryptedString;
}

- (void)shutdownServer {
	if(self.listeningSocket != NULL) {
		CFSocketInvalidate(self.listeningSocket);
		self.listeningSocket = NULL;
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
