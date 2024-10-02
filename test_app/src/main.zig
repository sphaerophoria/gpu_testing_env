const std = @import("std");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

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

fn drawRect(data: []u32, stride: usize, x1: usize, y1: usize, x2: usize, y2: usize, color: u32) void {
    const elem_size = @sizeOf(@TypeOf(data[0]));
    std.debug.assert(stride % elem_size == 0);
    for (y1..y2) |y| {
        for (x1..x2) |x| {
            const pix_pos = y * (stride / elem_size) + x;
            data[pix_pos] = color;
        }
    }
}

const RenderBuffer = struct {
    fb_id: u32,
    db_id: u32,
    pitch: u32,
    pixel_data: []u32,

    fn init(fd: c_int, width: u32, height: u32) !RenderBuffer {
        var db_id: u32 = undefined;
        var pitch: u32 = undefined;
        var size: u64 = undefined;
        if (c.drmModeCreateDumbBuffer(fd, width, height, 32, 0, &db_id, &pitch, &size) != 0) {
            return error.CreateDumbBuffer;
        }

        var fb_id: u32 = undefined;
        var ret: c_int = 0;
        ret = c.drmModeAddFB(fd, width, height, 24, 32, pitch, db_id, &fb_id);
        if (ret != 0) {
            return error.AddFb;
        }

        var db_offs: u64 = undefined;
        if (c.drmModeMapDumbBuffer(fd, db_id, &db_offs) != 0) {
            return error.MapDumb;
        }

        const pixel_data_u8 = try std.posix.mmap(null, size, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE, std.os.linux.MAP{ .TYPE = .SHARED }, fd, db_offs);
        const pixel_data: []u32 = std.mem.bytesAsSlice(u32, pixel_data_u8[0..size]);

        return .{
            .fb_id = fb_id,
            .db_id = db_id,
            .pitch = pitch,
            .pixel_data = pixel_data,
        };
    }
};

const RenderBuffers = struct {
    bufs: [2]RenderBuffer,
    id: u1 = 0,

    fn init(
        fd: c_int,
        width: u32,
        height: u32,
    ) !RenderBuffers {
        const render_buffers = [2]RenderBuffer{
            try RenderBuffer.init(fd, width, height),
            try RenderBuffer.init(fd, width, height),
        };

        return .{
            .bufs = render_buffers,
        };
    }

    fn active(self: *RenderBuffers) *RenderBuffer {
        return &self.bufs[self.id];
    }

    fn swap(self: *RenderBuffers) void {
        self.id +%= 1;
    }
};

fn drawSmile(render_buffer: *RenderBuffer, width: u32, height: u32, eye_height_norm: f32, color: u32) void {
    drawRect(
        render_buffer.pixel_data,
        render_buffer.pitch,
        0,
        0,
        width,
        height,
        color,
    );

    const eye_width = width / 10;
    const left_center_x = width / 3;
    const right_center_x = width / 3 * 2;
    const eye_center_y = height / 3;
    const mounth_center_y = eye_center_y * 2;
    const eye_height: u32 = @intFromFloat(@as(f32, @floatFromInt(eye_width)) * eye_height_norm);
    drawRect(
        render_buffer.pixel_data,
        render_buffer.pitch,
        left_center_x - eye_width / 2,
        eye_center_y - eye_height / 2,
        left_center_x + eye_width / 2,
        eye_center_y + eye_height / 2,
        0x0,
    );

    drawRect(
        render_buffer.pixel_data,
        render_buffer.pitch,
        right_center_x - eye_width / 2,
        eye_center_y - eye_height / 2,
        right_center_x + eye_width / 2,
        eye_center_y + eye_height / 2,
        0x0,
    );

    drawRect(
        render_buffer.pixel_data,
        render_buffer.pitch,
        left_center_x - eye_width / 2,
        mounth_center_y - eye_width / 2,
        right_center_x + eye_width / 2,
        mounth_center_y + eye_width / 2,
        0x0,
    );
}

// blink transition time
// _____    ______
//      \/\/
const Animation = struct {
    time: u32 = 0,
    const period = 2000;
    const blink_period = 500;
    const animation_start = 0;

    fn update(self: *Animation, delta_ms: u32) void {
        self.time += delta_ms;
        self.time %= period;
    }

    fn getEyeHeight(self: Animation) f32 {
        if (self.time > blink_period) {
            return 1.0;
        }

        var animation_amount: f32 = @floatFromInt(self.time % (blink_period / 2));
        animation_amount /= @floatFromInt(blink_period / 4);
        return @abs(1.0 - animation_amount);
    }
};

pub fn main() !void {
    var args = std.process.args();

    const process_name = args.next();
    _ = process_name;

    const gpu = args.next() orelse "/dev/dri/card0";
    const f = try std.fs.openFileAbsolute(gpu, .{
        .mode = .read_write,
    });

    const version: *c.drmVersion = c.drmGetVersion(f.handle) orelse return error.GetVersion;
    std.debug.print("Using driver {s}\n", .{version.name[0..version.name_len]});

    const resources: *c.drmModeRes = c.drmModeGetResources(f.handle) orelse return error.GetResourcers;
    const connector = getFirstConnectedConnector(f, resources) orelse return error.NoConnector;
    const preferred_mode = getPreferredMode(connector) orelse return error.NoMode;
    const encoder_id = getEncoderIdForConnector(connector) orelse return error.NoUsableEncoder;
    const encoder: *c.drmModeEncoder = c.drmModeGetEncoder(f.handle, encoder_id) orelse return error.NoEncoder;
    const crtc_id = getCrtcIdForEncoder(encoder, resources) orelse return error.NoUsableCrtc;
    const crtc: *c.drmModeCrtc = c.drmModeGetCrtc(f.handle, crtc_id) orelse return error.NoCrtc;

    var render_buffers = try RenderBuffers.init(f.handle, preferred_mode.hdisplay, preferred_mode.vdisplay);

    const color: u32 = 0x00ffff00;
    drawSmile(render_buffers.active(), preferred_mode.hdisplay, preferred_mode.vdisplay, 1.0, color);

    if (c.drmModeSetCrtc(f.handle, crtc.crtc_id, render_buffers.active().fb_id, 0, 0, &connector.connector_id, 1, preferred_mode) != 0) {
        return error.SetCrtc;
    }

    var last = try std.time.Instant.now();
    var animation = Animation{};

    while (true) {
        const now = try std.time.Instant.now();
        const delta_ms = now.since(last) / std.time.ns_per_ms;
        animation.update(@intCast(delta_ms));
        last = now;

        render_buffers.swap();
        const render_buffer = render_buffers.active();

        drawSmile(render_buffer, preferred_mode.hdisplay, preferred_mode.vdisplay, animation.getEyeHeight(), color);

        const page_flip_ret = c.drmModePageFlip(f.handle, crtc.crtc_id, render_buffer.fb_id, 0, null);
        if (page_flip_ret != 0) {
            std.log.err("Failed to flip page: {d}", .{page_flip_ret});
            return error.PageFlip;
        }

        // FIXME: Sleep for one frame time/vsync?
        std.time.sleep(30 * std.time.ns_per_ms);
    }
}
