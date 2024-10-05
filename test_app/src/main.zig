const std = @import("std");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("uapi/drm/sphaero_drm.h");
});
const model_renderer = @import("model_renderer.zig");

fn makeGpuUpload(handle: std.fs.File.Handle, data: []const u8) !c.drm_sphaero_upload_gpu_obj {
    var create_gpu_obj_params: c.drm_sphaero_create_gpu_obj = undefined;
    create_gpu_obj_params.size = data.len;
    if (c.drmIoctl(handle, c.DRM_IOCTL_SPHAERO_CREATE_GPU_OBJ, &create_gpu_obj_params) != 0) {
        return error.CreateVb;
    }

    var map_gpu_obj_params: c.drm_sphaero_map_gpu_obj = undefined;
    map_gpu_obj_params.handle = create_gpu_obj_params.handle;
    if (c.drmIoctl(handle, c.DRM_IOCTL_SPHAERO_MAP_GPU_OBJ, &map_gpu_obj_params) != 0) {
        return error.MapVb;
    }

    const vb_data_ptr = try std.posix.mmap(null, data.len, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE, std.os.linux.MAP{ .TYPE = .SHARED }, handle, map_gpu_obj_params.offset);
    const vb_data = vb_data_ptr[0..data.len];

    @memcpy(vb_data, data);

    std.posix.munmap(vb_data);

    return .{
        .handle = create_gpu_obj_params.handle,
        .size = data.len,
    };
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

    const version: *c.drmVersion = c.drmGetVersion(f.handle) orelse return error.GetVersion;
    std.debug.print("Using driver {s}\n", .{version.name[0..@intCast(version.name_len)]});

    var model = try model_renderer.Model.load(alloc, model_renderer.model_obj);
    defer model.deinit(alloc);

    const vertex_data = try model.makeUploadVertexBuffer(alloc);
    defer alloc.free(vertex_data);

    var upload_vb_params = try makeGpuUpload(f.handle, std.mem.sliceAsBytes(vertex_data));

    if (c.drmIoctl(f.handle, c.DRM_IOCTL_SPHAERO_UPLOAD_VB, &upload_vb_params) != 0) {
        return error.CreateVb;
    }

    var img = try model_renderer.Img.init(model_renderer.model_img);
    defer img.deinit();

    var upload_texture_params = try makeGpuUpload(f.handle, std.mem.sliceAsBytes(img.data));

    if (c.drmIoctl(f.handle, c.DRM_IOCTL_SPHAERO_UPLOAD_TEXTURE, &upload_texture_params) != 0) {
        return error.CreateTexture;
    }

    var last = try std.time.Instant.now();
    var y_angle: f32 = 0.0;

    while (true) {
        const now = try std.time.Instant.now();
        const delta_ms: f32 = @floatFromInt(now.since(last) / std.time.ns_per_ms);
        last = now;
        y_angle += std.math.pi * 2 / 1000.0 * delta_ms;
        y_angle = @mod(y_angle, std.math.pi * 2);

        const transform = model_renderer.getTransform(1024.0 / 768.0, y_angle);
        // FIXME: Re-using our existing buffer
        var upload_transform_params = try makeGpuUpload(f.handle, std.mem.asBytes(&transform));

        if (c.drmIoctl(f.handle, c.DRM_IOCTL_SPHAERO_UPLOAD_TRANSFORM, &upload_transform_params) != 0) {
            return error.CreateTexture;
        }

        // FIXME: Sleep for one frame time/vsync?
        std.time.sleep(30 * std.time.ns_per_ms);
    }
}
