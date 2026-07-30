// vkcapture-consumer — consume the obs-vkcapture Vulkan layer and encode to mp4.
//
// Captures cs2's frames inside its Vulkan present instead of reading them back
// through the X server (which serialized with cs2's render and stalled it). The
// obs-vkcapture LAYER (loaded into cs2 via OBS_VKCAPTURE=1) hooks
// vkQueuePresentKHR, copies the swapchain image into a shared host-visible dmabuf,
// and offers it over a unix socket. This program binds that socket, mmaps the
// shared image, and feeds frames into our GStreamer NVENC pipeline — nothing
// touches the X server, so it can't stall cs2's render.
//
// PROTOCOL (vendored in capture.h, from nowrep/obs-vkcapture, GPLv2):
//   - We are the SERVER: bind abstract socket "\0/com/obsproject/vkcapture",
//     listen()/accept4(). The layer is the client and retries connect() every 1s,
//     so starting this consumer per-segment (after cs2 is up) is fine.
//   - On connect the layer sends capture_client_data{exe}; we reply with
//     capture_control_data{capturing=1, linear, map_host} to make it start.
//   - It then sends capture_texture_data{w,h,fourcc,strides,offsets,flip} + the
//     dmabuf fd via SCM_RIGHTS, ONCE per swapchain (not per frame). We mmap it and
//     sample asynchronously on a fps timer.
//
// USAGE:
//   vkcapture-consumer '<gstreamer pipeline with appsrc name=vksrc>'
//     Feeds cs2 frames into the appsrc named "vksrc"; finalizes the mp4 on SIGINT
//     (clean whole-pipeline EOS — same contract as stop_clip_capture).
//   VKCAP_TEST=1 vkcapture-consumer
//     Debug: no encode — logs each frame's geometry (fourcc/modifier/nfd), dumps
//     one raw frame to $VKCAP_TEST_DUMP (default /tmp/vkcap-frame.raw), and exits
//     after VKCAP_TEST_SECS (default 15s). Run with cs2 up under OBS_VKCAPTURE=1.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/eventfd.h>
#include <stdint.h>
#include <immintrin.h>   // MOVNTDQA streaming loads for write-combined GPU memory
#include <glib.h>
#include <glib-unix.h>
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/allocators/allocators.h>   // GstDmaBufAllocator — zero-copy dmabuf wrap
#include <gst/video/video.h>             // GstVideoMeta — stride/offset on the dmabuf

#include "capture.h"

static const char SOCK_NAME[] = "/com/obsproject/vkcapture";

// ---- runtime state --------------------------------------------------------
struct state {
    GMainLoop *loop;
    int        listen_fd;
    int        client_fd;        // the connected layer, or -1
    guint      listen_src;
    guint      client_src;
    guint      tick_src;         // fps sampling timer

    bool       test_mode;
    int        test_frames_left;
    const char *test_dump_path;

    // current shared frame geometry (from the latest capture_texture_data)
    bool       have_frame;
    int        width, height;
    uint32_t   fourcc;
    uint64_t   modifier;
    int        strides[4];
    int        offsets[4];
    int        nfd;
    int        fds[4];           // dmabuf fds we own (close on replace/exit)
    bool       flip;

    // mmap of fds[0] (the host-visible shared image)
    void      *map_ptr;
    size_t     map_len;

    // zero-copy: when set (VKCAP_ZEROCOPY=1), the layer hands us a DEVICE-LOCAL
    // dmabuf (map_host=0) and we wrap its fd straight into a GstBuffer for
    // `cudaupload` to import on the GPU — no host map, no CPU pixel copy, no PCIe
    // readback. Off (default): the host-mapped wc_copy path below. Auto-disabled at
    // runtime if the layer reports a flipped image (can't cheaply GPU-flip a dmabuf).
    bool        zerocopy;
    GstAllocator *dmabuf_alloc;  // shared GstDmaBufAllocator for the wrapped fds

    // gstreamer
    GstElement *pipeline;
    GstAppSrc  *appsrc;
    bool        caps_set;
    bool        playing;         // pipeline moved to PLAYING (on first frame)
    int         fps;
    guint64     frame_no;
    GstBuffer  *last_buf;        // last good frame, repeated while the layer is
                                 // gone (cs2 swapchain rebuild on seek) so the
                                 // stream holds instead of dying
    bool        hold_black;      // VKCAP_BLACK_HOLD: repeat last frame over a demo-
                                 // seek reload's black frame instead of flashing black
    int         black_held;      // consecutive black frames held (capped)

    // present-lock: an eventfd we hand the (patched) layer via SCM_RIGHTS; it
    // pokes it on every vkQueuePresentKHR, so we push exactly one frame per
    // present with deterministic CFR PTS. Until the first poke we stay on the fps
    // timer (works with any/unpatched layer), then disarm it.
    int         present_efd;
    guint       present_src;
    bool        present_locked;   // engaged: presents drive the push, timer off
    guint64     present_signals;  // VKCAP_DEBUG: total presents seen
    guint64     dbg_last;         // VKCAP_DEBUG: present_signals at last debug tick
    bool        debug;

    // optional HUD-overlay toggle (composite mode): poll VKCAP_HUD_CTL and
    // set the compositor's HUD pad alpha, so the operator can hide/show the
    // overlay without unmapping the grabbed window (which would break the
    // ximagesrc xid grab). NULL pad => feature inactive.
    GstPad     *hud_pad;
    char       *hud_ctl_path;
    int         hud_visible;      // last applied (1 visible / 0 hidden)

