#import "HeyJoeVideoCapturer.h"
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>
#import <VideoToolbox/VideoToolbox.h>
#import <UIKit/UIKit.h>

static HeyJoeVideoCapturer *_sharedInstance = nil;

// Queue-specific keys for detecting current queue in dealloc
static void *kCaptureQueueSpecificKey = &kCaptureQueueSpecificKey;
static void *kRecordingQueueSpecificKey = &kRecordingQueueSpecificKey;

// Forward declaration for compression callback
static void compressionOutputCallback(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer);

#pragma mark - HJCompressionCallbackContext

@implementation HJCompressionCallbackContext
@end

#pragma mark - HeyJoeVideoCapturer Private Interface

@interface HeyJoeVideoCapturer () <AVCaptureAudioDataOutputSampleBufferDelegate>

// captureQueue owns these
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioDataOutput;

// recordingQueue owns these
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInput *audioWriterInput;
@property (nonatomic) VTCompressionSessionRef compressionSession;
@property (nonatomic, strong) NSURL *recordingURL;
@property (nonatomic, assign) BOOL hasWrittenFirstVideoFrame;
@property (nonatomic, assign) CMTime recordingStartTime;
@property (nonatomic, assign) BOOL needsCompressionSetup;
@property (nonatomic, assign) BOOL audioWriterInputAdded;
@property (nonatomic, strong, nullable) NSError *recordingSetupError;
@property (nonatomic, assign) int encodedFrameCount;
@property (nonatomic, assign) int compressedCallbackCount;
@property (nonatomic, strong, nullable) HJCompressionCallbackContext *callbackContext;

// Queues
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) dispatch_queue_t recordingQueue;
@property (nonatomic, strong) dispatch_queue_t videoOutputQueue;
@property (nonatomic, strong) dispatch_queue_t audioOutputQueue;

// Atomic properties (redeclared readwrite internally)
@property (atomic, assign) BOOL recordingActive;
@property (atomic, assign) BOOL isCapturing;
@property (atomic, assign) int videoWidth;
@property (atomic, assign) int videoHeight;

// Recording state (readwrite internally, only on recordingQueue)
@property (nonatomic, assign) HJRecordingState recordingState;

// Generation counter for capture sessions — incremented on every startCapture.
// _teardownCaptureSession checks this to avoid destroying a newer session.
@property (nonatomic, assign) NSUInteger captureGeneration;

// Completion handler for pending stop recording
@property (nonatomic, copy, nullable) void (^recordingCompletionHandler)(NSURL * _Nullable, NSError * _Nullable);

// Cached device orientation — updated via notification instead of per-frame dispatch_sync
@property (nonatomic, assign) UIDeviceOrientation cachedDeviceOrientation;

@end

@implementation HeyJoeVideoCapturer

#pragma mark - Shared Instance

+ (instancetype)sharedInstance {
    return _sharedInstance;
}

+ (void)setSharedInstance:(HeyJoeVideoCapturer *)instance {
    _sharedInstance = instance;
}

#pragma mark - Initialization

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate {
    self = [super initWithDelegate:delegate];
    if (self) {
        _captureQueue = dispatch_queue_create("com.heyjoe.capturer.capture", DISPATCH_QUEUE_SERIAL);
        _recordingQueue = dispatch_queue_create("com.heyjoe.capturer.recording", DISPATCH_QUEUE_SERIAL);
        _videoOutputQueue = dispatch_queue_create("com.heyjoe.capturer.videoOutput", DISPATCH_QUEUE_SERIAL);
        _audioOutputQueue = dispatch_queue_create("com.heyjoe.capturer.audioOutput", DISPATCH_QUEUE_SERIAL);

        // Set queue-specific keys so dealloc can detect if it's already on the target queue
        dispatch_queue_set_specific(_captureQueue, kCaptureQueueSpecificKey, kCaptureQueueSpecificKey, NULL);
        dispatch_queue_set_specific(_recordingQueue, kRecordingQueueSpecificKey, kRecordingQueueSpecificKey, NULL);

        _recordingState = HJRecordingStateIdle;
        _recordingActive = NO;
        _isCapturing = NO;
        _needsCompressionSetup = NO;
        _videoWidth = 1280;
        _videoHeight = 720;
        _hasWrittenFirstVideoFrame = NO;
        _recordingStartTime = kCMTimeInvalid;
        _recordingTargetResolution = HeyJoeRecordingResolution1080p;
        _encodedFrameCount = 0;
        _compressedCallbackCount = 0;

        // Cache device orientation — avoids dispatch_sync to main queue at 30fps
        _cachedDeviceOrientation = UIDeviceOrientationPortrait;
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deviceOrientationDidChange:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];

        // Stop recording gracefully on memory pressure
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        // Set as shared instance
        [HeyJoeVideoCapturer setSharedInstance:self];

        NSLog(@"[HeyJoeCapturer] Initialized with 4-queue architecture (captureQueue + recordingQueue + videoOutput + audioOutput)");
    }
    return self;
}

- (void)updateDelegate:(id<RTCVideoCapturerDelegate>)delegate {
    if (self.isCapturing) {
        NSLog(@"WARNING: updateDelegate called while still capturing — call stopCapture first");
    }
    // RTCVideoCapturer stores the delegate as a weak reference — thread-safe assignment
    self.delegate = delegate;
    NSLog(@"[HeyJoeCapturer] Delegate updated for new WebRTC session");
}

