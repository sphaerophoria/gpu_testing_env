const std = @import("std");
const Allocator = std.mem.Allocator;

// FIXME: Check signature between defined functions and headers
//

const global = struct {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
};

const Texture = struct {
    // 4 bytes per pix
    data: []u8,
    width_px: u32,

    fn calcHeight(self: Texture) u32 {
        return @intCast(self.data.len / self.calcStride());
    }

    fn calcStride(self: Texture) u32 {
        return self.width_px * 4;
    }
};

const Gpu = struct {
    alloc: Allocator,
    textures: std.AutoHashMapUnmanaged(u64, Texture) = .{},
    dumb_buffers: std.AutoHashMapUnmanaged(u64, []u8) = .{},

    pub fn init(alloc: Allocator) Gpu {
        return .{
            .alloc = alloc,
        };
    }

    pub fn create_texture(self: *Gpu, id: u64, width: u32, height: u32) !void {
        try self.textures.put(self.alloc, id, .{
            .data = try self.alloc.alloc(u8, width * height * 4),
            .width_px = width,
        });
    }

    pub fn create_dumb(self: *Gpu, id: u64, size: u64) !void {
        // FIXME: Hack to avoid 8 byte write masked at end of size in qemu
        const extra_bytes = 8;
        const rounded_up = ((size + 4095) / 4096) * 4096;
        try self.dumb_buffers.put(self.alloc, id, try self.alloc.alloc(u8, rounded_up + extra_bytes));
    }

    pub fn clear(self: *Gpu, id: u64, rgba_opt: [*c]f32, minx: u32, maxx: u32, miny: u32, maxy: u32) !void {
        const rgba = rgba_opt orelse return error.NoRgba;
        const texture = self.textures.get(id) orelse return error.InvalidTextureId;

        const adjusted_maxx = if (maxx == 0) texture.width_px else maxx;
        const adjusted_maxy = if (maxy == 0) texture.calcHeight() else maxy;
        const stride = texture.calcStride();

        for (miny..adjusted_maxy) |y| {
            for (minx..adjusted_maxx) |x| {
                for (0..4) |c| {
                    texture.data[y * stride + x * 4 + c] = @intFromFloat(rgba[c] * 255.0);
                }
            }
        }
    }
};

pub export fn libgpu_gpu_create() ?*anyopaque {
    const alloc = global.gpa.allocator();
    const gpu = alloc.create(Gpu) catch {
        return null;
    };
    gpu.* = Gpu.init(alloc);
    return gpu;
}

// FIXME: Thread safe api
pub export fn libgpu_gpu_create_texture(gpu: *Gpu, id: u64, width: u32, height: u32) bool {
    gpu.create_texture(id, width, height) catch |e| {
        std.log.err("Failed to allocate texture: {s}", .{@errorName(e)});
        return false;
    };

    return true;
}

pub export fn libgpu_gpu_clear(gpu: *Gpu, id: u64, rgba: ?*f32, minx: u32, maxx: u32, miny: u32, maxy: u32) bool {
    gpu.clear(id, rgba, minx, maxx, miny, maxy) catch |e| {
        std.log.err("Failed to allocate texture: {s}", .{@errorName(e)});
        return false;
    };

    return true;
}

pub export fn libgpu_gpu_get_tex_data(gpu: *Gpu, id: u64, width: ?*u32, height: ?*u32, stride: ?*u32, data: ?**anyopaque) bool {
    const texture = gpu.textures.get(id) orelse {
        std.log.err("Invalid texture id", .{});
        return false;
    };

    if (width) |w| {
        w.* = texture.width_px;
    }

    if (height) |h| {
        h.* = texture.calcHeight();
    }

    if (stride) |s| {
        s.* = texture.calcStride();
    }

    if (data) |d| {
        d.* = @ptrCast(texture.data.ptr);
    }

    return true;
}

pub export fn libgpu_gpu_create_dumb(gpu: *Gpu, id: u64, size: u64) bool {

    gpu.create_dumb(id, size) catch |e| {
        std.log.err("Failed to create dumb buffer: {s}", .{@errorName(e)});
        return false;
    };

    return true;
}

pub export fn libgpu_gpu_get_dumb(gpu: *Gpu, id: u64, data: ?**anyopaque) bool {
    const buf = gpu.dumb_buffers.get(id) orelse {
        std.log.err("Failed to get dumb buffer", .{});
        return false;
    };

    if (data) |d| {
        d.* = buf.ptr;
    }

    return true;
}