    // VKCAP_READY_FILE: touched the instant the shared texture is mapped, i.e. the
    // consumer is ARMED and one gate-open away from recording. The caller starts the
    // demo playing only once this exists — the layer retries connect() on a 1s
    // cadence, so a fresh consumer can be several hundred ms from recording anything,
    // and anything played before then is simply not in the mp4.
    char       *ready_path;
    bool        ready_signalled;
    bool        pushed_first;

    // VKCAP_START_FILE: when set, an armed consumer holds the pipeline in READY —
    // discarding cs2's frames — until this file appears. The clip renderer opens the
    // gate once the demo is confirmed MOVING, so the mp4 doesn't open on the held
    // paused frame. Unset => arm and record immediately (old behaviour).
    char       *start_path;
    bool        started;
    gint64      armed_us;         // g_get_monotonic_time() when we armed
    int         start_timeout_ms; // open the gate anyway after this (0 = never)
};

static struct state st = { .listen_fd = -1, .client_fd = -1, .present_efd = -1 };

// ---- fourcc -> GStreamer format ------------------------------------------
// DRM fourccs are little-endian byte order in memory; map to the matching gst
// raw format. CS2's swapchain is almost certainly XRGB/ARGB8888 (BGRx/BGRA).
// Alpha is mapped to the opaque (x) sibling on purpose: cs2 drives the swapchain
// alpha to 0 during a flashbang, so honoring it makes `compositor background=black`
// paint the whole frame black on every flash (OBS's "Allow Transparency = OFF").
static const char *fourcc_to_gst(uint32_t f)
{
    switch (f) {
    case DRM_FORMAT_XRGB8888:
    case DRM_FORMAT_ARGB8888: return "BGRx";
    case DRM_FORMAT_XBGR8888:
    case DRM_FORMAT_ABGR8888: return "RGBx";
    default:                  return NULL;
    }
}

// Same mapping as fourcc_to_gst but to the GstVideoFormat enum, for the
// GstVideoMeta we attach to zero-copy dmabuf buffers (stride/offset metadata).
static GstVideoFormat fourcc_to_gst_vfmt(uint32_t f)
{
    switch (f) {
    case DRM_FORMAT_XRGB8888:
    case DRM_FORMAT_ARGB8888: return GST_VIDEO_FORMAT_BGRx;
    case DRM_FORMAT_XBGR8888:
    case DRM_FORMAT_ABGR8888: return GST_VIDEO_FORMAT_RGBx;
    default:                  return GST_VIDEO_FORMAT_UNKNOWN;
    }
}

static void fourcc_str(uint32_t f, char out[5])
{
    out[0] = (char)(f & 0xff);
    out[1] = (char)((f >> 8) & 0xff);
    out[2] = (char)((f >> 16) & 0xff);
    out[3] = (char)((f >> 24) & 0xff);
    out[4] = '\0';
}

static void log_msg(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[vkcap] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    fflush(stderr);
}

// ---- frame buffer teardown -----------------------------------------------
static void release_frame(void)
{
    if (st.map_ptr) { munmap(st.map_ptr, st.map_len); st.map_ptr = NULL; st.map_len = 0; }
    for (int i = 0; i < st.nfd; i++) {
        if (st.fds[i] >= 0) { close(st.fds[i]); st.fds[i] = -1; }
    }
    st.nfd = 0;
    st.have_frame = false;
}

// Reject bogus geometry off the wire before it feeds size math / memcpy, so a
// garbage frame can't overflow an allocation or read out of bounds.
#define VKCAP_MAX_DIM   16384
#define VKCAP_MAX_BYTES (256u * 1024 * 1024)
static bool geometry_ok(const struct capture_texture_data *td, int nfd)
{
    if (nfd < 1) return false;
    if (td->width  <= 0 || td->width  > VKCAP_MAX_DIM) return false;
    if (td->height <= 0 || td->height > VKCAP_MAX_DIM) return false;
    if (td->strides[0] < td->width * 4 || td->offsets[0] < 0) return false;
    int64_t bytes = (int64_t)td->strides[0] * td->height + td->offsets[0];
    return bytes > 0 && bytes <= VKCAP_MAX_BYTES;
}

// ---- control: tell the layer to start producing --------------------------
// Default: request a LINEAR, host-visible, no-modifier dmabuf so we can mmap +
// memcpy it with the CPU. Zero-copy (st.zerocopy): request map_host=0 so the
// shared image stays DEVICE-LOCAL — we wrap its fd into a GstBuffer for cudaupload
// to import on the GPU, so the CPU never touches a pixel. Still LINEAR + no
// modifiers (keeps the consumer's video-meta simple; the layer's per-present blit
// into the shared image is inherent either way). (device_uuid left zero — single
// GPU; the layer allocates on its own device.)
static void send_control(int fd, bool capturing)
{
    struct capture_control_data c = {0};
    c.capturing    = capturing ? 1 : 0;
    c.no_modifiers = 1;
    c.linear       = 1;
    c.map_host     = st.zerocopy ? 0 : 1;

    // Ask the layer to poke us per present, handing it our eventfd via SCM_RIGHTS.
    // A patched layer reads want_present_signal + the fd; an unpatched layer treats
    // both as padding and ignores them — we stay on the fps timer (graceful).
    if (capturing && st.present_efd >= 0)
        c.want_present_signal = 1;

    struct iovec io = { .iov_base = &c, .iov_len = sizeof(c) };
    struct msghdr msg = {0};
    msg.msg_iov = &io;
    msg.msg_iovlen = 1;
    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    if (c.want_present_signal) {
        msg.msg_control = cmsg_buf;
        msg.msg_controllen = sizeof(cmsg_buf);
        struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type  = SCM_RIGHTS;
        cm->cmsg_len   = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &st.present_efd, sizeof(int));
        msg.msg_controllen = cm->cmsg_len;
    }

    ssize_t n = sendmsg(fd, &msg, MSG_NOSIGNAL);
    if (n != (ssize_t)sizeof(c))
        log_msg("WARN: send_control short write (%zd/%zu): %s", n, sizeof(c), strerror(errno));
}