- (void)dealloc {
    // Invalidate callback context immediately to stop VT callbacks from reaching us
    self.callbackContext.invalidated = YES;

    // Capture session teardown — use queue-specific key to avoid deadlock if last
    // retain was released from within captureQueue itself
    void (^captureCleanup)(void) = ^{
        if (self.captureSession && self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
    };
    if (dispatch_get_specific(kCaptureQueueSpecificKey)) {
        captureCleanup();
    } else if (self.captureQueue) {
        dispatch_sync(self.captureQueue, captureCleanup);
    }

    // Recording teardown — same pattern
    void (^recordingCleanup)(void) = ^{
        self.recordingActive = NO;
        self.recordingState = HJRecordingStateIdle;
        if (self.compressionSession) {
            VTCompressionSessionInvalidate(self.compressionSession);
            CFRelease(self.compressionSession);
            self.compressionSession = NULL;
            // Release the CFBridgingRetain'd context ref
            if (self.callbackContext) {
                CFRelease((__bridge CFTypeRef)self.callbackContext);
                self.callbackContext = nil;
            }
        }
        if (self.assetWriter) {
            [self.assetWriter cancelWriting];
        }
    };
    if (dispatch_get_specific(kRecordingQueueSpecificKey)) {
        recordingCleanup();
    } else if (self.recordingQueue) {
        dispatch_sync(self.recordingQueue, recordingCleanup);
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];

    if (_sharedInstance == self) {
        _sharedInstance = nil;
    }
    NSLog(@"[HeyJoeCapturer] Deallocated");
}

#pragma mark - Orientation Handling

- (void)deviceOrientationDidChange:(NSNotification *)notification {
    self.cachedDeviceOrientation = [UIDevice currentDevice].orientation;
}

- (void)handleMemoryWarning:(NSNotification *)notification {
    NSLog(@"[HeyJoeCapturer] MEMORY WARNING received");
    if (self.recordingActive) {
        NSLog(@"[HeyJoeCapturer] Stopping recording due to memory pressure");
        dispatch_async(self.recordingQueue, ^{
            if (self.recordingState == HJRecordingStateRecording) {
                [self _failRecordingWithError:[NSError errorWithDomain:@"HeyJoeCapturer" code:20
                    userInfo:@{NSLocalizedDescriptionKey: @"Recording stopped due to low memory"}]];
            }
        });
    }
}

- (UIDeviceOrientation)currentDeviceOrientation {
    return self.cachedDeviceOrientation;
}

- (RTCVideoRotation)rtcVideoRotationForCurrentDeviceOrientation {
    UIDeviceOrientation deviceOrientation = [self currentDeviceOrientation];

    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            return RTCVideoRotation_0;
        case UIDeviceOrientationPortraitUpsideDown:
            return RTCVideoRotation_180;
        case UIDeviceOrientationLandscapeLeft:
            return RTCVideoRotation_270;
        case UIDeviceOrientationLandscapeRight:
            return RTCVideoRotation_90;
        default:
            return RTCVideoRotation_0;
    }
}

- (CGAffineTransform)videoTransformForCurrentDeviceOrientation {
    UIDeviceOrientation deviceOrientation = [self currentDeviceOrientation];

    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            return CGAffineTransformIdentity;
        case UIDeviceOrientationPortraitUpsideDown:
            return CGAffineTransformMakeRotation(M_PI);
        case UIDeviceOrientationLandscapeLeft:
            return CGAffineTransformMakeRotation(-M_PI_2);
        case UIDeviceOrientationLandscapeRight:
            return CGAffineTransformMakeRotation(M_PI_2);
        default:
            return CGAffineTransformIdentity;
    }
}

#pragma mark - Capture Control

- (void)startCaptureWithDevice:(AVCaptureDevice *)device
                        format:(AVCaptureDeviceFormat *)format
                           fps:(NSInteger)fps
             completionHandler:(void (^)(NSError *))completionHandler {

    dispatch_async(self.captureQueue, ^{
        if (self.isCapturing) {
            NSLog(@"[HeyJoeCapturer] Already capturing, ignoring start request");
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil);
                });
            }
            return;
        }

        // Increment generation so any in-flight teardown from a previous stop
        // won't destroy this new session
        self.captureGeneration++;

        NSError *error = nil;

        // Create capture session
        self.captureSession = [[AVCaptureSession alloc] init];
        [self.captureSession beginConfiguration];

        // Add video input
        self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (error || !self.videoInput) {
            [self.captureSession commitConfiguration];
            NSLog(@"[HeyJoeCapturer] Failed to create video input: %@", error);
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(error ?: [NSError errorWithDomain:@"HeyJoeCapturer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create video input"}]);
                });
            }
            return;
        }

        if ([self.captureSession canAddInput:self.videoInput]) {
            [self.captureSession addInput:self.videoInput];
        } else {
            [self.captureSession commitConfiguration];
            NSLog(@"[HeyJoeCapturer] Cannot add video input to session");
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler([NSError errorWithDomain:@"HeyJoeCapturer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add video input"}]);
                });
            }
            return;
        }

        // Configure camera format and frame rate
        if ([device lockForConfiguration:&error]) {
            device.activeFormat = format;

            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            self.videoWidth = dims.width;
            self.videoHeight = dims.height;

            CMTime frameDuration = CMTimeMake(1, (int32_t)fps);
            device.activeVideoMinFrameDuration = frameDuration;
            device.activeVideoMaxFrameDuration = frameDuration;

            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            }
            if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            }

            [device unlockForConfiguration];
            NSLog(@"[HeyJoeCapturer] Camera configured: %dx%d @ %ldfps", self.videoWidth, self.videoHeight, (long)fps);
        } else {
            NSLog(@"[HeyJoeCapturer] Could not lock camera for configuration: %@", error);
        }

        // Add audio input for recording
        AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (audioDevice) {
            NSError *audioError = nil;
            self.audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioError];
            if (self.audioInput && [self.captureSession canAddInput:self.audioInput]) {
                [self.captureSession addInput:self.audioInput];
                NSLog(@"[HeyJoeCapturer] Audio input added");
            }
        }

        // Add video data output — delivered on videoOutputQueue
        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoDataOutput.alwaysDiscardsLateVideoFrames = YES;
        self.videoDataOutput.videoSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        };
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoOutputQueue];

        if ([self.captureSession canAddOutput:self.videoDataOutput]) {
            [self.captureSession addOutput:self.videoDataOutput];

            AVCaptureConnection *videoConnection = [self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
            if (videoConnection) {
                if ([videoConnection isVideoOrientationSupported]) {
                    videoConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
                if (device.position == AVCaptureDevicePositionFront && [videoConnection isVideoMirroringSupported]) {
                    videoConnection.videoMirrored = YES;
                }
            }
        } else {
            NSLog(@"[HeyJoeCapturer] Cannot add video data output");
        }

        // Add audio data output — delivered on audioOutputQueue
        self.audioDataOutput = [[AVCaptureAudioDataOutput alloc] init];
        [self.audioDataOutput setSampleBufferDelegate:self queue:self.audioOutputQueue];

        if ([self.captureSession canAddOutput:self.audioDataOutput]) {
            [self.captureSession addOutput:self.audioDataOutput];
            NSLog(@"[HeyJoeCapturer] Audio data output added for recording");
        } else {
            NSLog(@"[HeyJoeCapturer] Cannot add audio data output");
        }

        [self.captureSession commitConfiguration];

        // Start the session
        [self.captureSession startRunning];
        self.isCapturing = YES;

        NSLog(@"[HeyJoeCapturer] Capture session started at %dx%d", self.videoWidth, self.videoHeight);

        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil);
            });
        }
    });
}

