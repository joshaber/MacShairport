//
//  NSString+MSExtensions.m
//  MacShairport
//
//  Created by Josh Abernathy on 4/22/11.
//  Copyright 2011 Josh Abernathy. All rights reserved.
//

#import "NSString+MSExtensions.h"


@implementation NSString (MSExtensions)

- (int)decimalValueFromHex {
	int decimalValue = 0;
	sscanf([self UTF8String], "%x", &decimalValue);
	return decimalValue;
}

@end
