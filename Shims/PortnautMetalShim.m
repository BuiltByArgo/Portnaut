// PortnautMetalShim: loaded into Wine processes with DYLD_INSERT_LIBRARIES.
//
// 1. Pipeline fix. Direct3D 11 only writes render target 0 while dual-source blending is on and
//    ignores the other bound targets. DXMT passes every bound target to Metal, which aborts the
//    process ("Dual source blending is used in combination with multiple render targets"). This
//    shim drops targets 1-7 from such pipeline descriptors before Metal validates them, matching
//    Direct3D 11. Every other pipeline is passed through unchanged.
// 2. Presentation, both opt-in through the environment Portnaut sets:
//    PORTNAUT_LATENCY_TRACE=1 prints a "PortnautLatency:" summary to stderr (session.log) every 5 s.
//    PORTNAUT_FRAME_QUEUE=2 limits CAMetalLayer to two drawables, so one fewer frame can wait.
//
// AppKit and QuartzCore are not linked: this library loads into every Wine process, including
// wineserver. Their classes are looked up at runtime in the processes that already use them.
//
// Built without ARC: the interposed functions return +1 objects, which are passed through as-is.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

typedef id (*PipelineIMP)(id, SEL, id, MTLPipelineOption, id *, NSError **);

static IMP originalRender, originalMesh;
static os_unfair_lock installLock = OS_UNFAIR_LOCK_INIT;
static Class installedClasses[4];
static atomic_bool reported;

static BOOL usesSource1(MTLBlendFactor factor) {
    return factor == MTLBlendFactorSource1Color || factor == MTLBlendFactorOneMinusSource1Color
        || factor == MTLBlendFactorSource1Alpha || factor == MTLBlendFactorOneMinusSource1Alpha;
}

/// Returns a corrected copy, or nil when the descriptor is already valid.
static id corrected(id descriptor, MTLRenderPipelineColorAttachmentDescriptorArray *colors) {
    MTLRenderPipelineColorAttachmentDescriptor *target0 = colors[0];
    if (!target0.blendingEnabled || !(usesSource1(target0.sourceRGBBlendFactor) || usesSource1(target0.destinationRGBBlendFactor)
                                      || usesSource1(target0.sourceAlphaBlendFactor) || usesSource1(target0.destinationAlphaBlendFactor))) {
        return nil;
    }
    BOOL extraTargets = NO;
    for (NSUInteger i = 1; i < 8; i++) extraTargets |= colors[i].pixelFormat != MTLPixelFormatInvalid;
    if (!extraTargets) return nil;
    id copy = [[descriptor copy] autorelease];
    // Both descriptor classes have colorAttachments of this type; the cast picks the right declaration.
    MTLRenderPipelineColorAttachmentDescriptorArray *copied = [(MTLRenderPipelineDescriptor *)copy colorAttachments];
    for (NSUInteger i = 1; i < 8; i++) copied[i].pixelFormat = MTLPixelFormatInvalid;
    if (!atomic_exchange(&reported, true)) {
        fprintf(stderr, "PortnautMetalShim: dropped extra render targets from a dual-source blending pipeline, as Direct3D 11 does\n");
    }
    return copy;
}

static id renderPipeline(id device, SEL cmd, MTLRenderPipelineDescriptor *descriptor, MTLPipelineOption options, id *reflection, NSError **error) {
    id fixed = corrected(descriptor, descriptor.colorAttachments);
    return ((PipelineIMP)originalRender)(device, cmd, fixed ?: descriptor, options, reflection, error);
}

static id meshPipeline(id device, SEL cmd, MTLMeshRenderPipelineDescriptor *descriptor, MTLPipelineOption options, id *reflection, NSError **error) {
    id fixed = corrected(descriptor, descriptor.colorAttachments);
    return ((PipelineIMP)originalMesh)(device, cmd, fixed ?: descriptor, options, reflection, error);
}

// MARK: - Presentation: latency trace and frame queue

enum { kFrameInterval, kPresentToScreen, kPresentToRelease, kDrawableWait, kInputAge, kMetricCount };
enum { kMaxSamples = 4096 };
static const double kReportInterval = 5.0;