- (void)stopCaptureWithCompletionHandler:(void (^)(void))completionHandler {
    dispatch_async(self.captureQueue, ^{
        if (!self.isCapturing) {
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler();
                });
            }
            return;
        }

        // Set isCapturing to NO immediately — callback queues will early-return
        self.isCapturing = NO;

        // Capture the current generation so the deferred teardown won't destroy
        // a session that was created by a subsequent startCapture call
        NSUInteger generationAtStop = self.captureGeneration;

        // Always dispatch to recordingQueue to check if ANY recording work is pending.
        // We can't rely solely on recordingActive because it's NO during Starting state
        // (before the first frame sets up compression). recordingState is queue-confined
        // to recordingQueue, so we must check it there.
        dispatch_async(self.recordingQueue, ^{
            if (self.recordingState != HJRecordingStateIdle) {
                // Recording in some state — stop it first, then stop capture in completion
                NSLog(@"[HeyJoeCapturer] Recording state=%ld during capture stop — stopping recording first",
                      (long)self.recordingState);
                [self _stopRecordingInternalWithCompletionHandler:^(NSURL *url, NSError *error) {
                    // Recording stopped, now notify JS of interruption and stop capture
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"HeyJoeRecordingInterruptedDuringCaptureStop"
                            object:nil];
                    });

                    // Now stop the capture session on captureQueue
                    dispatch_async(self.captureQueue, ^{
                        [self _teardownCaptureSessionForGeneration:generationAtStop];
                        if (completionHandler) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                completionHandler();
                            });
                        }
                    });
                }];
            } else {
                // No recording — just tear down capture on captureQueue
                dispatch_async(self.captureQueue, ^{
                    [self _teardownCaptureSessionForGeneration:generationAtStop];
                    if (completionHandler) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completionHandler();
                        });
                    }
                });
            }
        });
    });
}

/// Must be called on captureQueue.
/// Checks generation counter to avoid destroying a session created by a newer startCapture.
- (void)_teardownCaptureSessionForGeneration:(NSUInteger)generation {
    if (generation != self.captureGeneration) {
        NSLog(@"[HeyJoeCapturer] Skipping stale teardown (gen %lu vs current %lu) — a new session was started",
              (unsigned long)generation, (unsigned long)self.captureGeneration);
        return;
    }
    if (self.captureSession && self.captureSession.isRunning) {
        [self.captureSession stopRunning];
    }
    self.captureSession = nil;
    self.videoInput = nil;
    self.audioInput = nil;
    self.videoDataOutput = nil;
    self.audioDataOutput = nil;
    NSLog(@"[HeyJoeCapturer] Capture session stopped and torn down (gen %lu)", (unsigned long)generation);
}

#pragma mark - Recording Control

- (BOOL)_setupCompressionSessionWithWidth:(int)width height:(int)height bitrate:(int)bitrate {
    // Must be called on recordingQueue

    if (@available(iOS 11.0, *)) {
        // iOS 11+ — use HEVC
    } else {
        NSLog(@"[HeyJoeCapturer] HEVC encoding requires iOS 11.0 or later");
        return NO;
    }

    // Create callback context with ref-counted safety
    HJCompressionCallbackContext *ctx = [[HJCompressionCallbackContext alloc] init];
    ctx.capturer = self;  // weak
    ctx.recordingQueue = self.recordingQueue;
    ctx.invalidated = NO;
    self.callbackContext = ctx;

    // CFBridgingRetain: gives VT a +1 strong reference to the context object.
    // This ensures the context stays alive even if self.callbackContext is nilled.
    // We balance this with CFRelease when invalidating the compression session.
    void *refCon = (void *)CFBridgingRetain(ctx);
    OSStatus vtStatus = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCMVideoCodecType_HEVC,
        NULL,
        NULL,
        NULL,
        compressionOutputCallback,
        refCon,
        &_compressionSession
    );

    if (vtStatus != noErr) {
        NSLog(@"[HeyJoeCapturer] Failed to create compression session: %d", (int)vtStatus);
        // Release the CFBridgingRetain'd ref since VT didn't take ownership
        CFRelease(refCon);
        self.callbackContext = nil;
        return NO;
    }

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)@(bitrate));

    NSArray *dataRateLimits = @[@(bitrate * 1.5), @1.0];
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_DataRateLimits,
                         (__bridge CFArrayRef)dataRateLimits);

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFNumberRef)@(30));

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFNumberRef)@(60));

    if (@available(iOS 11.0, *)) {
        VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel,
                             kVTProfileLevel_HEVC_Main_AutoLevel);
    }

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanTrue);

    VTCompressionSessionPrepareToEncodeFrames(_compressionSession);

    NSLog(@"[HeyJoeCapturer] Compression session created: %dx%d @ %d Mbps H.265", width, height, bitrate / 1000000);
    return YES;
}

