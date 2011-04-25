//
//  NSData+MSExtensions.m
//  MacShairport
//
//  Created by Josh Abernathy on 4/24/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import "NSData+MSExtensions.h"


@implementation NSData (MSExtensions)

// from http://www.iphonedevsdk.com/forum/iphone-sdk-development/32828-nsdata-hex-string.html
- (NSString *)stringWithHexBytes {
	static const char hexdigits[] = "0123456789abcdef";
	const NSUInteger numBytes = [self length];
	const unsigned char *bytes = [self bytes];
	char *strbuf = (char *) malloc(numBytes * 2 + 1);
	char *hex = strbuf;
	NSString *hexBytes = nil;
	
	for(NSUInteger i = 0; i < numBytes; ++i) {
		const unsigned char c = *bytes++;
		*hex++ = hexdigits[(c >> 4) & 0xF];
		*hex++ = hexdigits[(c ) & 0xF];
	}
	*hex = 0;
	hexBytes = [NSString stringWithUTF8String:strbuf];
	free(strbuf);
	return hexBytes;
}

@end
