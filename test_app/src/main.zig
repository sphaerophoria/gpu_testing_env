const std = @import("std");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

fn getFirstConnectedConnector(f: std.fs.File, resources: *c.drmModeRes) ?*c.drmModeConnector {
    for (resources.connectors[0..@intCast(resources.count_connectors)]) |connector_id| {
        const connector: *c.drmModeConnector = c.drmModeGetConnectorCurrent(f.handle, connector_id) orelse continue;

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

pub fn main() !void {
    const f = try std.fs.openFileAbsolute("/dev/dri/card0", .{
        .mode = .read_write,
    });

    const resources: *c.drmModeRes = c.drmModeGetResources(f.handle) orelse return error.GetResourcers;
    std.debug.print("{any}\n", .{resources});
    const connector = getFirstConnectedConnector(f, resources) orelse return error.NoConnector;
    std.debug.print("{any}\n", .{connector});
    const preferred_mode = getPreferredMode(connector) orelse return error.NoMode;

    var db_id: u32 = undefined;
    var pitch: u32 = undefined;
    var size: u64 = undefined;

    std.debug.print("{any}", .{preferred_mode});
    if (c.drmModeCreateDumbBuffer(f.handle, preferred_mode.hdisplay, preferred_mode.vdisplay, 32, 0, &db_id, &pitch, &size) != 0) {
        return error.CreateDumbBuffer;
    }

    var fb_id: u32 = undefined;
    if (c.drmModeAddFB(f.handle, preferred_mode.hdisplay, preferred_mode.vdisplay, 24, 32, pitch, db_id, &fb_id) != 0) {
        return error.AddFb;
    }

    const encoder: *c.drmModeEncoder = c.drmModeGetEncoder(f.handle, connector.encoder_id) orelse return error.NoEncoder;
    const crtc: *c.drmModeCrtc = c.drmModeGetCrtc(f.handle, encoder.crtc_id) orelse return error.NoEncoder;

    var db_offs: u64 = undefined;
    if (c.drmModeMapDumbBuffer(f.handle, db_id, &db_offs) != 0) {
        return error.MapDumb;
    }

    const db_data_u8 = try std.posix.mmap(null, size, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE, std.os.linux.MAP { .TYPE = .SHARED }, f.handle, db_offs);
    const db_data: []u32 = std.mem.bytesAsSlice(u32, db_data_u8[0..size]);

    drawRect(db_data, pitch,
            0, 0,
            preferred_mode.hdisplay, preferred_mode.vdisplay,
            0x00ffff00
    );

    const eye_width = preferred_mode.hdisplay / 10;
    const left_center_x = preferred_mode.hdisplay / 3;
    const right_center_x = preferred_mode.hdisplay / 3 * 2;
    const eye_center_y = preferred_mode.vdisplay / 3;
    const mounth_center_y = eye_center_y * 2;
    drawRect(db_data, pitch,
            left_center_x - eye_width / 2,
            eye_center_y - eye_width / 2,
            left_center_x + eye_width / 2,
            eye_center_y + eye_width / 2,
            0x0
    );
    drawRect(db_data, pitch,
            right_center_x - eye_width / 2,
            eye_center_y - eye_width / 2,
            right_center_x + eye_width / 2,
            eye_center_y + eye_width / 2,
            0x0
    );

    drawRect(db_data, pitch,
            left_center_x - eye_width / 2,
            mounth_center_y - eye_width / 2,
            right_center_x + eye_width / 2,
            mounth_center_y + eye_width / 2,
            0x0
    );

    _ = c.drmModeSetCrtc(f.handle, crtc.crtc_id, 0, 0, 0, null, 0, null);
    _ = c.drmModeSetCrtc(f.handle, crtc.crtc_id, fb_id, 0, 0, &connector.connector_id, 1, preferred_mode);
    std.time.sleep(1 * std.time.ns_per_s);
}