- (BOOL)_setupAssetWriterWithSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Must be called on recordingQueue

    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDesc) {
        NSLog(@"[HeyJoeCapturer] Failed to get format description from sample buffer");
        return NO;
    }

    NSError *error = nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:self.recordingURL.path]) {
        NSLog(@"[HeyJoeCapturer] WARNING: File already exists at recording URL during deferred setup - deleting");
        [fm removeItemAtURL:self.recordingURL error:nil];
    }

    self.assetWriter = [[AVAssetWriter alloc] initWithURL:self.recordingURL
                                                 fileType:AVFileTypeMPEG4
                                                    error:&error];
    if (error) {
        NSLog(@"[HeyJoeCapturer] Failed to create asset writer: %@", error);
        return NO;
    }

    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                               outputSettings:nil
                                                             sourceFormatHint:formatDesc];
    self.videoWriterInput.expectsMediaDataInRealTime = YES;

    CGAffineTransform videoTransform = [self videoTransformForCurrentDeviceOrientation];
    self.videoWriterInput.transform = videoTransform;
    NSLog(@"[HeyJoeCapturer] Video writer transform set for device orientation");

    AudioChannelLayout acl;
    memset(&acl, 0, sizeof(acl));
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;

    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(44100),
        AVNumberOfChannelsKey: @(1),
        AVEncoderBitRateKey: @(128000),
        AVChannelLayoutKey: [NSData dataWithBytes:&acl length:sizeof(acl)]
    };

    self.audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                               outputSettings:audioSettings];
    self.audioWriterInput.expectsMediaDataInRealTime = YES;

    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    } else {
        NSLog(@"[HeyJoeCapturer] Cannot add video writer input - canAddInput returned NO");
        NSLog(@"[HeyJoeCapturer] Asset writer error: %@", self.assetWriter.error);
        return NO;
    }

    if ([self.assetWriter canAddInput:self.audioWriterInput]) {
        [self.assetWriter addInput:self.audioWriterInput];
        self.audioWriterInputAdded = YES;
    } else {
        NSLog(@"[HeyJoeCapturer] Cannot add audio writer input — continuing without audio");
        self.audioWriterInputAdded = NO;
    }

    NSLog(@"[HeyJoeCapturer] Asset writer created with format hint for: %@", self.recordingURL.path);
    return YES;
}

/// Must be called on recordingQueue. Handles a compressed frame from VT callback.
- (void)_handleCompressedFrame:(CMSampleBufferRef)sampleBuffer {
    // Only append frames in Recording state.
    // Draining/Finalizing/Idle frames are silently dropped — they arrive after
    // markAsFinished has been called, so appending would crash the writer.
    if (self.recordingState != HJRecordingStateRecording) {
        CFRelease(sampleBuffer);
        return;
    }

    // Guard against stale callbacks
    if (!self.compressionSession) {
        NSLog(@"[HeyJoeCapturer] Ignoring compressed frame — no active compression session");
        CFRelease(sampleBuffer);
        return;
    }

    // Deferred asset writer setup on first compressed frame
    if (!self.assetWriter) {
        NSLog(@"[HeyJoeCapturer] Performing deferred asset writer setup...");
        if (![self _setupAssetWriterWithSampleBuffer:sampleBuffer]) {
            NSLog(@"[HeyJoeCapturer] Deferred asset writer setup failed — stopping recording");
            CFRelease(sampleBuffer);
            [self _failRecordingWithError:[NSError errorWithDomain:@"HeyJoeCapturer" code:12
                userInfo:@{NSLocalizedDescriptionKey: @"Asset writer setup failed"}]];
            return;
        }
        NSLog(@"[HeyJoeCapturer] Deferred asset writer setup completed successfully");
    }

    // Start writing if not yet started
    if (self.assetWriter.status == AVAssetWriterStatusUnknown) {
        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if ([self.assetWriter startWriting]) {
            [self.assetWriter startSessionAtSourceTime:timestamp];
            self.recordingStartTime = timestamp;
            NSLog(@"[HeyJoeCapturer] Asset writer started at time: %.3f", CMTimeGetSeconds(timestamp));
        } else {
            NSError *writerErr = self.assetWriter.error;
            NSLog(@"[HeyJoeCapturer] CRITICAL: startWriting failed — status=%ld, error=%@, URL=%@",
                  (long)self.assetWriter.status, writerErr, self.recordingURL);
            CFRelease(sampleBuffer);
            [self _failRecordingWithError:writerErr ?: [NSError errorWithDomain:@"HeyJoeCapturer" code:10
                userInfo:@{NSLocalizedDescriptionKey: @"Asset writer startWriting failed"}]];
            return;
        }
    }

    // Append video frame
    if (self.assetWriter.status == AVAssetWriterStatusWriting) {
        if (self.videoWriterInput.readyForMoreMediaData) {
            if ([self.videoWriterInput appendSampleBuffer:sampleBuffer]) {
                self.hasWrittenFirstVideoFrame = YES;
            } else {
                NSError *appendErr = self.assetWriter.error;
                NSLog(@"[HeyJoeCapturer] CRITICAL: Failed to append video sample — status=%ld, error=%@",
                      (long)self.assetWriter.status, appendErr);
                if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                    CFRelease(sampleBuffer);
                    [self _failRecordingWithError:appendErr];
                    return;
                }
            }
        }
    } else if (self.assetWriter.status == AVAssetWriterStatusFailed) {
        NSLog(@"[HeyJoeCapturer] Asset writer in failed state: %@", self.assetWriter.error);
        NSError *err = self.assetWriter.error;
        CFRelease(sampleBuffer);
        [self _failRecordingWithError:err];
        return;
    }

    CFRelease(sampleBuffer);
}

