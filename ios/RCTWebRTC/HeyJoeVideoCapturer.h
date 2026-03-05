#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/RTCVideoCapturer.h>
#import <WebRTC/RTCVideoFrame.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, HeyJoeRecordingResolution) {
    HeyJoeRecordingResolution4K = 0,
    HeyJoeRecordingResolution1080p = 1,
};

typedef NS_ENUM(NSInteger, HJRecordingState) {
    HJRecordingStateIdle = 0,       // Not recording
    HJRecordingStateStarting,       // Waiting for first frame to set up compression
    HJRecordingStateRecording,      // Actively recording
    HJRecordingStateDraining,       // Stop requested, flushing encoder
    HJRecordingStateFinalizing,     // Writer being finalized
};

@class HeyJoeVideoCapturer;

/// Ref-counted context object for VTCompressionSession callbacks.
/// Prevents dangling pointer crashes: VT holds a strong ref to the context,
/// but the capturer ref is weak — nil if deallocated.
@interface HJCompressionCallbackContext : NSObject
@property (weak, nullable) HeyJoeVideoCapturer *capturer;
@property (strong) dispatch_queue_t recordingQueue;
@property (atomic, assign) BOOL invalidated;
@end

/**
 * HeyJoeVideoCapturer - Single-session video capturer with 4K recording support
 *
 * Queue Architecture (4 queues, zero dispatch_sync between them):
 *
 * captureQueue (serial)  — AVCaptureSession lifecycle only
 * recordingQueue (serial) — ALL recording state, VTCompress, AVAssetWriter
 * videoOutputQueue (serial) — video callback delivery only
 * audioOutputQueue (serial) — audio callback delivery only
 *
 * Inter-queue communication is always dispatch_async with completion handlers.
 * Atomic flags (isCapturing, recordingActive) provide fast hot-path checks on
 * callback queues without dispatching to owning queues.
 */
@interface HeyJoeVideoCapturer : RTCVideoCapturer <AVCaptureVideoDataOutputSampleBufferDelegate>

/// The capture session - exposed for debugging/monitoring
@property (nonatomic, strong, readonly, nullable) AVCaptureSession *captureSession;

/// Atomic flag: YES when recording state is HJRecordingStateRecording.
/// Read from any thread for fast-path checks. Authoritative state is on recordingQueue.
@property (atomic, assign, readonly) BOOL recordingActive;

/// Whether the capture session is running (atomic, set on captureQueue)
@property (atomic, assign, readonly) BOOL isCapturing;

/// Current video dimensions (atomic, set once during config on captureQueue, read-only after)
@property (atomic, assign, readonly) int videoWidth;
@property (atomic, assign, readonly) int videoHeight;

/// The recording queue — exposed so HighResRecordModule can dispatch to it
@property (nonatomic, strong, readonly) dispatch_queue_t recordingQueue;

/// Current recording state (only read/written on recordingQueue)
@property (nonatomic, assign, readonly) HJRecordingState recordingState;

/// Atomic flag: YES when recording state is HJRecordingStateStarting.
/// Complements recordingActive for safe cross-queue checks.
@property (atomic, assign, readonly) BOOL recordingStarting;

/// Tracks which code path triggered the last recording failure (for diagnostics)
@property (nonatomic, strong, nullable) NSString *lastRecordingFailurePoint;

/// Counts consecutive VTCompressionSessionEncodeFrame failures (for diagnostics)
@property (nonatomic, assign) int consecutiveEncodeFailures;

/// Shared instance for global access
+ (nullable instancetype)sharedInstance;
+ (void)setSharedInstance:(nullable HeyJoeVideoCapturer *)instance;

/// Initialize with delegate (typically RTCVideoSource)
- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate;

/// Update the delegate for a new WebRTC session.
/// Lightweight: just sets self.delegate. Call only after stopCapture completes.
- (void)updateDelegate:(id<RTCVideoCapturerDelegate>)delegate;

/// Start capturing from the specified camera (async, dispatches to captureQueue)
- (void)startCaptureWithDevice:(AVCaptureDevice *)device
                        format:(AVCaptureDeviceFormat *)format
                           fps:(NSInteger)fps
             completionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler;

/// Stop capturing (async, stops recording first if active, then stops capture session)
- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completionHandler;

/// Start recording to the specified file URL (async, dispatches to recordingQueue)
- (void)startRecordingToURL:(NSURL *)outputURL
          completionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler;

/// Stop recording (async, drains encoder, finalizes writer, calls completion on main)
- (void)stopRecordingWithCompletionHandler:(nullable void (^)(NSURL * _Nullable fileURL, NSError * _Nullable error))completionHandler;

/// Get best available format for device (prefers highest resolution at 30fps)
+ (nullable AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device
                                        targetFrameRate:(NSInteger)fps;

#pragma mark - Zoom Control

/// Set the camera zoom factor (clamped to device limits) with async completion
- (void)setZoomFactor:(CGFloat)zoomFactor
    completionHandler:(nullable void (^)(CGFloat actualZoom, CGFloat minZoom, CGFloat maxZoom, NSError * _Nullable error))completionHandler;

/// Get zoom info asynchronously (thread-safe)
- (void)getZoomInfoWithCompletionHandler:(void (^)(CGFloat currentZoom, CGFloat minZoom, CGFloat maxZoom))completionHandler;

/// Target recording resolution (default: 1080p for smaller file sizes)
@property (nonatomic, assign) HeyJoeRecordingResolution recordingTargetResolution;

@end

NS_ASSUME_NONNULL_END