// ---- push one sampled frame into the pipeline ----------------------------
static void set_caps_if_needed(void)
{
    if (st.caps_set) return;
    const char *gfmt = fourcc_to_gst(st.fourcc);
    if (!gfmt) {
        char fs[5]; fourcc_str(st.fourcc, fs);
        log_msg("ERROR: unsupported fourcc '%s' (0x%08x) — add it to fourcc_to_gst", fs, st.fourcc);
        gfmt = "BGRx"; // best guess so we at least produce something
    }
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "format",    G_TYPE_STRING, gfmt,
        "width",     G_TYPE_INT, st.width,
        "height",    G_TYPE_INT, st.height,
        "framerate", GST_TYPE_FRACTION, st.fps, 1,
        NULL);
    // Zero-copy: tag the caps with the DMABuf memory feature so downstream
    // negotiates the dmabuf import (cudaupload) instead of expecting system memory.
    if (st.zerocopy)
        gst_caps_set_features_simple(caps, gst_caps_features_new("memory:DMABuf", NULL));
    gst_app_src_set_caps(st.appsrc, caps);
    gst_caps_unref(caps);
    st.caps_set = true;
    log_msg("appsrc caps: %s %dx%d @%dfps (stride0=%d flip=%d%s)",
            gfmt, st.width, st.height, st.fps, st.strides[0], st.flip,
            st.zerocopy ? " memory:DMABuf zero-copy" : "");
}

// Streaming-load (MOVNTDQA) copy for the layer's write-combined GPU buffer:
// cached loads off WC memory crawl (~1GB/s) and pegged a core; MOVNTDQA reads it
// near DRAM speed. Needs 16-byte-aligned src; sse4.1 gated at the caller.
__attribute__((target("sse4.1")))
static void wc_memcpy_sse41(uint8_t *dst, const uint8_t *src, size_t n)
{
    size_t i = 0;
    for (; i + 64 <= n; i += 64) {
        __m128i a = _mm_stream_load_si128((const __m128i *)(src + i));
        __m128i b = _mm_stream_load_si128((const __m128i *)(src + i + 16));
        __m128i c = _mm_stream_load_si128((const __m128i *)(src + i + 32));
        __m128i d = _mm_stream_load_si128((const __m128i *)(src + i + 48));
        _mm_storeu_si128((__m128i *)(dst + i),      a);
        _mm_storeu_si128((__m128i *)(dst + i + 16), b);
        _mm_storeu_si128((__m128i *)(dst + i + 32), c);
        _mm_storeu_si128((__m128i *)(dst + i + 48), d);
    }
    for (; i + 16 <= n; i += 16) {
        __m128i v = _mm_stream_load_si128((const __m128i *)(src + i));
        _mm_storeu_si128((__m128i *)(dst + i), v);
    }
    _mm_sfence();
    if (i < n) memcpy(dst + i, src + i, n - i);  // unaligned tail (rare)
}

// Copy from the WC GPU mapping: streaming-load path when SSE4.1 + aligned, else
// plain memcpy.
static void wc_copy(void *dst, const void *src, size_t n)
{
    static int sse41 = -1;
    if (sse41 < 0) sse41 = __builtin_cpu_supports("sse4.1");
    if (sse41 && (((uintptr_t)src & 15u) == 0))
        wc_memcpy_sse41((uint8_t *)dst, (const uint8_t *)src, n);
    else
        memcpy(dst, src, n);
}

// Detect a (near-)black frame — the reload frame cs2 briefly presents on a demo
// seek. Reads the just-copied SYSTEM buffer (fast; never the write-combined GPU
// map). Strided sample (~every 128px); "lit" = any BGR channel clearly non-zero.
// Tight threshold so dark gameplay (which still has lit pixels) is NOT black.
static bool frame_is_black(const uint8_t *p, int stride, int height)
{
    const size_t sz = (size_t)stride * (size_t)height;
    uint64_t lit = 0, n = 0;
    for (size_t i = 0; i + 3 < sz; i += 512) {   // 512 % 4 == 0 → stays pixel-aligned
        if (p[i] > 16 || p[i + 1] > 16 || p[i + 2] > 16) lit++;
        n++;
    }
    return n > 0 && (lit * 1000) < n;            // < 0.1% of sampled pixels lit
}

// Armed: the shared texture is mapped and frames are arriving, so the caller can
// safely start the demo — the only thing left is opening the start gate.
static void signal_armed(void)
{
    if (st.ready_signalled) return;
    st.ready_signalled = true;
    st.armed_us = g_get_monotonic_time();
    if (st.ready_path) {
        FILE *f = fopen(st.ready_path, "w");
        if (f) {
            fclose(f);
        } else {
            log_msg("WARN: could not write ready file %s: %s", st.ready_path, strerror(errno));
        }
    }
    log_msg("armed%s", st.start_path ? " — holding for start gate" : "");
}

