/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import "SDWebImageDecoder.h"
#import "UIImage+MultiFormat.h"
#import <ImageIO/ImageIO.h>
#import "SDMediaDiskCache.h"


NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";

static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

@interface SDWebImageDownloader ()

@property (strong, nonatomic) NSOperationQueue *downloadQueue;
@property (weak, nonatomic) NSOperation *lastAddedOperation;
@property (strong, nonatomic) NSMutableDictionary *URLCallbacks;
@property (strong, nonatomic) NSMutableDictionary *HTTPHeaders;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t barrierQueue;

@end

@implementation SDWebImageDownloader

+ (void)initialize {
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator")) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (SDWebImageDownloader *)sharedDownloader {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (id)init {
    if ((self = [super init])) {
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;
        _downloadQueue = [NSOperationQueue new];
        _downloadQueue.maxConcurrentOperationCount = 2;
        _URLCallbacks = [NSMutableDictionary new];
        _HTTPHeaders = [NSMutableDictionary dictionaryWithObject:@"image/webp,image/*;q=0.8" forKey:@"Accept"];
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
        _downloadTimeout = 15.0;
    }
    return self;
}

- (void)dealloc {
    [self.downloadQueue cancelAllOperations];
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (value) {
        self.HTTPHeaders[field] = value;
    }
    else {
        [self.HTTPHeaders removeObjectForKey:field];
    }
}

- (NSString *)valueForHTTPHeaderField:(NSString *)field {
    return self.HTTPHeaders[field];
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads {
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSUInteger)currentDownloadCount {
    return _downloadQueue.operationCount;
}

- (NSInteger)maxConcurrentDownloads {
    return _downloadQueue.maxConcurrentOperationCount;
}

- (id <SDWebImageOperation>)downloadImageWithURL:(NSURL *)imageURL options:(SDWebImageDownloaderOptions)options progress:(void (^)(NSInteger, NSInteger))progressBlock completed:(void (^)(UIImage *, NSData *, NSError *, BOOL))completedBlock {
    __block SDWebImageDownloaderOperation *operation;
    __weak SDWebImageDownloader *wself = self;
    
    NSURL * url=imageURL;
    if (self.delegate && [self.delegate respondsToSelector:@selector(downloader:mediaURLforURL:)]) {
        url=[self.delegate downloader:self mediaURLforURL:imageURL];
    }

    [self addProgressCallback:progressBlock andCompletedBlock:completedBlock forURL:url createCallback:^{
        
        NSURL * dataURL=nil;
        if (wself.useDiskCache) {
            dataURL=[[SDMediaDiskCache sharedDiskCache] dataURL:url];
        }
        if (!dataURL&&wself.delegate&&[wself.delegate respondsToSelector:@selector(downloader:mediaDataURLforURL:)]) {
            dataURL=[wself.delegate downloader:wself mediaDataURLforURL:url];
        }
        if (dataURL) {
            if (wself.delegate&&[wself.delegate respondsToSelector:@selector(downloader:resonseError:dataURL:withURL:)]) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    [wself.delegate downloader:wself resonseError:nil dataURL:dataURL withURL:url];
                });
            }
            if (wself.delegate&&[wself.delegate respondsToSelector:@selector(downloader:generateImageByDataURL:forImageURL:success:)]) {
                [wself.delegate downloader:wself generateImageByDataURL:dataURL forImageURL:imageURL success:^(UIImage * image, NSError * error) {
                    dispatch_async(dispatch_get_global_queue(0, 0), ^{
                        [wself doComplete:url image:image data:nil error:error finished:YES];
                    });
                }];
            }else{
                NSData * data =[NSData dataWithContentsOfURL:dataURL];
                UIImage * image=[UIImage imageWithData:data];
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    [wself doComplete:url image:image  data:data error:nil finished:YES];
                });
                
            }
            return;
        }
        
        NSTimeInterval timeoutInterval = wself.downloadTimeout;
        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        NSMutableURLRequest *request = nil;
        if (wself.delegate && [wself.delegate respondsToSelector:@selector(downloader:requestForURL:)]) {
            request=[wself.delegate downloader:wself requestForURL:url];
        }else{
            request = [[NSMutableURLRequest alloc] initWithURL:url];
        }
        request.cachePolicy=(options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData);
        request.timeoutInterval=timeoutInterval;
        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        request.HTTPShouldUsePipelining = YES;
        if (wself.headersFilter) {
            request.allHTTPHeaderFields = wself.headersFilter(url, [wself.HTTPHeaders copy]);
        }
        else {
            request.allHTTPHeaderFields = wself.HTTPHeaders;
        }
        
        
        operation = [[SDWebImageDownloaderOperation alloc] initWithRequest:request
                                                                   options:options
                                                                  progress:^(NSInteger receivedSize, NSInteger expectedSize) {
                                                                      if (!wself) return;
                                                                      SDWebImageDownloader *sself = wself;
                                                                      NSArray *callbacksForURL = [sself callbacksForURL:url];
                                                                      for (NSDictionary *callbacks in callbacksForURL) {
                                                                          SDWebImageDownloaderProgressBlock callback = callbacks[kProgressCallbackKey];
                                                                          if (callback) callback(receivedSize, expectedSize);
                                                                      }
                                                                  }
                                                                 completed:^(UIImage *image, NSData *data, NSError *error, BOOL finished) {
                                                                     if (!wself) return;
                                                                     SDWebImageDownloader *sself = wself;

                                                                     if (finished) {
                                                                         if (error) {
                                                                             if (sself.delegate&&[sself.delegate respondsToSelector:@selector(downloader:resonseError:dataURL:withURL:)]) {
                                                                                 [sself.delegate downloader:sself resonseError:error dataURL:nil withURL:url];
                                                                             }
                                                                             [sself doComplete:url image:nil data:nil error:error finished:YES];

                                                                         }else{
                                                                             
                                                                             if (sself.delegate&&[sself.delegate respondsToSelector:@selector(downloader:transformResponseData:withURL:)]) {
                                                                                 data=[sself.delegate downloader:sself transformResponseData:data withURL:url];
                                                                                 if (!data) {
                                                                                     
                                                                                 }
                                                                             }
                                                                             NSURL * dURL=nil;
                                                                             if(sself.useDiskCache){
                                                                                 dURL=[[SDMediaDiskCache sharedDiskCache] store:data forKey:url];
                                                                                 if (sself.delegate&&[sself.delegate respondsToSelector:@selector(downloader:resonseError:dataURL:withURL:)]) {
                                                                                     [sself.delegate downloader:sself resonseError:nil dataURL:dURL withURL:url];
                                                                                 }
                                                                             }
                                                                             if (sself.delegate&&[sself.delegate respondsToSelector:@selector(downloader:generateImageByDataURL:forImageURL:success:)]) {
                                                                                 
                                                                                 [sself.delegate downloader:sself generateImageByDataURL:dURL  forImageURL:imageURL success:^(UIImage * img, NSError * err) {
                                                                                     [sself doComplete:url image:img data:nil error:nil finished:YES];

                                                                                 }];
                                                                             }else{
                                                                                 UIImage *img = [UIImage sd_imageWithData:data];
                                                                                 img =  SDScaledImageForKey(url.absoluteString, img);
                                                                                 
                                                                                 if (!img.images) // Do not force decod animated GIFs
                                                                                 {
                                                                                     img = [UIImage decodedImageWithImage:img];
                                                                                 }
                                                                                 
                                                                                 if (CGSizeEqualToSize(img.size, CGSizeZero)) {
                                                                                     error=[NSError errorWithDomain:@"SDWebImageErrorDomain" code:0 userInfo:@{NSLocalizedDescriptionKey : @"Downloaded image has 0 pixels"}];
                                                                                 }

                                                                                 [sself doComplete:url image:img data:data error:error finished:YES];

                                                                             }

                                                                         }

                                                                     }else{
                                                                         [sself doComplete:url image:image data:data error:error finished:NO];
                                                                     }
                                                                 }
                                                                 cancelled:^{
                                                                     if (!wself) return;
                                                                     SDWebImageDownloader *sself = wself;
                                                                     [sself removeCallbacksForURL:url];
                                                                 }];
        
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        }

        [wself.downloadQueue addOperation:operation];
        if (wself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            [wself.lastAddedOperation addDependency:operation];
            wself.lastAddedOperation = operation;
        }
    }];

    return operation;
}