/// Must be called on recordingQueue. Handles audio sample from audioOutputQueue.
- (void)_handleAudioSample:(CMSampleBufferRef)sampleBuffer {
    if (self.recordingState != HJRecordingStateRecording) {
        CFRelease(sampleBuffer);
        return;
    }

    if (!self.hasWrittenFirstVideoFrame) {
        // Don't write audio before the first video frame
        CFRelease(sampleBuffer);
        return;
    }

    if (self.assetWriter.status == AVAssetWriterStatusWriting &&
        self.audioWriterInput.readyForMoreMediaData) {
        if (![self.audioWriterInput appendSampleBuffer:sampleBuffer]) {
            NSError *audioErr = self.assetWriter.error;
            NSLog(@"[HeyJoeCapturer] Failed to append audio sample — status=%ld, error=%@",
                  (long)self.assetWriter.status, audioErr);
            if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                CFRelease(sampleBuffer);
                [self _failRecordingWithError:audioErr];
                return;
            }
        }
    }

    CFRelease(sampleBuffer);
}

/// Central error handler — must be called on recordingQueue.
/// All error paths funnel through here.
- (void)_failRecordingWithError:(NSError *)error {
    NSLog(@"[HeyJoeCapturer] _failRecordingWithError: %@", error);

    self.recordingActive = NO;
    self.recordingState = HJRecordingStateIdle;

    // Invalidate callback context to stop any in-flight VT callbacks
    self.callbackContext.invalidated = YES;

    // Tear down compression session + release the CFBridgingRetain'd context ref
    if (self.compressionSession) {
        VTCompressionSessionInvalidate(self.compressionSession);
        CFRelease(self.compressionSession);
        self.compressionSession = NULL;
    }
    if (self.callbackContext) {
        CFRelease((__bridge CFTypeRef)self.callbackContext);
        self.callbackContext = nil;
    }

    // Cancel asset writer
    if (self.assetWriter) {
        [self.assetWriter cancelWriting];
    }

    // Clean up all recording state
    self.assetWriter = nil;
    self.videoWriterInput = nil;
    self.audioWriterInput = nil;
    self.recordingURL = nil;
    self.needsCompressionSetup = NO;
    self.hasWrittenFirstVideoFrame = NO;
    self.recordingStartTime = kCMTimeInvalid;
    self.recordingSetupError = nil;

    // Call pending completion handler if any
    void (^pendingCompletion)(NSURL *, NSError *) = self.recordingCompletionHandler;
    self.recordingCompletionHandler = nil;
    if (pendingCompletion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            pendingCompletion(nil, error);
        });
    }

    // Notify JS
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"HeyJoeRecordingFailedMidStream"
            object:nil
            userInfo:error ? @{@"error": error.localizedDescription ?: @"Unknown error"} : nil];
    });
}

- (void)startRecordingToURL:(NSURL *)outputURL
          completionHandler:(void (^)(NSError *))completionHandler {

    dispatch_async(self.recordingQueue, ^{
        if (!self.isCapturing) {
            NSLog(@"[HeyJoeCapturer] Cannot start recording — not capturing");
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler([NSError errorWithDomain:@"HeyJoeCapturer" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Not capturing"}]);
                });
            }
            return;
        }

        if (self.recordingState != HJRecordingStateIdle) {
            NSLog(@"[HeyJoeCapturer] Already recording (state=%ld)", (long)self.recordingState);
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler([NSError errorWithDomain:@"HeyJoeCapturer" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Already recording"}]);
                });
            }
            return;
        }

        // Pre-recording cleanup: force-clean any stale resources
        if (self.compressionSession) {
            NSLog(@"[HeyJoeCapturer] Cleaning up stale compression session before new recording");
            self.callbackContext.invalidated = YES;
            VTCompressionSessionInvalidate(self.compressionSession);
            CFRelease(self.compressionSession);
            self.compressionSession = NULL;
            // Release the CFBridgingRetain'd context ref
            if (self.callbackContext) {
                CFRelease((__bridge CFTypeRef)self.callbackContext);
                self.callbackContext = nil;
            }
        }
        if (self.assetWriter) {
            NSLog(@"[HeyJoeCapturer] Cleaning up stale asset writer before new recording (status=%ld)",
                  (long)self.assetWriter.status);
            [self.assetWriter cancelWriting];
            self.assetWriter = nil;
            self.videoWriterInput = nil;
            self.audioWriterInput = nil;
        }

        // Delete existing file if present
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:outputURL.path]) {
            [fileManager removeItemAtURL:outputURL error:nil];
        }

        self.recordingURL = outputURL;
        self.hasWrittenFirstVideoFrame = NO;
        self.recordingStartTime = kCMTimeInvalid;
        self.recordingSetupError = nil;
        self.encodedFrameCount = 0;
        self.compressedCallbackCount = 0;
        self.needsCompressionSetup = YES;
        self.recordingCompletionHandler = nil;

        // Transition: Idle → Starting
        self.recordingState = HJRecordingStateStarting;
        // recordingActive stays NO until we actually transition to Recording
        // (after compression session is set up on first frame dispatch)

        NSLog(@"[HeyJoeCapturer] Recording started (target: %s) to: %@ (compression setup deferred)",
              self.recordingTargetResolution == HeyJoeRecordingResolution4K ? "4K" : "1080p",
              outputURL.path);

        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil);
            });
        }
    });
}

- (void)stopRecordingWithCompletionHandler:(void (^)(NSURL *, NSError *))completionHandler {
    dispatch_async(self.recordingQueue, ^{
        [self _stopRecordingInternalWithCompletionHandler:completionHandler];
    });
}