static BOOL traceEnabled;
static NSUInteger frameQueue;  // 0 keeps Metal's default of three drawables
static os_unfair_lock statsLock = OS_UNFAIR_LOCK_INIT;
static double samples[kMetricCount][kMaxSamples];
static int sampleCount[kMetricCount];
static double windowStart, lastPresent, gpuBusy;
static int presents, droppedFrames;
static IMP originalPresent, originalPresentAfter, originalCommit, originalSendEvent, originalNextDrawable;

/// Seconds on the clock NSEvent.timestamp and MTLDrawable.presentedTime use.
static double now(void) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

static void addSample(int metric, double seconds) {
    os_unfair_lock_lock(&statsLock);
    if (sampleCount[metric] < kMaxSamples) samples[metric][sampleCount[metric]++] = seconds;
    os_unfair_lock_unlock(&statsLock);
}

static int compareDoubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/// Milliseconds at percentile p of a sorted sample array.
static double percentileMs(const double *sorted, int count, double p) {
    return count ? sorted[(int)(p * (count - 1) + 0.5)] * 1000 : 0;
}

/// Prints one summary line per interval, from the presenting thread. The copies are static
/// rather than on that thread's stack; reportLock keeps two presenting threads from sharing them.
static void reportIfDue(double time) {
    static double copies[kMetricCount][kMaxSamples];
    static os_unfair_lock reportLock = OS_UNFAIR_LOCK_INIT;
    int counts[kMetricCount];
    if (!os_unfair_lock_trylock(&reportLock)) return;
    os_unfair_lock_lock(&statsLock);
    if (!windowStart) windowStart = time;
    double elapsed = time - windowStart;
    if (elapsed < kReportInterval) { os_unfair_lock_unlock(&statsLock); os_unfair_lock_unlock(&reportLock); return; }
    for (int m = 0; m < kMetricCount; m++) {
        counts[m] = sampleCount[m];
        memcpy(copies[m], samples[m], sizeof(double) * counts[m]);
        sampleCount[m] = 0;
    }
    int framePresents = presents, dropped = droppedFrames;
    double busy = gpuBusy;
    presents = droppedFrames = 0;
    gpuBusy = 0;
    windowStart = time;
    os_unfair_lock_unlock(&statsLock);

    for (int m = 0; m < kMetricCount; m++) qsort(copies[m], counts[m], sizeof(double), compareDoubles);
    const double *frame = copies[kFrameInterval], *screen = copies[kPresentToScreen], *release = copies[kPresentToRelease];
    const double *wait = copies[kDrawableWait], *input = copies[kInputAge];
    fprintf(stderr,
            "PortnautLatency: fps %.1f | frame ms p50 %.1f p95 %.1f | present to screen ms p50 %.1f p95 %.1f (%d frames without a screen time)"
            " | present to release ms p50 %.1f p95 %.1f | drawable wait ms p50 %.2f p95 %.2f | GPU %.1f ms/frame, %.0f%% busy"
            " | input age ms p50 %.1f p95 %.1f max %.1f (%d events) | frame queue %s\n",
            framePresents / elapsed, percentileMs(frame, counts[kFrameInterval], 0.5), percentileMs(frame, counts[kFrameInterval], 0.95),
            percentileMs(screen, counts[kPresentToScreen], 0.5), percentileMs(screen, counts[kPresentToScreen], 0.95), dropped,
            percentileMs(release, counts[kPresentToRelease], 0.5), percentileMs(release, counts[kPresentToRelease], 0.95),
            percentileMs(wait, counts[kDrawableWait], 0.5), percentileMs(wait, counts[kDrawableWait], 0.95),
            framePresents ? busy / framePresents * 1000 : 0, busy / elapsed * 100,
            percentileMs(input, counts[kInputAge], 0.5), percentileMs(input, counts[kInputAge], 0.95), percentileMs(input, counts[kInputAge], 1.0),
            counts[kInputAge], frameQueue ? "2" : "default");
    os_unfair_lock_unlock(&reportLock);
}

