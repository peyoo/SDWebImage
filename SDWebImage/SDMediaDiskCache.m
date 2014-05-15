//
//  SDMediaDiskCache.m
//  SDWebImage
//
//  Created by cjpystudio on 15/05/2014.
//  Copyright (c) 2014 Dailymotion. All rights reserved.
//

#import "SDMediaDiskCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "SDWebImageDecoder.h"


@interface SDMediaDiskCache(){
    NSFileManager *_fileManager;
}


@property(nonatomic)NSCache * cache;
@property (strong, nonatomic) NSString *diskCachePath;
@property (nonatomic) dispatch_queue_t ioQueue;

@end


@implementation SDMediaDiskCache


+ (SDMediaDiskCache *)sharedDiskCache{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

-(id)init{
    self=[super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        _diskCachePath = [paths[0] stringByAppendingPathComponent:@"MediaCache"];
        _fileManager = [NSFileManager new];
        if (![_fileManager fileExistsAtPath:_diskCachePath]) {
            [_fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
        }
    }
    return self;
}

-(NSURL*)store:(NSData*)data forKey:(NSURL*)url{
    if (!data) {
        return nil;
    }
    dispatch_sync(self.ioQueue, ^{
        NSString * path=[self defaultCachePathForKey:url.absoluteString];
        [_fileManager createFileAtPath:path contents:data attributes:nil];
        [self.cache setObject:[NSURL fileURLWithPath:path] forKey:url];
    });
    return [self dataURL:url];
    
    
}


-(NSURL*)dataURL:(NSURL*)key{
    return [self.cache objectForKey:key];
}


- (NSString *)cachePathForKey:(NSString *)key inPath:(NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key];
    return [path stringByAppendingPathComponent:filename];
}

- (NSString *)defaultCachePathForKey:(NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

- (NSString *)cachedFileNameForKey:(NSString *)key {
    const char *str = [key UTF8String];
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
    
    return filename;
}
@end
