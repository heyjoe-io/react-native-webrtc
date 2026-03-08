package com.oney.WebRTCModule;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.media.MediaRecorder;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.OrientationEventListener;
import android.view.Surface;

import org.webrtc.CapturerObserver;
import org.webrtc.CameraEnumerator;
import org.webrtc.CameraVideoCapturer;
import org.webrtc.EglBase;
import org.webrtc.GlRectDrawer;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoCapturer;
import org.webrtc.VideoFrame;
import org.webrtc.VideoFrameDrawer;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * HeyJoeVideoCapturer — wraps a Camera2/Camera1 capturer via composition,
 * intercepts frames at the source for high-resolution local recording.
 *
 * Mirrors the iOS HeyJoeVideoCapturer architecture:
 * - IS the camera capturer (drop-in replacement for Camera2Capturer)
 * - Intercepts frames via CapturerObserver proxy
 * - Sends full-res frames to both WebRTC and the recording pipeline
 * - Recording: OpenGL render → MediaCodec Surface → H.264 → MediaMuxer
 * - Audio: AudioRecord 48kHz stereo → MediaCodec AAC → MediaMuxer
 */
public class HeyJoeVideoCapturer implements VideoCapturer {
    private static final String TAG = "HeyJoeVideoCapturer";

    // Resolution constants
    public static final int RESOLUTION_1080P = 1;
    public static final int RESOLUTION_4K = 2;

    // Video encoding parameters
    private static final int VIDEO_FPS = 30;
    private static final int IFRAME_INTERVAL = 1;
    private static final int BITRATE_1080P = 10_000_000;  // 10 Mbps
    private static final int BITRATE_4K = 25_000_000;     // 25 Mbps

    // Audio encoding parameters
    private static final int AUDIO_SAMPLE_RATE = 48000;
    private static final int AUDIO_CHANNELS = 2;
    private static final int AUDIO_BITRATE = 128_000;     // 128 kbps AAC-LC

    // Maximum buffered video frames before muxer starts (5 seconds at 30fps)
    private static final int MAX_BUFFERED_FRAMES = 150;

    // Thread join timeout
    private static final long THREAD_JOIN_TIMEOUT_MS = 3000;

    // Singleton
    private static HeyJoeVideoCapturer instance;

    // Inner capturer (Camera2Capturer or Camera1Capturer)
    private volatile VideoCapturer innerCapturer;
    private CameraEnumerator cameraEnumerator;
    private String cameraName;
    private volatile Context context;

    // Capture state
    private volatile boolean isCapturing = false;
    private volatile int captureWidth;
    private volatile int captureHeight;
    private int captureFps;

    // WebRTC-requested resolution (we capture higher, scale down for WebRTC)
    private volatile int webrtcWidth;
    private volatile int webrtcHeight;

    // Orientation tracking (mirrors iOS cachedDeviceOrientation)
    private OrientationEventListener orientationListener;
    private volatile int deviceOrientationDegrees = 0; // 0, 90, 180, 270

    // Camera sensor orientation (set via setInnerCapturer)
    private int sensorOrientation = 90; // default for most rear cameras
    private boolean isFrontCamera = false;

    // Last known frame rotation from WebRTC (set on every frame, used for recording orientation)
    private volatile int lastFrameRotation = 0;

    // Recording state machine: Idle → Starting → Recording → Stopping → Idle
    // All transitions guarded by stateLock
    private enum RecordingState { IDLE, STARTING, RECORDING, STOPPING }
    private volatile RecordingState recordingState = RecordingState.IDLE;
    private final Object stateLock = new Object();

    // Recording pipeline — video
    private MediaCodec videoEncoder;
    private Surface encoderInputSurface;
    private EglBase recordingEglBase;
    private VideoFrameDrawer frameDrawer;
    private GlRectDrawer glDrawer;
    private int encoderWidth;
    private int encoderHeight;

    // Recording pipeline — audio
    private MediaCodec audioEncoder;
    private AudioCaptureRunner audioCaptureRunner;
    private Thread audioCaptureThread;

    // Muxer
    private MediaMuxer mediaMuxer;
    private int videoTrackIndex = -1;
    private int audioTrackIndex = -1;
    private volatile boolean muxerStarted = false;
    private final Object muxerLock = new Object();
    private final List<BufferedFrame> bufferedVideoFrames = new ArrayList<>();

    // Threading
    private HandlerThread encoderThread;
    private volatile Handler encoderHandler;
    private Thread videoDrainThread;
    private Thread audioDrainThread;
    private volatile boolean audioDrainRunning = false;

    // Frame timing — uses System.nanoTime() consistently for both audio and video
    private volatile long globalStartTimeNs = -1;
    private final Object timeLock = new Object();
    private long frameCount = 0;