/// Must be called on recordingQueue.
- (void)_stopRecordingInternalWithCompletionHandler:(void (^)(NSURL *, NSError *))completionHandler {
    // Check for deferred errors
    if (self.recordingState == HJRecordingStateIdle && self.recordingSetupError) {
        NSError *setupErr = self.recordingSetupError;
        self.recordingSetupError = nil;
        NSLog(@"[HeyJoeCapturer] Reporting deferred recording setup error: %@", setupErr);
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, setupErr);
            });
        }
        return;
    }

    if (self.recordingState == HJRecordingStateIdle) {
        NSLog(@"[HeyJoeCapturer] Not recording, nothing to stop");
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, [NSError errorWithDomain:@"HeyJoeCapturer" code:7 userInfo:@{NSLocalizedDescriptionKey: @"Not recording"}]);
            });
        }
        return;
    }

    // Handle case where we're still in Starting state (no frames processed yet)
    if (self.recordingState == HJRecordingStateStarting) {
        NSLog(@"[HeyJoeCapturer] Recording stopped before any frames were processed");
        self.recordingActive = NO;
        self.recordingState = HJRecordingStateIdle;
        self.callbackContext.invalidated = YES;
        self.callbackContext = nil;
        self.needsCompressionSetup = NO;
        self.recordingURL = nil;
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil);
            });
        }
        return;
    }

    NSURL *outputURL = self.recordingURL;

    NSLog(@"[HeyJoeCapturer] Stopping recording — state: %ld, assetWriter=%@, compressionSession=%@",
          (long)self.recordingState,
          self.assetWriter ? @"exists" : @"nil",
          self.compressionSession ? @"exists" : @"nil");

    // Step 1: Stop accepting new frames
    self.recordingActive = NO;
    self.recordingState = HJRecordingStateDraining;
    NSLog(@"[HeyJoeCapturer] recordingActive=NO, state=Draining — no more frames will be dispatched");

    // Step 2: Flush compression session on global queue with timeout
    if (self.compressionSession) {
        NSLog(@"[HeyJoeCapturer] Flushing compression session...");
        VTCompressionSessionRef sessionToFlush = self.compressionSession;
        dispatch_semaphore_t flushSem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            VTCompressionSessionCompleteFrames(sessionToFlush, kCMTimeInvalid);
            dispatch_semaphore_signal(flushSem);
        });
        // Wait up to 3 seconds — any remaining VT callbacks will dispatch_async
        // back to this (recording) queue, so they'll be processed after this method returns
        long flushResult = dispatch_semaphore_wait(flushSem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        if (flushResult != 0) {
            NSLog(@"[HeyJoeCapturer] WARNING: Compression flush timed out after 3s");
        } else {
            NSLog(@"[HeyJoeCapturer] Compression session flushed");
        }
    }

    // Step 3: Invalidate callback context + compression session
    self.callbackContext.invalidated = YES;
    if (self.compressionSession) {
        VTCompressionSessionInvalidate(self.compressionSession);
        CFRelease(self.compressionSession);
        self.compressionSession = NULL;
    }
    // Release the CFBridgingRetain'd context ref
    if (self.callbackContext) {
        CFRelease((__bridge CFTypeRef)self.callbackContext);
        self.callbackContext = nil;
    }

    // Step 4: Finalize asset writer
    self.recordingState = HJRecordingStateFinalizing;

    if (!self.assetWriter || self.assetWriter.status != AVAssetWriterStatusWriting) {
        // No writer or not in writing state
        NSError *writerError = self.assetWriter.error;
        AVAssetWriterStatus writerStatus = self.assetWriter ? self.assetWriter.status : -1;

        if (!self.assetWriter || writerStatus == AVAssetWriterStatusUnknown) {
            NSLog(@"[HeyJoeCapturer] No frames were written — recording too short");
            [self _cleanupRecordingState];
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil, nil);
                });
            }
        } else if (writerStatus == AVAssetWriterStatusCompleted) {
            NSLog(@"[HeyJoeCapturer] Asset writer already completed");
            [self _cleanupRecordingState];
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(outputURL, nil);
                });
            }
        } else {
            NSLog(@"[HeyJoeCapturer] Asset writer in unexpected state: %ld, error=%@",
                  (long)writerStatus, writerError);
            [self _cleanupRecordingState];
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (writerError) {
                        completionHandler(nil, writerError);
                    } else {
                        NSString *desc = [NSString stringWithFormat:
                            @"Recording failed — writer in state %ld (0=Unknown,3=Failed,4=Cancelled)",
                            (long)writerStatus];
                        completionHandler(nil, [NSError errorWithDomain:@"HeyJoeCapturer" code:8 userInfo:@{NSLocalizedDescriptionKey: desc}]);
                    }
                });
            }
        }
        return;
    }

    // Writer is in Writing state — finalize properly
    NSLog(@"[HeyJoeCapturer] Finishing asset writer...");
    [self.videoWriterInput markAsFinished];
    if (self.audioWriterInputAdded) {
        [self.audioWriterInput markAsFinished];
    }

    [self.assetWriter finishWritingWithCompletionHandler:^{
        // This completion runs on an arbitrary queue — dispatch back to recordingQueue
        dispatch_async(self.recordingQueue, ^{
            AVAssetWriterStatus finalStatus = self.assetWriter.status;
            NSError *finalError = self.assetWriter.error;

            if (finalStatus == AVAssetWriterStatusFailed) {
                NSLog(@"[HeyJoeCapturer] finishWriting completed but writer FAILED: %@", finalError);
                [self _cleanupRecordingState];
                if (completionHandler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionHandler(nil, finalError ?: [NSError errorWithDomain:@"HeyJoeCapturer" code:11
                            userInfo:@{NSLocalizedDescriptionKey: @"Recording finalization failed"}]);
                    });
                }
                return;
            }

            NSLog(@"[HeyJoeCapturer] Recording finished: %@", outputURL.path);

            // Log file size
            NSError *fsError = nil;
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputURL.path error:&fsError];
            if (attrs) {
                unsigned long long fileSize = [attrs fileSize];
                NSLog(@"[HeyJoeCapturer] File size: %.2f MB", fileSize / (1024.0 * 1024.0));
            }

            [self _cleanupRecordingState];

            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(outputURL, nil);
                });
            }
        });
    }];
}