/// Once per process: the layer settings of a drawable Metal gave no screen time, so session.log
/// shows why. AC III's layer under Wine reports none, while a plain window's layer does.
static void describeLayerOnce(id drawable) {
    static atomic_bool described;
    if (atomic_exchange(&described, true) || ![drawable respondsToSelector:@selector(layer)]) return;
    id layer = ((id (*)(id, SEL))objc_msgSend)(drawable, @selector(layer));
    if (!layer) return;
    BOOL (*flag)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    fprintf(stderr, "PortnautLatency: no screen time for %s; presentsWithTransaction %d displaySyncEnabled %d maximumDrawableCount %lu opaque %d\n",
            class_getName(object_getClass(layer)), flag(layer, @selector(presentsWithTransaction)), flag(layer, @selector(displaySyncEnabled)),
            ((NSUInteger (*)(id, SEL))objc_msgSend)(layer, @selector(maximumDrawableCount)), flag(layer, @selector(isOpaque)));
}

/// Present time is when DXMT encodes the present, which can trail the game's Present() by up to one frame.
/// Metal calls the presented handler once the drawable is on screen or released; the release time is
/// measured too because some layers report no screen time.
static void notePresent(id<MTLDrawable> drawable) {
    double time = now();
    os_unfair_lock_lock(&statsLock);
    if (lastPresent) {
        double interval = time - lastPresent;
        if (interval < 1 && sampleCount[kFrameInterval] < kMaxSamples) samples[kFrameInterval][sampleCount[kFrameInterval]++] = interval;
    }
    lastPresent = time;
    presents++;
    os_unfair_lock_unlock(&statsLock);
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        addSample(kPresentToRelease, now() - time);
        double presented = shown.presentedTime;
        if (presented > 0) addSample(kPresentToScreen, presented - time);
        else {
            os_unfair_lock_lock(&statsLock); droppedFrames++; os_unfair_lock_unlock(&statsLock);
            describeLayerOnce(shown);
        }
    }];
    reportIfDue(time);
}

static void hookedPresent(id buffer, SEL cmd, id drawable) {
    notePresent(drawable);
    ((void (*)(id, SEL, id))originalPresent)(buffer, cmd, drawable);
}

static void hookedPresentAfter(id buffer, SEL cmd, id drawable, CFTimeInterval duration) {
    notePresent(drawable);
    ((void (*)(id, SEL, id, CFTimeInterval))originalPresentAfter)(buffer, cmd, drawable, duration);
}

/// GPU time of every command buffer; summed per interval, so overlapping work counts twice.
static void hookedCommit(id buffer, SEL cmd) {
    [(id<MTLCommandBuffer>)buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
        double gpu = done.GPUEndTime - done.GPUStartTime;
        if (gpu > 0 && gpu < 1) { os_unfair_lock_lock(&statsLock); gpuBusy += gpu; os_unfair_lock_unlock(&statsLock); }
    }];
    ((void (*)(id, SEL))originalCommit)(buffer, cmd);
}

/// Replaces CAMetalLayer's own nextDrawable only. Wine's WineMetalLayer overrides nextDrawable and
/// calls super, so every layer arrives here exactly once. Hooking the subclass too made that super
/// call re-enter the hook and recurse until the stack overflowed (Portnaut 0.1.4: black screen).
static id hookedNextDrawable(id layer, SEL cmd) {
    if (frameQueue && ((NSUInteger (*)(id, SEL))objc_msgSend)(layer, @selector(maximumDrawableCount)) != frameQueue) {
        // DXMT sets layer properties on the main thread; do the same. Applies from the next frame.
        id retained = [layer retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(retained, @selector(setMaximumDrawableCount:), frameQueue);
            [retained release];
        });
    }
    double start = now();
    id drawable = ((id (*)(id, SEL))originalNextDrawable)(layer, cmd);
    if (traceEnabled) addSample(kDrawableWait, now() - start);
    return drawable;
}

/// Age of each mouse or key event when Wine's Cocoa thread handles it. Enum values match NSEventType.
static void hookedSendEvent(id app, SEL cmd, id event) {
    NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, @selector(type));
    if (type == 1 || type == 3 || type == 5 || type == 6 || type == 7 || type == 10 || type == 27) {
        double age = now() - ((double (*)(id, SEL))objc_msgSend)(event, @selector(timestamp));
        if (age >= 0 && age < 5) addSample(kInputAge, age);
    }
    ((void (*)(id, SEL, id))originalSendEvent)(app, cmd, event);
}

