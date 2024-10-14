const std = @import("std");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("libdrm/drm_fourcc.h");
    @cInclude("uapi/drm/sphaero_drm.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GL/gl.h");
    @cInclude("gbm.h");
});
const Allocator = std.mem.Allocator;
const model_renderer = @import("model_renderer.zig");

const width = 1024;
const height = 768;

fn getFirstConnectedConnector(f: std.fs.File, resources: *c.drmModeRes) ?*c.drmModeConnector {
    for (resources.connectors[0..@intCast(resources.count_connectors)]) |connector_id| {
        const connector: *c.drmModeConnector = c.drmModeGetConnector(f.handle, connector_id) orelse continue;

        if (connector.connection == c.DRM_MODE_CONNECTED) {
            return connector;
        }

        c.drmModeFreeConnector(connector);
    }
    return null;
}

fn getPreferredMode(connector: *c.drmModeConnector) ?*c.drmModeModeInfo {
    for (connector.modes[0..@intCast(connector.count_modes)]) |*mode| {
        if (mode.type & c.DRM_MODE_TYPE_PREFERRED != 0) {
            return mode;
        }
    }
    return null;
}

fn getEncoderIdForConnector(connector: *c.drmModeConnector) ?u32 {
    if (connector.encoder_id != 0) {
        return connector.encoder_id;
    } else if (connector.count_encoders > 0) {
        return connector.encoders[0];
    } else {
        return null;
    }
}

fn getCrtcIdForEncoder(encoder: *c.drmModeEncoder, resources: *c.drmModeRes) ?u32 {
    if (encoder.crtc_id != 0) {
        return encoder.crtc_id;
    } else if (encoder.possible_crtcs & 1 != 0) {
        return resources.crtcs[0];
    } else {
        return null;
    }
}

fn chooseConfig(display: c.EGLDisplay, configs: []c.EGLConfig) ?c.EGLConfig {
    for (configs) |config| {
        var id: c_int = 0;
        if (c.eglGetConfigAttrib(display, config, c.EGL_NATIVE_VISUAL_ID, &id) != c.EGL_TRUE) {
            continue;
        }
        std.debug.print("id: ", .{});
        for (0..4) |i| {
            std.debug.print("{c}", .{@as(u8, @truncate(@as(u32, @bitCast(id)) >> @intCast(8 * i)))});
        }
        std.debug.print("\n", .{});


        if (id == c.DRM_FORMAT_XRGB8888) {
            return config;
        }
    }

    return null;
}

fn swapBuffers(display: c.EGLDisplay, egl_surface: c.EGLSurface, gbm_surface: *c.gbm_surface) !*c.gbm_bo {
    if (c.eglSwapBuffers(display, egl_surface) != c.EGL_TRUE) {
        std.debug.print("error: 0x{x}\n", .{c.eglGetError()});
        return error.SwapBuffers;
    }

    return c.gbm_surface_lock_front_buffer(gbm_surface) orelse return error.LockSurface;
}