-(void)doComplete:(NSURL*)url image:(UIImage*)image data:(NSData*)data error:(NSError*)error finished:(BOOL)finished{
    NSArray *callbacksForURL = [self callbacksForURL:url];
    if (finished)
    {
        [self removeCallbacksForURL:url];
    }
    for (NSDictionary *callbacks in callbacksForURL)
    {
        SDWebImageDownloaderCompletedBlock callback = callbacks[kCompletedCallbackKey];
        if (callback) callback(image, data, error, finished);
    }
    
    
}

- (void)addProgressCallback:(void (^)(NSInteger, NSInteger))progressBlock andCompletedBlock:(void (^)(UIImage *, NSData *data, NSError *, BOOL))completedBlock forURL:(NSURL *)url createCallback:(void (^)())createCallback {
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }
        return;
    }

    dispatch_barrier_sync(self.barrierQueue, ^{
        BOOL first = NO;
        if (!self.URLCallbacks[url]) {
            self.URLCallbacks[url] = [NSMutableArray new];
            first = YES;
        }

        // Handle single download of simultaneous download request for the same URL
        NSMutableArray *callbacksForURL = self.URLCallbacks[url];
        NSMutableDictionary *callbacks = [NSMutableDictionary new];
        if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
        if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
        [callbacksForURL addObject:callbacks];
        self.URLCallbacks[url] = callbacksForURL;

        if (first) {
            createCallback();
        }
    });
}

- (NSArray *)callbacksForURL:(NSURL *)url {
    __block NSArray *callbacksForURL;
    dispatch_sync(self.barrierQueue, ^{
        callbacksForURL = self.URLCallbacks[url];
    });
    return [callbacksForURL copy];
}

- (void)removeCallbacksForURL:(NSURL *)url {
    dispatch_barrier_async(self.barrierQueue, ^{
        [self.URLCallbacks removeObjectForKey:url];
    });
}

@end
