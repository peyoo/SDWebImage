//
//  SDMediaDiskCache.h
//  SDWebImage
//
//  Created by cjpystudio on 15/05/2014.
//  Copyright (c) 2014 Dailymotion. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SDMediaDiskCache : NSObject

+ (SDMediaDiskCache *)sharedDiskCache;

-(NSURL*)store:(NSData*)data forKey:(NSURL*)url;


-(NSURL*)dataURL:(NSURL*)key;


@end