fn getFramebuffer(bo: *c.gbm_bo, f: std.fs.File) !u32 {
    const userdata = c.gbm_bo_get_user_data(bo);
    if (userdata) |data| {
        return @intCast(@intFromPtr(data));
    }

    const stride = c.gbm_bo_get_stride(bo);
    const handle = c.gbm_bo_get_handle(bo).u32;
    var fb_id: u32 = 0;
    if (c.drmModeAddFB(f.handle, width, height, 24, 32, stride, handle, &fb_id) != 0) {
        return error.CreateFb;
    }
    c.gbm_bo_set_user_data(bo, @ptrFromInt(fb_id), null);
    return fb_id;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();
    var args = std.process.args();

    const process_name = args.next();
    _ = process_name;

    const gpu = args.next() orelse "/dev/dri/card0";
    const f = try std.fs.openFileAbsolute(gpu, .{
        .mode = .read_write,
    });

    const format = c.DRM_FORMAT_XRGB8888;

    const gbm_dpy: *c.gbm_device = c.gbm_create_device(f.handle) orelse return error.MakeGbm;
    const gbm_surface: *c.gbm_surface = c.gbm_surface_create(gbm_dpy, width, height, format, c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING) orelse return error.MakeSurface;
    const display = c.eglGetDisplay(gbm_dpy);

    if (display == c.EGL_NO_DISPLAY) {
        return error.NoDisplay;
    }

    if (c.eglInitialize(display, null, null) != c.EGL_TRUE) {
        std.debug.print("0x{x}\n", .{c.eglGetError()});
        return error.EglInit;
    }

    if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE) {
        return error.BindApi;
    }

    const attribs = [_]c.EGLint{
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
        c.EGL_SURFACE_TYPE, c.EGL_WINDOW_BIT,
        c.EGL_RED_SIZE, 1,
        c.EGL_GREEN_SIZE, 1,
        c.EGL_BLUE_SIZE, 1,
        c.EGL_ALPHA_SIZE, 0,
        c.EGL_SAMPLES, 0,
        c.EGL_NONE };

    var num_configs: c_int = 0;
    if (c.eglGetConfigs(display, null, 0, &num_configs) != c.EGL_TRUE) {
        return error.GetConfigs;
    }

    const max_configs = try alloc.alloc(c.EGLConfig, @intCast(num_configs));
    defer alloc.free(max_configs);

    if (c.eglChooseConfig(display, &attribs, max_configs.ptr, @intCast(max_configs.len), &num_configs) != c.EGL_TRUE) {
        return error.ChooseConfig;
    }

    const configs = max_configs[0..@intCast(num_configs)];

    const config = chooseConfig(display, configs) orelse return error.NoGoodConfig;

    const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, null);
    if (context == c.EGL_NO_CONTEXT) {
        return error.CreateContext;
    }

    const egl_surface = c.eglCreateWindowSurface(display, config, @intFromPtr(gbm_surface), null);
    if (egl_surface == c.EGL_NO_SURFACE) {
        return error.CreateSurface;
    }

    if (c.eglMakeCurrent(display, egl_surface, egl_surface, context) == 0) {
        return error.UpdateContext;
    }

    var bo = try swapBuffers(display, egl_surface, gbm_surface);

    const version: *c.drmVersion = c.drmGetVersion(f.handle) orelse return error.GetVersion;
    std.debug.print("Using driver {s}\n", .{version.name[0..@intCast(version.name_len)]});

    const resources: *c.drmModeRes = c.drmModeGetResources(f.handle) orelse return error.GetResourcers;
    const connector = getFirstConnectedConnector(f, resources) orelse return error.NoConnector;
    const preferred_mode = getPreferredMode(connector) orelse return error.NoMode;
    const encoder_id = getEncoderIdForConnector(connector) orelse return error.NoUsableEncoder;
    const encoder: *c.drmModeEncoder = c.drmModeGetEncoder(f.handle, encoder_id) orelse return error.NoEncoder;
    const crtc_id = getCrtcIdForEncoder(encoder, resources) orelse return error.NoUsableCrtc;
    const crtc: *c.drmModeCrtc = c.drmModeGetCrtc(f.handle, crtc_id) orelse return error.NoCrtc;

    var fb_id = try getFramebuffer(bo, f);
    if (c.drmModeSetCrtc(f.handle, crtc.crtc_id, fb_id, 0, 0, &connector.connector_id, 1, preferred_mode) != 0) {
        return error.SetCrtc;
    }

    std.debug.print("success\n", .{});

    var color: f32 = 0.0;
    var last = try std.time.Instant.now();
    while (true) {
        const now = try std.time.Instant.now();
        color += @as(f32, @floatFromInt(now.since(last))) / std.time.ns_per_s;
        while (color > 1.0) {
            color -= 1.0;
        }
        c.glViewport(0, 0, 512, 512);
        c.glClearColor(0.0, color, 0.0, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glFlush();
        const next_bo = try swapBuffers(display, egl_surface, gbm_surface);
        fb_id = try getFramebuffer(next_bo, f);
        if(c.drmModePageFlip(f.handle, crtc.crtc_id, fb_id, 0, null) != 0) {
            std.debug.print("Failed to page flip\n", .{});
            continue;
        }

        c.gbm_surface_release_buffer(gbm_surface, bo);
        bo = next_bo;
        last = now;

        std.time.sleep(30 * std.time.ns_per_ms);
    }
    std.debug.print("Hi mom we are finished :)\n", .{});
}