/// Must be called on recordingQueue. Resets all recording state to idle.
- (void)_cleanupRecordingState {
    self.recordingActive = NO;
    self.recordingState = HJRecordingStateIdle;
    self.needsCompressionSetup = NO;
    self.hasWrittenFirstVideoFrame = NO;
    self.audioWriterInputAdded = NO;
    self.recordingStartTime = kCMTimeInvalid;
    self.recordingSetupError = nil;
    self.assetWriter = nil;
    self.videoWriterInput = nil;
    self.audioWriterInput = nil;
    self.recordingURL = nil;
    self.recordingCompletionHandler = nil;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    // Fast atomic check — early return if not capturing
    if (!self.isCapturing) return;

    // Handle video frames (delivered on videoOutputQueue)
    if (output == self.videoDataOutput) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pixelBuffer) return;

        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        int64_t timeStampNs = CMTimeGetSeconds(timestamp) * NSEC_PER_SEC;

        // === WebRTC frame delivery (sync, fast, no I/O) ===
        RTCVideoRotation rotation = [self rtcVideoRotationForCurrentDeviceOrientation];

        int pbWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
        int pbHeight = (int)CVPixelBufferGetHeight(pixelBuffer);

        // Target 720p for WebRTC
        int adaptedWidth, adaptedHeight;
        if (pbWidth > pbHeight) {
            adaptedWidth = MIN(pbWidth, 1280);
            adaptedHeight = MIN(pbHeight, 720);
        } else {
            adaptedWidth = MIN(pbWidth, 720);
            adaptedHeight = MIN(pbHeight, 1280);
        }

        RTCCVPixelBuffer *rtcPixelBuffer = [[RTCCVPixelBuffer alloc]
            initWithPixelBuffer:pixelBuffer
                   adaptedWidth:adaptedWidth
                  adaptedHeight:adaptedHeight
                      cropWidth:pbWidth
                     cropHeight:pbHeight
                          cropX:0
                          cropY:0];
        RTCVideoFrame *videoFrame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer
                                                                 rotation:rotation
                                                              timeStampNs:timeStampNs];
        [self.delegate capturer:self didCaptureVideoFrame:videoFrame];

        // === Recording: dispatch to recordingQueue if active ===
        if (self.recordingActive || self.recordingState == HJRecordingStateStarting) {
            // Retain pixel buffer for async dispatch to recordingQueue
            CVPixelBufferRetain(pixelBuffer);
            CMTime ts = timestamp; // value copy
            dispatch_async(self.recordingQueue, ^{
                [self _encodeVideoFrame:pixelBuffer timestamp:ts];
                CVPixelBufferRelease(pixelBuffer);
            });
        }
    }
    // Handle audio frames (delivered on audioOutputQueue)
    else if (output == self.audioDataOutput) {
        if (self.recordingActive) {
            CFRetain(sampleBuffer);
            dispatch_async(self.recordingQueue, ^{
                [self _handleAudioSample:sampleBuffer];
            });
        }
    }
}

/// Must be called on recordingQueue. Encodes a video frame via VTCompressionSession.
- (void)_encodeVideoFrame:(CVPixelBufferRef)pixelBuffer timestamp:(CMTime)timestamp {
    // Check recording state
    if (self.recordingState != HJRecordingStateStarting &&
        self.recordingState != HJRecordingStateRecording) {
        return;
    }

    // Deferred compression session setup on first frame
    if (self.needsCompressionSetup && !self.compressionSession) {
        int actualWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
        int actualHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
        NSLog(@"[HeyJoeCapturer] Actual pixel buffer dimensions: %dx%d", actualWidth, actualHeight);

        int targetWidth = actualWidth;
        int targetHeight = actualHeight;
        int bitrate = 20000000; // 20 Mbps for 4K

        if (self.recordingTargetResolution == HeyJoeRecordingResolution1080p) {
            if (actualWidth > actualHeight) {
                targetWidth = MIN(actualWidth, 1920);
                targetHeight = MIN(actualHeight, 1080);
            } else {
                targetWidth = MIN(actualWidth, 1080);
                targetHeight = MIN(actualHeight, 1920);
            }
            bitrate = 8000000; // 8 Mbps for 1080p
        }

        NSLog(@"[HeyJoeCapturer] Setting up compression session: %dx%d @ %d Mbps (target: %s)",
              targetWidth, targetHeight, bitrate / 1000000,
              self.recordingTargetResolution == HeyJoeRecordingResolution4K ? "4K" : "1080p");

        if (![self _setupCompressionSessionWithWidth:targetWidth height:targetHeight bitrate:bitrate]) {
            NSLog(@"[HeyJoeCapturer] Failed to setup compression session");
            [self _failRecordingWithError:[NSError errorWithDomain:@"HeyJoeCapturer" code:5
                userInfo:@{NSLocalizedDescriptionKey: @"Compression session creation failed"}]];
            return;
        }

        self.needsCompressionSetup = NO;
        // Transition: Starting → Recording
        self.recordingState = HJRecordingStateRecording;
        self.recordingActive = YES;
        NSLog(@"[HeyJoeCapturer] Recording state: Starting → Recording (recordingActive=YES)");
    }

    if (self.compressionSession) {
        self.encodedFrameCount++;
        if (self.encodedFrameCount <= 3) {
            size_t w = CVPixelBufferGetWidth(pixelBuffer);
            size_t h = CVPixelBufferGetHeight(pixelBuffer);
            NSLog(@"[HeyJoeCapturer] Frame #%d — PixelBuffer: %zux%zu", self.encodedFrameCount, w, h);
        } else if (self.encodedFrameCount % 30 == 0) {
            NSLog(@"[HeyJoeCapturer] Encoding video frame #%d", self.encodedFrameCount);
        }

        OSStatus status = VTCompressionSessionEncodeFrame(
            self.compressionSession,
            pixelBuffer,
            timestamp,
            kCMTimeInvalid,
            NULL,
            NULL,
            NULL
        );
        if (status != noErr) {
            NSLog(@"[HeyJoeCapturer] VTCompressionSessionEncodeFrame failed with status: %d", (int)status);
        }
    }
}