// True once the pipeline is allowed to record. Without VKCAP_START_FILE that is
// immediately; with it, when the renderer touches the file (or the timeout fires,
// so a renderer that never opens the gate degrades to a late clip, not an empty one).
static bool start_gate_open(void)
{
    if (st.started) return true;
    if (!st.start_path) { st.started = true; return true; }
    if (st.armed_us == 0) st.armed_us = g_get_monotonic_time();
    const gint64 waited_ms = (g_get_monotonic_time() - st.armed_us) / 1000;
    if (access(st.start_path, F_OK) == 0) {
        st.started = true;
        log_msg("start gate opened after %" G_GINT64_FORMAT "ms armed — recording", waited_ms);
    } else if (st.start_timeout_ms > 0 && waited_ms >= st.start_timeout_ms) {
        st.started = true;
        log_msg("WARN: start gate never opened within %dms — recording anyway", st.start_timeout_ms);
    }
    return st.started;
}

// Build a buffer from the current shared frame (or repeat the last good frame
// while the layer is transiently gone) and push it into the pipeline. Shared by
// the fps timer (on_tick) and the per-present signal (on_present_signal).
// Returns false to stop the main loop.
static bool push_one_frame(void)
{
    if (!st.appsrc) return true;
    // Hold in READY until we have a frame AND the gate is open, then go PLAYING so
    // the pulsesrc audio starts in lockstep with the first recorded video frame.
    if (!st.playing) {
        if (!st.have_frame || !start_gate_open()) return true;
        gst_element_set_state(st.pipeline, GST_STATE_PLAYING);
        st.playing = true;
        return true;   // push from the next tick/present, as before
    }

    GstBuffer *out = NULL;

    if (st.have_frame && st.zerocopy && st.fds[0] >= 0) {
        // Zero-copy: wrap the device-local dmabuf fd straight into a GstBuffer.
        // dup() because the dmabuf allocator takes ownership of the fd it's given
        // and closes it when the buffer is released — we keep st.fds[0] alive for
        // the swapchain's lifetime. cudaupload downstream imports + GPU-copies it;
        // the CPU never maps the pixels. (Single shared image, overwritten on the
        // next present — same one-texture model as obs-vkcapture itself; present-
        // lock pushes right after a present so the import wins the race.)
        set_caps_if_needed();
        int dfd = dup(st.fds[0]);
        if (dfd < 0) return true;  // transient; next present re-pushes
        const gsize sz = (gsize)st.strides[0] * (gsize)st.height + (gsize)st.offsets[0];
        GstMemory *mem = gst_dmabuf_allocator_alloc(st.dmabuf_alloc, dfd, sz);
        if (!mem) { close(dfd); return true; }
        GstBuffer *buf = gst_buffer_new();
        gst_buffer_append_memory(buf, mem);  // takes the dfd-owning memory
        GstVideoFormat vfmt = fourcc_to_gst_vfmt(st.fourcc);
        if (vfmt == GST_VIDEO_FORMAT_UNKNOWN) vfmt = GST_VIDEO_FORMAT_BGRx;
        gsize off[GST_VIDEO_MAX_PLANES] = { (gsize)st.offsets[0], 0, 0, 0 };
        gint  strd[GST_VIDEO_MAX_PLANES] = { st.strides[0], 0, 0, 0 };
        gst_buffer_add_video_meta_full(buf, GST_VIDEO_FRAME_FLAG_NONE, vfmt,
                                       st.width, st.height, 1, off, strd);
        out = buf;  // push (transfers ownership)
    } else if (st.have_frame && st.map_ptr) {
        set_caps_if_needed();

        // Copy the shared host-mapped image into a fresh buffer (the layer
        // overwrites it on cs2's next present). Single plane assumed.
        const size_t row = (size_t)st.strides[0];
        const size_t sz  = row * (size_t)st.height;
        GstBuffer *buf = gst_buffer_new_allocate(NULL, sz, NULL);
        GstMapInfo mi;
        if (!gst_buffer_map(buf, &mi, GST_MAP_WRITE)) { gst_buffer_unref(buf); return true; }

        const uint8_t *src = (const uint8_t *)st.map_ptr + st.offsets[0];
        if (st.flip) {
            for (int y = 0; y < st.height; y++)   // bottom-up -> top-down
                wc_copy(mi.data + (size_t)y * row, src + (size_t)(st.height - 1 - y) * row, row);
        } else {
            wc_copy(mi.data, src, sz);
        }
        // Seek/reload black-frame hold: a demo seek makes cs2 present a pure-black
        // reload frame. Detect it (fast read of the just-copied SYSTEM buffer) and
        // repeat the last good frame instead, so a seek shows a brief hold→new-view
        // rather than a black flash. Capped (~3s) so a genuinely black scene isn't
        // frozen forever. Checked while still mapped.
        bool black = st.hold_black && st.last_buf
                     && frame_is_black(mi.data, st.strides[0], st.height);
        gst_buffer_unmap(buf, &mi);

        if (black && st.black_held < st.fps * 3) {
            st.black_held++;
            gst_buffer_unref(buf);
            out = gst_buffer_ref(st.last_buf);   // hold last good frame over the reload
        } else {
            st.black_held = 0;
            // Keep this as the "last good frame" to repeat if the layer blips.
            if (st.last_buf) gst_buffer_unref(st.last_buf);
            st.last_buf = gst_buffer_ref(buf);
            out = buf;  // push (transfers ownership)
        }
    } else if (st.last_buf) {
        // Layer transiently gone (cs2 swapchain rebuild on seek): repeat the last
        // frame so the stream holds instead of dying + tripping client reconnects.
        out = gst_buffer_ref(st.last_buf);
    } else {
        return true;  // nothing captured yet
    }

    // PTS is stamped by appsrc (do-timestamp=TRUE); downstream videorate locks CFR.
    // Present-driven pushing feeds videorate distinct, render-aligned frames, so it
    // corrects only on a real cs2 frame dip (not timer phase-drift dups). Video
    // rides the same live clock as the pulsesrc audio, so A/V stays synced and the
    // clip's duration always matches wall-clock (no time-compression).
    GstFlowReturn fr = gst_app_src_push_buffer(st.appsrc, out); // takes ownership
    if (fr != GST_FLOW_OK) {
        log_msg("appsrc push returned %d — stopping", fr);
        g_main_loop_quit(st.loop);
        return false;
    }
    if (!st.pushed_first) { st.pushed_first = true; log_msg("first frame pushed — recording"); }
    return true;
}