    // Recording file
    private String currentFilePath;

    // Callback for start completion (async pipeline setup)
    public interface StartRecordingCallback {
        void onStarted(int width, int height, String error);
    }

    // Callback for stop completion
    public interface StopRecordingCallback {
        void onStopped(String filePath, long fileSize, int width, int height, String error);
    }

    // Helper for buffering encoded frames before muxer starts
    private static class BufferedFrame {
        final ByteBuffer data;
        final MediaCodec.BufferInfo info;

        BufferedFrame(ByteBuffer srcData, MediaCodec.BufferInfo srcInfo) {
            data = ByteBuffer.allocate(srcData.remaining());
            data.put(srcData);
            data.flip();
            info = new MediaCodec.BufferInfo();
            info.set(srcInfo.offset, srcInfo.size, srcInfo.presentationTimeUs, srcInfo.flags);
        }
    }

    private HeyJoeVideoCapturer() {
        // Private constructor for singleton
    }

    public static synchronized HeyJoeVideoCapturer getInstance() {
        if (instance == null) {
            instance = new HeyJoeVideoCapturer();
        }
        return instance;
    }

    /**
     * Set the inner capturer that this wrapper delegates to.
     * Called by CameraCaptureController.createVideoCapturer().
     * If recording is active, force-stops it first.
     */
    public void setInnerCapturer(VideoCapturer capturer, CameraEnumerator enumerator,
                                  String camName, Context ctx) {
        synchronized (stateLock) {
            if (recordingState != RecordingState.IDLE) {
                Log.w(TAG, "setInnerCapturer called while recording — force stopping");
                forceResetRecordingStateLocked();
            }
        }
        this.innerCapturer = capturer;
        this.cameraEnumerator = enumerator;
        this.cameraName = camName;
        this.context = ctx;

        // Detect front/rear camera for orientation calculation
        this.isFrontCamera = enumerator.isFrontFacing(camName);

        // Get sensor orientation from Camera2 API
        try {
            android.hardware.camera2.CameraManager camManager =
                    (android.hardware.camera2.CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
            for (String id : camManager.getCameraIdList()) {
                android.hardware.camera2.CameraCharacteristics chars =
                        camManager.getCameraCharacteristics(id);
                // Match by facing direction
                Integer facing = chars.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING);
                boolean idIsFront = facing != null
                        && facing == android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT;
                if (idIsFront == this.isFrontCamera) {
                    Integer sensorOr = chars.get(
                            android.hardware.camera2.CameraCharacteristics.SENSOR_ORIENTATION);
                    if (sensorOr != null) {
                        this.sensorOrientation = sensorOr;
                    }
                    break;
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Could not get sensor orientation, using default 90", e);
        }

        Log.d(TAG, "Inner capturer set: " + camName
                + ", front=" + isFrontCamera + ", sensorOrientation=" + sensorOrientation);
    }

    // --- VideoCapturer interface (delegated to inner capturer) ---

    @Override
    public void initialize(SurfaceTextureHelper surfaceTextureHelper, Context applicationContext,
                           CapturerObserver capturerObserver) {
        if (this.context == null) {
            this.context = applicationContext;
        }

        // Start orientation listener (mirrors iOS cachedDeviceOrientation)
        if (orientationListener == null) {
            orientationListener = new OrientationEventListener(applicationContext) {
                @Override
                public void onOrientationChanged(int orientation) {
                    if (orientation == ORIENTATION_UNKNOWN) return;
                    // Snap to nearest 90-degree increment
                    if (orientation >= 315 || orientation < 45) {
                        deviceOrientationDegrees = 0;   // Portrait
                    } else if (orientation >= 45 && orientation < 135) {
                        deviceOrientationDegrees = 270; // Landscape right
                    } else if (orientation >= 135 && orientation < 225) {
                        deviceOrientationDegrees = 180; // Upside down
                    } else {
                        deviceOrientationDegrees = 90;  // Landscape left
                    }
                }
            };
            if (orientationListener.canDetectOrientation()) {
                orientationListener.enable();
            }
        }

        // Wrap the observer to intercept frames for recording
        CapturerObserver interceptingObserver = new CapturerObserver() {
            @Override
            public void onCapturerStarted(boolean success) {
                isCapturing = success;
                capturerObserver.onCapturerStarted(success);
                if (success) {
                    Log.d(TAG, "Capture started successfully");
                }
            }

            @Override
            public void onCapturerStopped() {
                isCapturing = false;
                capturerObserver.onCapturerStopped();
                Log.d(TAG, "Capture stopped");

                if (recordingState == RecordingState.RECORDING) {
                    Log.w(TAG, "Capture stopped while recording — recording will be interrupted");
                }
            }

            @Override
            public void onFrameCaptured(VideoFrame frame) {
                // Track frame rotation — WebRTC computes this correctly for each camera
                // Used as the muxer orientationHint when recording starts
                lastFrameRotation = frame.getRotation();

                // Scale down to WebRTC-requested resolution (e.g., 720p)
                // Camera captures at 1080p+, but WebRTC only needs 720p
                int targetW = webrtcWidth;
                int targetH = webrtcHeight;
                VideoFrame.Buffer buf = frame.getBuffer();
                int bufW = buf.getWidth();
                int bufH = buf.getHeight();

                if (targetW > 0 && targetH > 0
                        && (bufW != targetW || bufH != targetH)) {
                    VideoFrame.Buffer scaled = buf.cropAndScale(
                            0, 0, bufW, bufH, targetW, targetH);
                    VideoFrame scaledFrame = new VideoFrame(
                            scaled, frame.getRotation(), frame.getTimestampNs());
                    capturerObserver.onFrameCaptured(scaledFrame);
                    scaledFrame.release();
                } else {
                    capturerObserver.onFrameCaptured(frame);
                }

                // Forward full-res to recording pipeline if active
                if (recordingState == RecordingState.RECORDING) {
                    Handler handler = encoderHandler;
                    if (handler != null) {
                        processFrameForRecording(frame, handler);
                    }
                }
            }
        };

        innerCapturer.initialize(surfaceTextureHelper, applicationContext, interceptingObserver);
    }

    @Override
    public void startCapture(int width, int height, int fps) {
        // Save WebRTC-requested resolution (e.g., 720p)
        this.webrtcWidth = width;
        this.webrtcHeight = height;
        this.captureFps = fps;

        // Request higher resolution from camera for recording (at least 1080p)
        int captureW, captureH;
        if (height > width) {
            // Portrait
            captureW = Math.max(width, 1080);
            captureH = Math.max(height, 1920);
        } else {
            // Landscape
            captureW = Math.max(width, 1920);
            captureH = Math.max(height, 1080);
        }
        this.captureWidth = captureW;
        this.captureHeight = captureH;

        Log.d(TAG, "startCapture: WebRTC=" + width + "x" + height
                + ", Camera=" + captureW + "x" + captureH + " @ " + fps + "fps");
        innerCapturer.startCapture(captureW, captureH, fps);
    }

    @Override
    public void stopCapture() throws InterruptedException {
        innerCapturer.stopCapture();
    }

    @Override
    public void changeCaptureFormat(int width, int height, int fps) {
        this.webrtcWidth = width;
        this.webrtcHeight = height;
        this.captureFps = fps;

        int captureW, captureH;
        if (height > width) {
            captureW = Math.max(width, 1080);
            captureH = Math.max(height, 1920);
        } else {
            captureW = Math.max(width, 1920);
            captureH = Math.max(height, 1080);
        }
        this.captureWidth = captureW;
        this.captureHeight = captureH;

        innerCapturer.changeCaptureFormat(captureW, captureH, fps);
    }

    @Override
    public void dispose() {
        synchronized (stateLock) {
            if (recordingState != RecordingState.IDLE) {
                Log.w(TAG, "Disposing while recording — force stopping");
                forceResetRecordingStateLocked();
            }
        }
        if (orientationListener != null) {
            orientationListener.disable();
            orientationListener = null;
        }
        if (innerCapturer != null) {
            innerCapturer.dispose();
        }
    }

    @Override
    public boolean isScreencast() {
        return innerCapturer != null && innerCapturer.isScreencast();
    }

    // --- CameraVideoCapturer delegation for switchCamera ---

    public void switchCamera(CameraVideoCapturer.CameraSwitchHandler handler) {
        if (innerCapturer instanceof CameraVideoCapturer) {
            ((CameraVideoCapturer) innerCapturer).switchCamera(handler);
        }
    }

    // --- Recording API ---

    public int getVideoWidth() {
        return encoderWidth > 0 ? encoderWidth : captureWidth;
    }

    public int getVideoHeight() {
        return encoderHeight > 0 ? encoderHeight : captureHeight;
    }

    public boolean isCapturing() {
        return isCapturing;
    }

    public boolean isRecording() {
        return recordingState == RecordingState.RECORDING;
    }

    public boolean isStartingOrRecording() {
        RecordingState s = recordingState;
        return s == RecordingState.STARTING || s == RecordingState.RECORDING;
    }

    public String getCurrentFilePath() {
        return currentFilePath;
    }

    /**
     * Start recording to the given file path.
     * The callback is invoked on the encoder thread when the pipeline is ready (or on error).
     *
     * @param filePath  Full path to the output MP4 file
     * @param enable4K  true for 4K recording, false for 1080p
     * @param callback  Called when recording actually starts (or fails)
     */
    public void startRecording(String filePath, boolean enable4K, StartRecordingCallback callback) {
        synchronized (stateLock) {
            if (recordingState != RecordingState.IDLE) {
                Log.w(TAG, "startRecording called but state is " + recordingState);
                if (callback != null) {
                    callback.onStarted(0, 0, "Recording already in progress (state=" + recordingState + ")");
                }
                return;
            }
            recordingState = RecordingState.STARTING;
        }

        currentFilePath = filePath;

        // Always encode in landscape — orientation is handled by muxer metadata
        // (mirrors iOS: pixel buffer is fixed in landscape, transform rotates on playback)
        if (enable4K) {
            encoderWidth = 3840;
            encoderHeight = 2160;
        } else {
            encoderWidth = 1920;
            encoderHeight = 1080;
        }

        int bitrate = enable4K ? BITRATE_4K : BITRATE_1080P;

        Log.d(TAG, "Starting recording: " + encoderWidth + "x" + encoderHeight
                + " @ " + bitrate + "bps → " + filePath);

        // Create encoder thread
        encoderThread = new HandlerThread("HeyJoeEncoder");
        encoderThread.start();
        encoderHandler = new Handler(encoderThread.getLooper());

        encoderHandler.post(() -> {
            try {
                setupEncodingPipeline(bitrate);
                synchronized (stateLock) {
                    recordingState = RecordingState.RECORDING;
                }
                Log.d(TAG, "Recording started successfully");
                if (callback != null) {
                    callback.onStarted(encoderWidth, encoderHeight, null);
                }
            } catch (Exception e) {
                Log.e(TAG, "Failed to setup encoding pipeline", e);
                cleanupRecording();
                synchronized (stateLock) {
                    recordingState = RecordingState.IDLE;
                }
                if (callback != null) {
                    callback.onStarted(0, 0, e.getMessage());
                }
            }
        });
    }

    /**
     * Stop recording and invoke callback with result.
     * Callback is invoked on the encoder thread — caller must handle threading.
     */
    public void stopRecording(StopRecordingCallback callback) {
        synchronized (stateLock) {
            if (recordingState != RecordingState.RECORDING) {
                Log.w(TAG, "stopRecording called but state is " + recordingState);
                if (callback != null) {
                    callback.onStopped(null, 0, 0, 0, "Not recording");
                }
                return;
            }
            recordingState = RecordingState.STOPPING;
        }

        Log.d(TAG, "Stopping recording...");

        // Save values before cleanup can null them
        final String savedFilePath = currentFilePath;

        // Stop audio capture first
        if (audioCaptureRunner != null) {
            audioCaptureRunner.stop();
        }
        if (audioCaptureThread != null) {
            try {
                audioCaptureThread.join(THREAD_JOIN_TIMEOUT_MS);
            } catch (InterruptedException e) {
                Log.e(TAG, "Interrupted waiting for audio capture thread");
            }
        }

        // Stop audio drain — wait for it to fully exit before touching audioEncoder
        audioDrainRunning = false;
        if (audioDrainThread != null) {
            try {
                audioDrainThread.join(THREAD_JOIN_TIMEOUT_MS);
            } catch (InterruptedException e) {
                Log.e(TAG, "Interrupted waiting for audio drain thread");
            }
            if (audioDrainThread.isAlive()) {
                Log.w(TAG, "Audio drain thread still alive after join timeout — interrupting");
                audioDrainThread.interrupt();
            }
        }

        // Finalize on encoder thread
        Handler handler = encoderHandler;
        if (handler != null) {
            handler.post(() -> {
                try {
                    // Send EOS to audio encoder (drain thread is stopped, safe to call)
                    if (audioEncoder != null) {
                        drainAudioEncoder(true);
                        Thread.sleep(100);
                    }

                    // Signal end of video stream — drain thread will naturally stop on EOS
                    if (videoEncoder != null) {
                        videoEncoder.signalEndOfInputStream();
                    }

                    // Wait for video drain to finish via EOS (do NOT set videoDrainRunning=false)
                    if (videoDrainThread != null) {
                        try {
                            videoDrainThread.join(THREAD_JOIN_TIMEOUT_MS);
                        } catch (InterruptedException e) {
                            Log.e(TAG, "Interrupted waiting for video drain");
                        }
                        if (videoDrainThread.isAlive()) {
                            Log.w(TAG, "Video drain thread still alive — interrupting");
                            videoDrainThread.interrupt();
                        }
                    }

                    // Stop and release encoders
                    if (videoEncoder != null) {
                        videoEncoder.stop();
                        videoEncoder.release();
                    }
                    if (audioEncoder != null) {
                        audioEncoder.stop();
                        audioEncoder.release();
                    }

                    // Stop and release muxer
                    synchronized (muxerLock) {
                        if (muxerStarted && mediaMuxer != null) {
                            mediaMuxer.stop();
                        }
                        if (mediaMuxer != null) {
                            mediaMuxer.release();
                        }
                    }

                    // Get file info
                    long fileSize = 0;
                    if (savedFilePath != null) {
                        File file = new File(savedFilePath);
                        if (file.exists()) {
                            fileSize = file.length();
                        }
                    }

                    int w = encoderWidth;
                    int h = encoderHeight;

                    Log.d(TAG, "Recording stopped. File: " + savedFilePath
                            + ", size: " + fileSize + " bytes");

                    cleanupRecording();
                    synchronized (stateLock) {
                        recordingState = RecordingState.IDLE;
                    }

                    if (callback != null) {
                        callback.onStopped(savedFilePath, fileSize, w, h, null);
                    }
                } catch (Exception e) {
                    Log.e(TAG, "Error stopping recording", e);
                    cleanupRecording();
                    synchronized (stateLock) {
                        recordingState = RecordingState.IDLE;
                    }

                    if (callback != null) {
                        callback.onStopped(savedFilePath, 0, 0, 0, e.getMessage());
                    }
                }
            });
        } else {
            cleanupRecording();
            synchronized (stateLock) {
                recordingState = RecordingState.IDLE;
            }
            if (callback != null) {
                callback.onStopped(null, 0, 0, 0, "No encoder handler");
            }
        }
    }

    /**
     * Force reset recording state — used for cleanup after room transitions.
     *
     * @return true if was recording
     */
    public boolean forceResetRecordingState() {
        synchronized (stateLock) {
            return forceResetRecordingStateLocked();
        }
    }

    /** Must be called with stateLock held. */
    private boolean forceResetRecordingStateLocked() {
        boolean wasRecording = recordingState != RecordingState.IDLE;
        if (wasRecording) {
            Log.w(TAG, "Force resetting recording state from " + recordingState);
            recordingState = RecordingState.STOPPING;

            // Stop threads first before releasing codecs
            if (audioCaptureRunner != null) {
                audioCaptureRunner.stop();
            }
            audioDrainRunning = false;

            // Wait for drain threads to exit so they're not touching MediaCodec
            if (audioDrainThread != null) {
                try {
                    audioDrainThread.join(1000);
                } catch (InterruptedException e) { /* ignore */ }
                if (audioDrainThread.isAlive()) {
                    audioDrainThread.interrupt();
                }
            }
            if (videoDrainThread != null) {
                try {
                    videoDrainThread.join(1000);
                } catch (InterruptedException e) { /* ignore */ }
                if (videoDrainThread.isAlive()) {
                    videoDrainThread.interrupt();
                }
            }
            if (audioCaptureThread != null) {
                try {
                    audioCaptureThread.join(1000);
                } catch (InterruptedException e) { /* ignore */ }
            }

            // Now safe to release codecs — no other threads are using them
            try {
                if (videoEncoder != null) {
                    videoEncoder.stop();
                    videoEncoder.release();
                }
            } catch (Exception e) { /* ignore */ }

            try {
                if (audioEncoder != null) {
                    audioEncoder.stop();
                    audioEncoder.release();
                }
            } catch (Exception e) { /* ignore */ }

            try {
                synchronized (muxerLock) {
                    if (muxerStarted && mediaMuxer != null) {
                        mediaMuxer.stop();
                    }
                    if (mediaMuxer != null) {
                        mediaMuxer.release();
                    }
                }
            } catch (Exception e) { /* ignore */ }

            cleanupRecording();
            recordingState = RecordingState.IDLE;
        }
        return wasRecording;
    }

    // --- Private: Recording Pipeline Setup ---

    private void setupEncodingPipeline(int videoBitrate) throws IOException {
        // Reset state
        videoTrackIndex = -1;
        audioTrackIndex = -1;
        muxerStarted = false;
        frameCount = 0;
        synchronized (timeLock) {
            globalStartTimeNs = -1;
        }
        bufferedVideoFrames.clear();

        // Create muxer
        mediaMuxer = new MediaMuxer(currentFilePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

        // Use the frame rotation that WebRTC already computes correctly for the
        // active camera + device orientation. This is the most reliable source since
        // WebRTC handles all the sensor/device/front-back math internally.
        // We encode raw landscape pixels, so this hint tells players how to rotate.
        int orientationHint = lastFrameRotation;
        mediaMuxer.setOrientationHint(orientationHint);
        Log.d(TAG, "Muxer orientation hint: " + orientationHint
                + "° (from frame rotation, front=" + isFrontCamera + ")");

        // Setup video encoder (H.264 with Surface input)
        MediaFormat videoFormat = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC, encoderWidth, encoderHeight);
        videoFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        videoFormat.setInteger(MediaFormat.KEY_BIT_RATE, videoBitrate);
        videoFormat.setInteger(MediaFormat.KEY_FRAME_RATE, VIDEO_FPS);
        videoFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_INTERVAL);

        videoEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        videoEncoder.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        encoderInputSurface = videoEncoder.createInputSurface();
        videoEncoder.start();

        // Setup audio encoder (AAC-LC, 48kHz stereo)
        MediaFormat audioFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC, AUDIO_SAMPLE_RATE, AUDIO_CHANNELS);
        audioFormat.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BITRATE);
        audioFormat.setInteger(MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC);
        audioFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384);

        audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
        audioEncoder.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        audioEncoder.start();

        // Setup EGL context for rendering to encoder surface
        EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();
        recordingEglBase = EglBase.create(sharedContext, EglBase.CONFIG_RECORDABLE);
        recordingEglBase.createSurface(encoderInputSurface);
        recordingEglBase.makeCurrent();

        frameDrawer = new VideoFrameDrawer();
        glDrawer = new GlRectDrawer();

        // Start audio capture
        audioCaptureRunner = new AudioCaptureRunner();
        audioCaptureThread = new Thread(audioCaptureRunner, "HeyJoeAudioCapture");
        audioCaptureThread.start();

        // Start drain threads
        startVideoDrainThread();
        startAudioDrainThread();

        Log.d(TAG, "Encoding pipeline setup complete: " + encoderWidth + "x" + encoderHeight);
    }

    // --- Private: Frame Processing ---

    private void processFrameForRecording(VideoFrame frame, Handler handler) {
        if (encoderInputSurface == null) {
            return;
        }

        frameCount++;

        // Set global start time using System.nanoTime() consistently
        synchronized (timeLock) {
            if (globalStartTimeNs == -1) {
                globalStartTimeNs = System.nanoTime();
                Log.d(TAG, "Global start time set from first video frame");
            }
        }

        // Capture wall-clock time for this frame's PTS
        final long frameWallTimeNs = System.nanoTime();

        // Copy the frame WITHOUT rotation for the encoder.
        // We encode raw landscape pixels (same as the camera sensor produces).
        // Rotation is handled by the muxer's orientationHint metadata.
        // (Mirrors iOS: pixel buffer is fixed in landscape, transform rotates on playback)
        final VideoFrame frameCopy = new VideoFrame(
                frame.getBuffer(),
                0,  // No rotation — muxer orientationHint handles display rotation
                frame.getTimestampNs()
        );
        frameCopy.retain();

        handler.post(() -> {
            if (recordingState != RecordingState.RECORDING) {
                frameCopy.release();
                return;
            }

            // Null-check EGL resources in case cleanup raced
            EglBase egl = recordingEglBase;
            VideoFrameDrawer fd = frameDrawer;
            GlRectDrawer gd = glDrawer;
            if (egl == null || fd == null || gd == null) {
                frameCopy.release();
                return;
            }

            try {
                egl.makeCurrent();
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                fd.drawFrame(frameCopy, gd, null,
                        0, 0, encoderWidth, encoderHeight);

                long startTime;
                synchronized (timeLock) {
                    startTime = globalStartTimeNs;
                }
                long presentationTimeNs = frameWallTimeNs - startTime;
                if (presentationTimeNs < 0) presentationTimeNs = 0;
                egl.swapBuffers(presentationTimeNs);

                if (frameCount % 90 == 0) {
                    Log.d(TAG, "Rendered " + frameCount + " frames to encoder");
                }
            } catch (Exception e) {
                Log.e(TAG, "Error rendering frame to encoder", e);
            } finally {
                frameCopy.release();
            }
        });
    }

    // --- Private: Video Drain Thread ---

    private void startVideoDrainThread() {
        videoDrainThread = new Thread(() -> {
            MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();

            while (true) {
                try {
                    int outputIndex = videoEncoder.dequeueOutputBuffer(bufferInfo, 10000);

                    if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        MediaFormat newFormat = videoEncoder.getOutputFormat();
                        Log.d(TAG, "Video output format: " + newFormat);

                        synchronized (muxerLock) {
                            if (videoTrackIndex == -1) {
                                videoTrackIndex = mediaMuxer.addTrack(newFormat);
                                Log.d(TAG, "Video track added, index: " + videoTrackIndex);
                            }
                        }
                        attemptStartMuxer();

                    } else if (outputIndex >= 0) {
                        ByteBuffer outputBuffer = videoEncoder.getOutputBuffer(outputIndex);

                        if (bufferInfo.size > 0 && outputBuffer != null) {
                            outputBuffer.position(bufferInfo.offset);
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size);

                            synchronized (muxerLock) {
                                if (muxerStarted) {
                                    mediaMuxer.writeSampleData(videoTrackIndex, outputBuffer, bufferInfo);
                                } else if (bufferedVideoFrames.size() < MAX_BUFFERED_FRAMES) {
                                    bufferedVideoFrames.add(new BufferedFrame(outputBuffer, bufferInfo));
                                } else {
                                    Log.w(TAG, "Video buffer full (" + MAX_BUFFERED_FRAMES
                                            + " frames), dropping frame");
                                }
                            }
                        }

                        videoEncoder.releaseOutputBuffer(outputIndex, false);

                        if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            Log.d(TAG, "Video EOS reached");
                            break;
                        }
                    }
                } catch (IllegalStateException e) {
                    // Encoder was released — exit gracefully
                    Log.d(TAG, "Video drain exiting: " + e.getMessage());
                    break;
                }
            }
            Log.d(TAG, "Video drain thread finished");
        }, "HeyJoeVideoDrain");
        videoDrainThread.start();
    }

    // --- Private: Audio Drain Thread ---

    private void startAudioDrainThread() {
        audioDrainRunning = true;
        audioDrainThread = new Thread(() -> {
            while (audioDrainRunning) {
                try {
                    drainAudioEncoder(false);
                    Thread.sleep(10);
                } catch (InterruptedException e) {
                    break;
                } catch (Exception e) {
                    if (audioDrainRunning) {
                        Log.e(TAG, "Error in audio drain: " + e.getMessage());
                    }
                    break;
                }
            }
            Log.d(TAG, "Audio drain thread finished");
        }, "HeyJoeAudioDrain");
        audioDrainThread.start();
    }

    // --- Private: Audio Encoding ---

    private void encodeAudioFrame(byte[] audioData, long presentationTimeUs) {
        if (recordingState != RecordingState.RECORDING || audioEncoder == null) {
            return;
        }

        try {
            int inputIndex = audioEncoder.dequeueInputBuffer(10000);
            if (inputIndex >= 0) {
                ByteBuffer inputBuffer = audioEncoder.getInputBuffer(inputIndex);
                if (inputBuffer != null) {
                    inputBuffer.clear();
                    inputBuffer.put(audioData);
                    audioEncoder.queueInputBuffer(inputIndex, 0, audioData.length,
                            presentationTimeUs, 0);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error encoding audio frame: " + e.getMessage());
        }
    }

    private void drainAudioEncoder(boolean endOfStream) {
        if (audioEncoder == null) {
            return;
        }

        if (endOfStream) {
            try {
                int inputIndex = audioEncoder.dequeueInputBuffer(10000);
                if (inputIndex >= 0) {
                    audioEncoder.queueInputBuffer(inputIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                    Log.d(TAG, "Sent EOS to audio encoder");
                }
            } catch (Exception e) {
                Log.e(TAG, "Error sending EOS to audio: " + e.getMessage());
            }
        }

        MediaCodec.BufferInfo bufferInfo = new MediaCodec.BufferInfo();

        try {
            int outputIndex;
            while ((outputIndex = audioEncoder.dequeueOutputBuffer(bufferInfo, 0)) >= 0) {
                ByteBuffer outputBuffer = audioEncoder.getOutputBuffer(outputIndex);

                if (outputBuffer != null && bufferInfo.size > 0) {
                    outputBuffer.position(bufferInfo.offset);
                    outputBuffer.limit(bufferInfo.offset + bufferInfo.size);

                    synchronized (muxerLock) {
                        if (muxerStarted && audioTrackIndex != -1) {
                            mediaMuxer.writeSampleData(audioTrackIndex, outputBuffer, bufferInfo);
                        }
                    }
                }

                audioEncoder.releaseOutputBuffer(outputIndex, false);

                if ((bufferInfo.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    Log.d(TAG, "Audio EOS reached");
                    break;
                }
            }

            // Check for format change (happens before first data buffer)
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                MediaFormat newFormat = audioEncoder.getOutputFormat();
                Log.d(TAG, "Audio output format: " + newFormat);

                synchronized (muxerLock) {
                    if (audioTrackIndex == -1) {
                        audioTrackIndex = mediaMuxer.addTrack(newFormat);
                        Log.d(TAG, "Audio track added, index: " + audioTrackIndex);
                    }
                }
                attemptStartMuxer();
            }
        } catch (IllegalStateException e) {
            if (recordingState == RecordingState.RECORDING) {
                Log.e(TAG, "Illegal state in audio drain: " + e.getMessage());
            }
        }
    }

    // --- Private: Muxer Management ---

    private void attemptStartMuxer() {
        synchronized (muxerLock) {
            if (!muxerStarted && videoTrackIndex != -1 && audioTrackIndex != -1) {
                try {
                    mediaMuxer.start();
                    muxerStarted = true;
                    Log.i(TAG, "MediaMuxer started with video and audio tracks");

                    // Flush buffered video frames
                    if (!bufferedVideoFrames.isEmpty()) {
                        Log.d(TAG, "Writing " + bufferedVideoFrames.size() + " buffered video frames");
                        for (BufferedFrame frame : bufferedVideoFrames) {
                            mediaMuxer.writeSampleData(videoTrackIndex, frame.data, frame.info);
                        }
                        bufferedVideoFrames.clear();
                    }
                } catch (IllegalStateException e) {
                    Log.e(TAG, "Failed to start muxer: " + e.getMessage());
                    synchronized (stateLock) {
                        recordingState = RecordingState.IDLE;
                    }
                }
            }
        }
    }

    // --- Private: Cleanup ---

    private void cleanupRecording() {
        // Null out handler first to prevent new work from being posted
        encoderHandler = null;

        try {
            if (frameDrawer != null) {
                frameDrawer.release();
                frameDrawer = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error releasing frameDrawer", e);
        }

        try {
            if (glDrawer != null) {
                glDrawer.release();
                glDrawer = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error releasing glDrawer", e);
        }

        try {
            if (recordingEglBase != null) {
                recordingEglBase.release();
                recordingEglBase = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error releasing EGL base", e);
        }

        try {
            if (encoderThread != null) {
                encoderThread.quitSafely();
                encoderThread = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "Error stopping encoder thread", e);
        }

        videoEncoder = null;
        audioEncoder = null;
        encoderInputSurface = null;
        mediaMuxer = null;
        audioCaptureRunner = null;
        audioCaptureThread = null;
        videoDrainThread = null;
        audioDrainThread = null;
        frameCount = 0;
        synchronized (timeLock) {
            globalStartTimeNs = -1;
        }
        muxerStarted = false;
        videoTrackIndex = -1;
        audioTrackIndex = -1;
        audioDrainRunning = false;
        bufferedVideoFrames.clear();

        Log.d(TAG, "Recording cleanup completed");
    }

    // --- Private: Audio Capture Runner ---

    private class AudioCaptureRunner implements Runnable {
        private volatile boolean running = true;

        void stop() {
            running = false;
        }

        @Override
        public void run() {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);

            int bufferSize = AudioRecord.getMinBufferSize(
                    AUDIO_SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT) * 2;

            AudioRecord audioRecord = null;
            try {
                audioRecord = new AudioRecord(
                        MediaRecorder.AudioSource.DEFAULT,
                        AUDIO_SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT,
                        bufferSize
                );

                if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                    Log.e(TAG, "AudioRecord failed to initialize");
                    audioRecord.release();
                    return;
                }

                audioRecord.startRecording();
                Log.d(TAG, "Audio capture started (48kHz stereo)");

                short[] audioBuffer = new short[bufferSize / 2];

                while (running && recordingState != RecordingState.STOPPING) {
                    int samplesRead = audioRecord.read(audioBuffer, 0, audioBuffer.length);

                    if (samplesRead > 0) {
                        // Use System.nanoTime() consistently (same source as video PTS)
                        long currentTimeNs = System.nanoTime();
                        long startTime;
                        synchronized (timeLock) {
                            if (globalStartTimeNs == -1) {
                                globalStartTimeNs = currentTimeNs;
                                Log.d(TAG, "Global start time set from first audio frame");
                            }
                            startTime = globalStartTimeNs;
                        }

                        long presentationTimeUs = Math.max(0,
                                (currentTimeNs - startTime) / 1000);

                        ByteBuffer byteBuffer = ByteBuffer.allocate(samplesRead * 2);
                        byteBuffer.order(ByteOrder.nativeOrder());
                        byteBuffer.asShortBuffer().put(audioBuffer, 0, samplesRead);

                        encodeAudioFrame(byteBuffer.array(), presentationTimeUs);
                    }
                }

                audioRecord.stop();
                audioRecord.release();
                Log.d(TAG, "Audio capture stopped");

            } catch (Exception e) {
                Log.e(TAG, "Audio capture error: " + e.getMessage(), e);
                if (audioRecord != null) {
                    try {
                        audioRecord.stop();
                        audioRecord.release();
                    } catch (Exception ex) { /* ignore */ }
                }
            }
        }
    }
}
