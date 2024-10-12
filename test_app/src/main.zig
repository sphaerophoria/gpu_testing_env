const std = @import("std");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("uapi/drm/sphaero_drm.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("gbm.h");
});
const model_renderer = @import("model_renderer.zig");

pub fn main() !void {
    var args = std.process.args();

    const process_name = args.next();
    _ = process_name;

    const gpu = args.next() orelse "/dev/dri/card0";
    const f = try std.fs.openFileAbsolute(gpu, .{
        .mode = .read_write,
    });

    const gbm_dpy = c.gbm_create_device(f.handle);
    const display = c.eglGetDisplay(gbm_dpy);

    if (display == c.EGL_NO_DISPLAY) {
        return error.NoDisplay;
    }

    if (c.eglInitialize(display, null, null) != c.EGL_TRUE) {
        std.debug.print("0x{x}\n", .{c.eglGetError()});
        return error.EglInit;
    }
    if (true) return;

    if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE) {
        return error.BindApi;
    }

    var config: c.EGLConfig = undefined;
    const attribs = [_]c.EGLint{ c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT, c.EGL_NONE };

    var num_configs: c_int = 0;
    if (c.eglChooseConfig(display, &attribs, &config, 1, &num_configs) != c.EGL_TRUE) {
        return error.ChooseConfig;
    }

    const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, null);
    if (context == c.EGL_NO_CONTEXT) {
        return error.CreateContext;
    }

    if (c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, context) == 0) {
        return error.UpdateContext;
    }
}