static gboolean on_tick(gpointer user)
{
    (void)user;
    if (st.present_locked) return G_SOURCE_REMOVE;  // presents drive the push now
    return push_one_frame() ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

// First present poke from a patched layer: switch from the wall-clock timer to
// present-driven, deterministic-CFR pushing.
static void engage_present_lock(void)
{
    if (st.present_locked) return;
    st.present_locked = true;
    // Presents now drive the push; drop the wall-clock sampler. Timestamping stays
    // on do-timestamp + videorate (A/V-safe; duration tracks wall-clock even if cs2
    // dips below fps_max). Sampling is what we lock to the render, not the clock.
    if (st.tick_src) { g_source_remove(st.tick_src); st.tick_src = 0; }
    log_msg("present-lock ENGAGED (layer pokes per present; fps=%d, present-driven sampling)", st.fps);
}

// eventfd readable: the layer poked us one or more presents. Drain the counter and
// push exactly one CFR frame (fps_max==capture fps keeps the count ≈1 in steady state).
static gboolean on_present_signal(gint fd, GIOCondition cond, gpointer user)
{
    (void)user;
    if (cond & (G_IO_HUP | G_IO_ERR)) { st.present_src = 0; return G_SOURCE_REMOVE; }
    uint64_t cnt = 0;
    ssize_t n = read(fd, &cnt, sizeof(cnt));
    if (n != (ssize_t)sizeof(cnt)) return G_SOURCE_CONTINUE;  // spurious / EAGAIN
    if (!st.present_locked) engage_present_lock();
    st.present_signals += cnt;
    if (!push_one_frame()) { st.present_src = 0; return G_SOURCE_REMOVE; }
    return G_SOURCE_CONTINUE;
}

// VKCAP_DEBUG: once a second, report present rate and mode so we can confirm 1:1
// present->frame locking and spot drops.
static gboolean on_debug_tick(gpointer user)
{
    (void)user;
    guint64 d = st.present_signals - st.dbg_last;
    st.dbg_last = st.present_signals;
    log_msg("DEBUG %s: presents/s=%llu (total=%llu)",
            st.present_locked ? "present-locked" : "timer-fallback",
            (unsigned long long)d, (unsigned long long)st.present_signals);
    return G_SOURCE_CONTINUE;
}

// ---- TEST mode: log + dump one frame -------------------------------------
static void test_handle_frame(void)
{
    char fs[5]; fourcc_str(st.fourcc, fs);
    log_msg("TEXTURE #%llu: %dx%d fourcc=%s(0x%08x) modifier=0x%016llx nfd=%d "
            "stride0=%d offset0=%d flip=%d",
            (unsigned long long)st.frame_no, st.width, st.height, fs, st.fourcc,
            (unsigned long long)st.modifier, st.nfd, st.strides[0], st.offsets[0], st.flip);
    st.frame_no++;

    if (!st.map_ptr && st.nfd > 0 && st.fds[0] >= 0) {
        st.map_len = (size_t)st.strides[0] * (size_t)st.height + (size_t)st.offsets[0];
        st.map_ptr = mmap(NULL, st.map_len, PROT_READ, MAP_SHARED, st.fds[0], 0);
        if (st.map_ptr == MAP_FAILED) {
            st.map_ptr = NULL;
            log_msg("  mmap(fd0) FAILED: %s", strerror(errno));
        } else {
            log_msg("  mmap(fd0) OK (%zu bytes)", st.map_len);
            FILE *f = fopen(st.test_dump_path, "wb");
            if (f) {
                fwrite((uint8_t *)st.map_ptr + st.offsets[0], 1,
                       (size_t)st.strides[0] * (size_t)st.height, f);
                fclose(f);
                log_msg("  dumped one raw frame -> %s (%s %dx%d, view with: ffmpeg -f rawvideo "
                        "-pix_fmt bgra -s %dx%d -i %s frame.png)",
                        st.test_dump_path, fs, st.width, st.height, st.width, st.height,
                        st.test_dump_path);
            }
        }
    }

    if (--st.test_frames_left <= 0) {
        log_msg("TEST: captured enough — exiting. (host-map %s)",
                st.map_ptr ? "WORKS" : "did NOT work");
        g_main_loop_quit(st.loop);
    }
}

// ---- socket receive -------------------------------------------------------
static gboolean on_client_data(gint fd, GIOCondition cond, gpointer user)
{
    (void)user;
    if (cond & (G_IO_HUP | G_IO_ERR)) {
        log_msg("layer disconnected");
        goto drop;
    }

    uint8_t buf[CAPTURE_TEXTURE_DATA_SIZE];
    struct iovec io = { .iov_base = buf, .iov_len = sizeof(buf) };
    char cmsg_buf[CMSG_SPACE(sizeof(int)) * 4];
    struct msghdr msg = {0};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf; msg.msg_controllen = sizeof(cmsg_buf);

    ssize_t n = recvmsg(fd, &msg, MSG_NOSIGNAL);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return G_SOURCE_CONTINUE;
        log_msg("layer recvmsg ended (%zd): %s", n, n < 0 ? strerror(errno) : "eof");
        goto drop;
    }

    switch (buf[0]) {
    case CAPTURE_CLIENT_DATA_TYPE: {
        struct capture_client_data *cd = (void *)buf;
        cd->exe[sizeof(cd->exe) - 1] = '\0';
        log_msg("layer hello: exe='%s' -> capturing=1 (linear+map_host%s)", cd->exe,
                st.present_efd >= 0 ? ", requesting present-signal" : "");
        send_control(fd, true);
        break;
    }
    case CAPTURE_TEXTURE_DATA_TYPE: {
        struct capture_texture_data *td = (void *)buf;
        // collect fds passed via SCM_RIGHTS
        int got_fds[4] = {-1,-1,-1,-1};
        int nfd = 0;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
                nfd = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
                if (nfd > 4) nfd = 4;
                memcpy(got_fds, CMSG_DATA(c), nfd * sizeof(int));
                break;
            }
        }
        if (!geometry_ok(td, nfd)) {
            log_msg("ignoring texture: bad geometry %dx%d stride0=%d nfd=%d",
                    td->width, td->height, td->strides[0], nfd);
            for (int i = 0; i < nfd; i++) if (got_fds[i] >= 0) close(got_fds[i]);
            break;
        }
        // new shared texture -> drop the old mapping/fds
        release_frame();
        st.width = td->width; st.height = td->height; st.fourcc = (uint32_t)td->format;
        st.modifier = td->modifier; st.flip = td->flip != 0;
        memcpy(st.strides, td->strides, sizeof(st.strides));
        memcpy(st.offsets, td->offsets, sizeof(st.offsets));
        st.nfd = nfd;
        memcpy(st.fds, got_fds, sizeof(st.fds));
        st.caps_set = false; // geometry may have changed

        if (st.test_mode) {
            test_handle_frame();
            break;
        }
        if (st.nfd < 1 || st.fds[0] < 0) break;
        if (st.zerocopy) {
            // Zero-copy can't cheaply GPU-flip a dmabuf. If the layer reports a
            // flipped (bottom-up) image, drop back to the host-map copy path (which
            // flips per-row): clear zerocopy, re-request map_host=1, and wait for
            // the layer to reinit + resend a host-mappable texture.
            if (st.flip) {
                log_msg("WARN: layer reports flipped image — zero-copy can't GPU-flip; reverting to host-map copy");
                st.zerocopy = false;
                st.caps_set = false;
                send_control(fd, true);
                break;
            }
            // Device-local dmabuf: no host map — push_one_frame wraps the fd directly.
            st.have_frame = true;
            log_msg("shared dmabuf ready (zero-copy): %dx%d, pushing at %dfps", st.width, st.height, st.fps);
        } else {
            // host-map copy path: mmap the shared image so push_one_frame can sample it.
            st.map_len = (size_t)st.strides[0] * (size_t)st.height + (size_t)st.offsets[0];
            st.map_ptr = mmap(NULL, st.map_len, PROT_READ, MAP_SHARED, st.fds[0], 0);
            if (st.map_ptr == MAP_FAILED) {
                st.map_ptr = NULL;
                log_msg("ERROR: mmap(fd0) failed: %s", strerror(errno));
                break;
            }
            st.have_frame = true;
            log_msg("shared texture ready: %dx%d, sampling at %dfps", st.width, st.height, st.fps);
        }
        // Armed. push_one_frame flips the pipeline to PLAYING on the next tick /
        // present once the start gate is open, so audio starts with the first
        // recorded frame rather than with the layer handshake.
        signal_armed();
        break;
    }
    default:
        log_msg("unknown message type %u (%zd bytes)", buf[0], n);
        break;
    }
    return G_SOURCE_CONTINUE;