/// The method defined on CAMetalLayer itself, never one inherited or a subclass override.
static Method ownMethod(Class cls, SEL selector) {
    Method found = NULL;
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned m = 0; m < count && !found; m++) if (method_getName(methods[m]) == selector) found = methods[m];
    free(methods);
    return found;
}

/// Runs once, and only when tracing or the frame queue is requested; the default path is the
/// pipeline fix alone. CAMetalLayer and AppKit are loaded in the processes that create a device.
static void installPresentation(id<MTLDevice> device) {
    @autoreleasepool {
        id<MTLCommandQueue> queue = [device newCommandQueue];
        Class bufferClass = object_getClass([queue commandBuffer]);
        [queue release];
        if (traceEnabled && bufferClass) {
            Method present = class_getInstanceMethod(bufferClass, @selector(presentDrawable:));
            Method presentAfter = class_getInstanceMethod(bufferClass, @selector(presentDrawable:afterMinimumDuration:));
            Method commit = class_getInstanceMethod(bufferClass, @selector(commit));
            if (present) originalPresent = method_setImplementation(present, (IMP)hookedPresent);
            if (presentAfter) originalPresentAfter = method_setImplementation(presentAfter, (IMP)hookedPresentAfter);
            if (commit) originalCommit = method_setImplementation(commit, (IMP)hookedCommit);
            Method sendEvent = class_getInstanceMethod(objc_getClass("WineApplication"), @selector(sendEvent:));
            if (sendEvent) originalSendEvent = method_setImplementation(sendEvent, (IMP)hookedSendEvent);
        }
        Class layerClass = objc_getClass("CAMetalLayer");
        Method nextDrawable = layerClass ? ownMethod(layerClass, @selector(nextDrawable)) : NULL;
        if (nextDrawable) originalNextDrawable = method_setImplementation(nextDrawable, (IMP)hookedNextDrawable);
    }
}

/// Replaces the two pipeline methods DXMT uses on the device's class. Apple Silicon has one GPU class.
static void install(id<MTLDevice> device) {
    if (!device) return;
    Class cls = object_getClass(device);
    BOOL first = NO;
    os_unfair_lock_lock(&installLock);
    BOOL done = NO;
    for (int i = 0; i < 4 && !done; i++) {
        if (installedClasses[i] == cls) done = YES;
        else if (!installedClasses[i]) {
            Method render = class_getInstanceMethod(cls, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:));
            Method mesh = class_getInstanceMethod(cls, @selector(newRenderPipelineStateWithMeshDescriptor:options:reflection:error:));
            if (render && !originalRender) originalRender = method_setImplementation(render, (IMP)renderPipeline);
            if (mesh && !originalMesh) originalMesh = method_setImplementation(mesh, (IMP)meshPipeline);
            first = i == 0;
            installedClasses[i] = cls;
            done = YES;
        }
    }
    os_unfair_lock_unlock(&installLock);
    if (first) {
        const char *trace = getenv("PORTNAUT_LATENCY_TRACE"), *queue = getenv("PORTNAUT_FRAME_QUEUE");
        traceEnabled = trace && strcmp(trace, "1") == 0;
        frameQueue = queue && strcmp(queue, "2") == 0 ? 2 : 0;
        if (traceEnabled || frameQueue) installPresentation(device);
        fprintf(stderr, "PortnautMetalShim: active; latency trace %s; frame queue %s\n", traceEnabled ? "on" : "off", frameQueue ? "2" : "default");
    }
}

static NSArray<id<MTLDevice>> *portnautCopyAllDevices(void) {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    for (id<MTLDevice> device in devices) install(device);
    return devices;
}

static id<MTLDevice> portnautCreateSystemDefaultDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    install(device);
    return device;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } interposers[] = {
    { (const void *)portnautCopyAllDevices, (const void *)MTLCopyAllDevices },
    { (const void *)portnautCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice },
};
