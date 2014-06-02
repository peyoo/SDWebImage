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
#include <sys/xattr.h>

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

- (void) addSkipBackupAttributeToFile: (NSURL*) url //文件的URL
{    u_int8_t b = 1;
    setxattr([[url path] fileSystemRepresentation], "com.apple.MobileBackup", &b, 1, 0, 0);
}

-(id)init{
    self=[super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        _diskCachePath = [paths[0] stringByAppendingPathComponent:@"MediaCache"];
        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
            if (![_fileManager fileExistsAtPath:_diskCachePath]) {
                [_fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
                NSURL * urlpath=[NSURL fileURLWithPath:_diskCachePath];
                [self addSkipBackupAttributeToFile:urlpath];
            }
        });
        self.cache=[NSCache new];
    }
    return self;
}

-(void)storeDataURL:(NSURL*)dataURL forKey:(NSURL*)url{
    [self.cache setObject:dataURL forKey:url];
}

-(NSURL*)store:(NSData*)data forKey:(NSURL*)url{
    if (!data) {
        return nil;
    }
    NSString * path=[self defaultCachePathForKey:url];
    dispatch_sync(self.ioQueue, ^{
        [_fileManager createFileAtPath:path contents:data attributes:nil];
    });
    NSURL * dataURL=[NSURL fileURLWithPath:path];
    [self.cache setObject:dataURL forKey:url];
    return dataURL;
}


-(NSURL*)dataURL:(NSURL*)key{
    return [self.cache objectForKey:key];
}


- (NSString *)cachePathForKey:(NSURL *)key inPath:(NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key.absoluteString];
    NSString * ext=key.pathExtension;
    return [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@",filename,ext]];
}

- (NSString *)defaultCachePathForKey:(NSURL*)key {
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