drop:
    release_frame();
    if (st.client_src) { g_source_remove(st.client_src); st.client_src = 0; }
    if (st.client_fd >= 0) { close(st.client_fd); st.client_fd = -1; }
    return G_SOURCE_REMOVE;
}

static gboolean on_listen(gint fd, GIOCondition cond, gpointer user)
{
    (void)cond; (void)user;
    int cfd = accept4(fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (cfd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) log_msg("accept4: %s", strerror(errno));
        return G_SOURCE_CONTINUE;
    }
    if (st.client_fd >= 0) { // only one game at a time
        log_msg("second client connected — ignoring (already capturing)");
        close(cfd);
        return G_SOURCE_CONTINUE;
    }
    log_msg("layer connected (fd=%d)", cfd);
    st.client_fd = cfd;
    st.client_src = g_unix_fd_add(cfd, G_IO_IN | G_IO_HUP | G_IO_ERR, on_client_data, NULL);
    return G_SOURCE_CONTINUE;
}

// ---- shutdown -------------------------------------------------------------
static gboolean on_sigint(gpointer user)
{
    (void)user;
    log_msg("SIGINT — sending EOS and finalizing");
    if (st.tick_src)    { g_source_remove(st.tick_src);    st.tick_src = 0; }
    if (st.present_src) { g_source_remove(st.present_src); st.present_src = 0; }
    if (st.pipeline && st.playing) {
        // EOS the WHOLE pipeline (same as `gst-launch -e`) so BOTH the video appsrc
        // and the audio pulsesrc branch drain into qtmux and the moov atom is
        // written — EOS-ing only appsrc would leave audio open and truncate the mp4.
        gst_element_send_event(st.pipeline, gst_event_new_eos());
        // backstop in case EOS never reaches the bus (the EOS bus handler quits too)
        g_timeout_add(5000, (GSourceFunc)g_main_loop_quit, st.loop);
    } else {
        g_main_loop_quit(st.loop);
    }
    return G_SOURCE_REMOVE;
}

