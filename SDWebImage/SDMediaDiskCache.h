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

-(void)storeDataURL:(NSURL*)dataURL forKey:(NSURL*)url;

-(NSURL*)store:(NSData*)data forKey:(NSURL*)url;

-(NSURL*)dataURL:(NSURL*)key;


@end