#pragma mark - Helper Methods

+ (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device
                               targetFrameRate:(NSInteger)fps {
    if (!device) return nil;

    AVCaptureDeviceFormat *bestFormat = nil;
    int32_t bestPixelCount = 0;

    const int32_t maxPixelCount = 3840 * 2160;

    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        int32_t pixelCount = dims.width * dims.height;

        if (pixelCount > maxPixelCount) {
            continue;
        }

        BOOL supportsTargetFps = NO;
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
            if (range.maxFrameRate >= fps) {
                supportsTargetFps = YES;
                break;
            }
        }

        if (!supportsTargetFps) continue;

        FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        BOOL isBiplanar = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

        if (pixelCount > bestPixelCount) {
            bestFormat = format;
            bestPixelCount = pixelCount;
        } else if (pixelCount == bestPixelCount && isBiplanar && bestFormat) {
            FourCharCode bestPixelFormat = CMFormatDescriptionGetMediaSubType(bestFormat.formatDescription);
            if (bestPixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
                bestPixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                bestFormat = format;
            }
        }
    }

    if (bestFormat) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
        NSLog(@"[HeyJoeCapturer] Best format for device (capped at 4K): %dx%d", dims.width, dims.height);
    }

    return bestFormat;
}

#pragma mark - Zoom Control

- (void)setZoomFactor:(CGFloat)zoomFactor
    completionHandler:(nullable void (^)(CGFloat actualZoom, CGFloat minZoom, CGFloat maxZoom, NSError * _Nullable error))completionHandler {

    if (isnan(zoomFactor) || isinf(zoomFactor) || zoomFactor < 0) {
        NSLog(@"[HeyJoeCapturer] setZoomFactor: Invalid zoom value: %f", zoomFactor);
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(1.0, 1.0, 1.0, [NSError errorWithDomain:@"HeyJoeCapturer"
                                                                     code:10
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"Invalid zoom factor"}]);
            });
        }
        return;
    }

    dispatch_async(self.captureQueue, ^{
        AVCaptureDevice *device = self.videoInput.device;
        if (!device) {
            NSLog(@"[HeyJoeCapturer] setZoomFactor: No device available");
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(1.0, 1.0, 1.0, [NSError errorWithDomain:@"HeyJoeCapturer"
                                                                         code:11
                                                                     userInfo:@{NSLocalizedDescriptionKey: @"No device available"}]);
                });
            }
            return;
        }

        NSError *error = nil;
        if ([device lockForConfiguration:&error]) {
            CGFloat minZoom = device.minAvailableVideoZoomFactor;
            CGFloat maxZoom = device.maxAvailableVideoZoomFactor;
            CGFloat clampedZoom = MAX(minZoom, MIN(zoomFactor, maxZoom));

            [device rampToVideoZoomFactor:clampedZoom withRate:4.0];

            [device unlockForConfiguration];
            NSLog(@"[HeyJoeCapturer] Zoom set to %.2f (range: %.2f-%.2f)", clampedZoom, minZoom, maxZoom);

            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(clampedZoom, minZoom, maxZoom, nil);
                });
            }
        } else {
            NSLog(@"[HeyJoeCapturer] Failed to lock device for zoom: %@", error);
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(1.0, 1.0, 1.0, error);
                });
            }
        }
    });
}

- (void)getZoomInfoWithCompletionHandler:(void (^)(CGFloat currentZoom, CGFloat minZoom, CGFloat maxZoom))completionHandler {
    dispatch_async(self.captureQueue, ^{
        AVCaptureDevice *device = self.videoInput.device;
        CGFloat currentZoom = 1.0;
        CGFloat minZoom = 1.0;
        CGFloat maxZoom = 1.0;

        if (device) {
            currentZoom = device.videoZoomFactor;
            minZoom = device.minAvailableVideoZoomFactor;
            maxZoom = device.maxAvailableVideoZoomFactor;
        }

        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(currentZoom, minZoom, maxZoom);
            });
        }
    });
}

@end

#pragma mark - VTCompressionSession Callback

static void compressionOutputCallback(void *outputCallbackRefCon,
                                       void *sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer) {
    if (!outputCallbackRefCon) return;

    // outputCallbackRefCon is a CFBridgingRetain'd HJCompressionCallbackContext.
    // __bridge (no ownership transfer) since VT calls this callback multiple times.
    // The retained ref is released when the compression session is invalidated.
    HJCompressionCallbackContext *ctx = (__bridge HJCompressionCallbackContext *)outputCallbackRefCon;

    // Fast atomic check — immediate cutoff if session was torn down
    if (ctx.invalidated) return;

    // Weak ref — nil if capturer was deallocated
    HeyJoeVideoCapturer *capturer = ctx.capturer;
    if (!capturer) return;

    capturer.compressedCallbackCount++;
    if (capturer.compressedCallbackCount <= 3 || capturer.compressedCallbackCount % 30 == 0) {
        NSLog(@"[HeyJoeCapturer] Compression callback #%d, status=%d", capturer.compressedCallbackCount, (int)status);
    }

    if (status != noErr) {
        NSLog(@"[HeyJoeCapturer] Compression error: %d", (int)status);
        return;
    }

    if (!sampleBuffer) {
        NSLog(@"[HeyJoeCapturer] Compression callback: sampleBuffer is NULL");
        return;
    }

    // Retain sample buffer and dispatch to recordingQueue
    CFRetain(sampleBuffer);
    dispatch_async(ctx.recordingQueue, ^{
        // Re-check invalidation after dispatch (context may have been invalidated while enqueued)
        if (ctx.invalidated) {
            CFRelease(sampleBuffer);
            return;
        }
        HeyJoeVideoCapturer *cap = ctx.capturer;
        if (!cap) {
            CFRelease(sampleBuffer);
            return;
        }
        // sampleBuffer ownership transferred to _handleCompressedFrame (it calls CFRelease)
        [cap _handleCompressedFrame:sampleBuffer];
    });
}