static gboolean on_bus(GstBus *bus, GstMessage *m, gpointer user)
{
    (void)bus; (void)user;
    switch (GST_MESSAGE_TYPE(m)) {
    case GST_MESSAGE_EOS:
        log_msg("pipeline EOS");
        g_main_loop_quit(st.loop);
        break;
    case GST_MESSAGE_ERROR: {
        GError *e = NULL; gchar *dbg = NULL;
        gst_message_parse_error(m, &e, &dbg);
        log_msg("pipeline ERROR: %s | %s", e ? e->message : "?", dbg ? dbg : "");
        if (e) g_error_free(e); g_free(dbg);
        g_main_loop_quit(st.loop);
        break;
    }
    default: break;
    }
    return TRUE;
}

// ---- socket setup ---------------------------------------------------------
static int make_listen_socket(void)
{
    int fd = socket(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) { log_msg("socket: %s", strerror(errno)); return -1; }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_LOCAL;
    addr.sun_path[0] = '\0'; // abstract namespace
    memcpy(&addr.sun_path[1], SOCK_NAME, sizeof(SOCK_NAME) - 1);
    socklen_t len = offsetof(struct sockaddr_un, sun_path) + 1 + (sizeof(SOCK_NAME) - 1);
    if (bind(fd, (struct sockaddr *)&addr, len) < 0) {
        log_msg("bind %s: %s (another consumer/OBS already running?)", SOCK_NAME, strerror(errno));
        close(fd); return -1;
    }
    if (listen(fd, 1) < 0) { log_msg("listen: %s", strerror(errno)); close(fd); return -1; }
    return fd;
}

// HUD show/hide: read VKCAP_HUD_CTL ("1"/"0") and set the compositor HUD pad's
// alpha on change. (Unmapping the window would break the ximagesrc grab.)
static gboolean poll_hud_ctl(gpointer user)
{
    (void)user;
    if (!st.hud_pad || !st.hud_ctl_path) return G_SOURCE_REMOVE;
    FILE *f = fopen(st.hud_ctl_path, "r");
    if (!f) return G_SOURCE_CONTINUE;
    int c = fgetc(f);
    fclose(f);
    int v = (c == '0') ? 0 : (c == '1') ? 1 : st.hud_visible;
    if (v != st.hud_visible) {
        st.hud_visible = v;
        g_object_set(st.hud_pad, "alpha", v ? 1.0 : 0.0, NULL);
        log_msg("hud overlay %s (compositor alpha)", v ? "shown" : "hidden");
    }
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv)
{
    st.test_mode = getenv("VKCAP_TEST") && atoi(getenv("VKCAP_TEST")) != 0;
    st.test_dump_path = getenv("VKCAP_TEST_DUMP"); if (!st.test_dump_path) st.test_dump_path = "/tmp/vkcap-frame.raw";
    st.test_frames_left = getenv("VKCAP_TEST_FRAMES") ? atoi(getenv("VKCAP_TEST_FRAMES")) : 5;
    st.fps = getenv("VKCAP_FPS") ? atoi(getenv("VKCAP_FPS")) : 60;
    if (st.fps <= 0) st.fps = 60;
    st.debug = getenv("VKCAP_DEBUG") && atoi(getenv("VKCAP_DEBUG")) != 0;
    // Zero-copy defaults ON; only an explicit VKCAP_ZEROCOPY=0 disables it. (The
    // shell always exports an explicit value; this default is for bare manual runs.)
    { const char *z = getenv("VKCAP_ZEROCOPY"); st.zerocopy = !z || atoi(z) != 0; }
    // Black-frame hold defaults ON (host-map/composite path only — needs pixel
    // access; the zero-copy clip path doesn't read pixels). VKCAP_BLACK_HOLD=0 off.
    { const char *z = getenv("VKCAP_BLACK_HOLD"); st.hold_black = !z || atoi(z) != 0; }
    { const char *p = getenv("VKCAP_READY_FILE"); st.ready_path = (p && *p) ? (char *)p : NULL; }
    { const char *p = getenv("VKCAP_START_FILE"); st.start_path = (p && *p) ? (char *)p : NULL; }
    { const char *t = getenv("VKCAP_START_TIMEOUT_MS"); st.start_timeout_ms = t ? atoi(t) : 10000; }
    for (int i = 0; i < 4; i++) st.fds[i] = -1;

    if (!st.test_mode) {
        if (argc < 2) {
            log_msg("usage: %s '<gstreamer pipeline with appsrc name=vksrc>'   (or VKCAP_TEST=1 %s)",
                    argv[0], argv[0]);
            return 2;
        }
        gst_init(&argc, &argv);
        if (st.zerocopy) {
            st.dmabuf_alloc = gst_dmabuf_allocator_new();
            if (!st.dmabuf_alloc) {
                log_msg("WARN: gst_dmabuf_allocator_new failed — disabling zero-copy (host-map copy)");
                st.zerocopy = false;
            } else {
                log_msg("zero-copy ENABLED (device-local dmabuf import; CPU never touches pixels)");
            }
        }
        GError *err = NULL;
        // FATAL_ERRORS: a missing element must fail here so the shell falls back to
        // ximagesrc, not return a half-linked pipeline that limps to "not-linked".
        st.pipeline = gst_parse_launch_full(argv[1], NULL, GST_PARSE_FLAG_FATAL_ERRORS, &err);
        if (!st.pipeline) { log_msg("bad pipeline: %s", err ? err->message : "?"); return 2; }
        GstElement *src = gst_bin_get_by_name(GST_BIN(st.pipeline), "vksrc");
        if (!src) { log_msg("pipeline has no element named 'vksrc'"); return 2; }
        st.appsrc = GST_APP_SRC(src);
        gst_app_src_set_stream_type(st.appsrc, GST_APP_STREAM_TYPE_STREAM);
        g_object_set(src, "is-live", TRUE, "format", GST_FORMAT_TIME, "do-timestamp", TRUE, NULL);
        GstBus *bus = gst_element_get_bus(st.pipeline);
        gst_bus_add_watch(bus, on_bus, NULL);
        gst_object_unref(bus);
        // HUD toggle: grab the compositor's HUD pad (sink_1) for poll_hud_ctl,
        // when a 'comp' element + VKCAP_HUD_CTL exist.
        const char *hud_ctl = getenv("VKCAP_HUD_CTL");
        if (hud_ctl && *hud_ctl) {
            GstElement *comp = gst_bin_get_by_name(GST_BIN(st.pipeline), "comp");
            if (comp) {
                st.hud_pad = gst_element_get_static_pad(comp, "sink_1");
                gst_object_unref(comp);
                if (st.hud_pad) {
                    st.hud_ctl_path = g_strdup(hud_ctl);
                    st.hud_visible = 1;   // stream.sh seeds the file to "1"
                    log_msg("hud toggle armed (compositor sink_1 alpha <- %s)", hud_ctl);
                } else {
                    log_msg("hud toggle: compositor 'comp' has no sink_1 pad — toggle disabled");
                }
            }
        }
        // READY (not PLAYING): we flip to PLAYING when the first frame arrives, so
        // the live pulsesrc audio starts together with video (no audio lead-in).
        gst_element_set_state(st.pipeline, GST_STATE_READY);
    } else {
        log_msg("TEST mode: will log %d texture update(s), dump to %s, no encode",
                st.test_frames_left, st.test_dump_path);
    }

    st.listen_fd = make_listen_socket();
    if (st.listen_fd < 0) return 1;

    st.loop = g_main_loop_new(NULL, FALSE);
    st.listen_src = g_unix_fd_add(st.listen_fd, G_IO_IN, on_listen, NULL);
    g_unix_signal_add(SIGINT,  on_sigint, NULL);
    g_unix_signal_add(SIGTERM, on_sigint, NULL);
    if (!st.test_mode) {
        // Present-lock channel: an eventfd we hand the layer (via send_control's
        // SCM_RIGHTS). A patched layer pokes it per present -> on_present_signal
        // engages present-lock and disarms the timer below. Unpatched layer never
        // pokes -> timer path runs unchanged.
        st.present_efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        if (st.present_efd < 0)
            log_msg("WARN: eventfd failed (%s) — present-lock off, fps timer only", strerror(errno));
        else
            st.present_src = g_unix_fd_add(st.present_efd, G_IO_IN | G_IO_ERR, on_present_signal, NULL);

        guint interval_ms = (guint)(1000 / st.fps);
        if (interval_ms < 1) interval_ms = 1;   // clamp: absurd VKCAP_FPS -> 0 -> busy loop
        st.tick_src = g_timeout_add(interval_ms, on_tick, NULL);
        if (st.hud_pad) g_timeout_add(250, poll_hud_ctl, NULL);
        if (st.debug)   g_timeout_add_seconds(1, on_debug_tick, NULL);
    } else {
        // TEST mode always terminates: the layer may send texture metadata only
        // ONCE (then you sample asynchronously), so don't rely on the frame count.
        guint secs = getenv("VKCAP_TEST_SECS") ? (guint)atoi(getenv("VKCAP_TEST_SECS")) : 15;
        g_timeout_add_seconds(secs, (GSourceFunc)g_main_loop_quit, st.loop);
    }

    log_msg("listening on %s (test=%d fps=%d) — waiting for cs2's vkcapture layer",
            SOCK_NAME, st.test_mode, st.fps);
    g_main_loop_run(st.loop);

    // teardown
    if (st.last_buf) gst_buffer_unref(st.last_buf);
    if (st.dmabuf_alloc) gst_object_unref(st.dmabuf_alloc);
    if (st.hud_pad) gst_object_unref(st.hud_pad);
    g_free(st.hud_ctl_path);
    if (st.pipeline) {
        gst_element_set_state(st.pipeline, GST_STATE_NULL);
        gst_object_unref(st.pipeline);
    }
    release_frame();
    if (st.present_src) g_source_remove(st.present_src);
    if (st.present_efd >= 0) close(st.present_efd);
    if (st.client_fd >= 0) close(st.client_fd);
    if (st.listen_fd >= 0) close(st.listen_fd);
    log_msg("exit");
    return 0;
}
