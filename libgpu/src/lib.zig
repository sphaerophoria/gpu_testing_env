const std = @import("std");
const Allocator = std.mem.Allocator;
const shader = @import("shader.zig");
const Vec3 = shader.Vec3;
const Vec4 = shader.Vec4;
const global = @import("global.zig");

// FIXME: Check signature between defined functions and headers
//

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

const DumbBuffers = std.AutoHashMapUnmanaged(u64, []u8);
const Textures = std.AutoHashMapUnmanaged(u64, Texture);

const Gpu = struct {
    alloc: Allocator,
    textures: Textures = .{},
    dumb_buffers: DumbBuffers = .{},

    pub fn init(alloc: Allocator) Gpu {
        return .{
            .alloc = alloc,
        };
    }

    // FIXME: camel case
    pub fn create_texture(self: *Gpu, id: u64, width: u32, height: u32) !void {
        try self.textures.put(self.alloc, id, .{
            .data = try self.alloc.alloc(u8, width * height * 4),
            .width_px = width,
        });
    }

    // FIXME: camel case
    pub fn create_dumb(self: *Gpu, id: u64, size: u64) !void {
        // FIXME: Hack to avoid 8 byte write masked at end of size in qemu
        const extra_bytes = 8;
        try self.dumb_buffers.put(self.alloc, id, try self.alloc.alloc(u8, size + extra_bytes));
    }

    pub fn freeDumb(self: *Gpu, id: u64) void {
        const kv = self.dumb_buffers.fetchRemove(id) orelse return;
        self.alloc.free(kv.value);
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

    pub fn executeGraphicsPipeline(self: *Gpu, input_handles: GraphicsPipelineInputHandles, num_elems: usize) !void {
        const inputs = try getGraphicsPiplineInputs(
            self.alloc,
            input_handles,
            self.dumb_buffers,
            self.textures,
        );
        defer inputs.deinit(self.alloc);

        const vert_outputs = try inputs.vs.execute(self.alloc, inputs.vb, inputs.format, num_elems);
        defer self.alloc.free(vert_outputs);

        const frag_outputs = try inputs.fs.execute(self.alloc, &.{}, &.{}, 1);
        defer self.alloc.free(frag_outputs);

        rasterizeTriangles(vert_outputs, frag_outputs, inputs.texture);
   }
};

const GraphicsPipelineInputs = struct {
    vs: shader.Shader,
    fs: shader.Shader,
    vb: []const u8, // refrence to dumb_buffers data
    format: []shader.ShaderInput,
    texture: Texture, // shallow copy of textures data

    fn deinit(self: GraphicsPipelineInputs, alloc: Allocator) void {
        self.vs.deinit(alloc);
        self.fs.deinit(alloc);
        alloc.free(self.format);
    }
};

const GraphicsPipelineInputHandles = struct {
    vs: u64,
    fs: u64,
    vb: u64,
    format: u64,
    output_tex: u64,
};

fn getGraphicsPiplineInputs(alloc: Allocator, handles: GraphicsPipelineInputHandles, dumb_buffers: DumbBuffers, textures: Textures) !GraphicsPipelineInputs {
    const vs = dumb_buffers.get(handles.vs) orelse return error.InvalidVsId;
    const fs = dumb_buffers.get(handles.fs) orelse return error.InvalidFsId;
    const vb = dumb_buffers.get(handles.vb) orelse return error.InvalidVbId;
    const format = dumb_buffers.get(handles.format) orelse return error.InvalidFormatId;
    const texture = textures.get(handles.output_tex) orelse return error.InvalidTextureId;

    // FIXME: remove this hack
    const oversize_buffer_len = 8;
    const vert_shader = try shader.Shader.load(alloc, vs[0..vs.len - oversize_buffer_len]);
    errdefer vert_shader.deinit(alloc);

    const fragment_shader = try shader.Shader.load(alloc, fs[0..fs.len - oversize_buffer_len]);
    errdefer fragment_shader.deinit(alloc);

    const shader_input_defs = try std.json.parseFromSlice([]shader.ShaderInput, alloc, format[0..format.len - oversize_buffer_len], .{});
    defer shader_input_defs.deinit();

    return .{
        .vs = vert_shader,
        .fs = fragment_shader,
        .vb = vb,
        .format = try alloc.dupe(shader.ShaderInput, shader_input_defs.value),
        .texture = texture,
    };
}

fn lerpInt(a: anytype, b: anytype, start: anytype, end: anytype, val: anytype) @TypeOf(a) {
    const lerp_val = @as(f32, @floatFromInt(val - start)) / @as(f32, @floatFromInt(end - start));
    return @intFromFloat(std.math.lerp(
        @as(f32, @floatFromInt(a)),
        @as(f32, @floatFromInt(b)),
        lerp_val));
}

const TriangleRasterizer = struct {
    texture_data_u32: []u32,
    texture_width_px: u32,
    texture_height_px: u32,
    frag_color: u32,

    fn rasterizeTriangle(self: TriangleRasterizer, sorted_triangle: [3]PixelCoord) void {
        const a_px, const b_px, const c_px = sorted_triangle;

        self.rasterizeHalfTriangle(c_px, b_px, c_px, a_px);
        self.rasterizeHalfTriangle(b_px, a_px, c_px, a_px);
    }

    fn rasterizeHalfTriangle(self: TriangleRasterizer, start: PixelCoord, end: PixelCoord, long_start: PixelCoord, long_end: PixelCoord) void {
        const start_y  = @max(start[1], 0);
        const end_y  = @min(end[1], self.texture_height_px);

        for (start_y..end_y) |y_px| {
            const x1_px = lerpInt(long_start[0], long_end[0], long_start[1], long_end[1], y_px);
            const x2_px = lerpInt(start[0], end[0], start[1], end[1], y_px);
            const left = @max(@min(x1_px, x2_px), 0);
            const right = @min(@max(x1_px, x2_px), self.texture_width_px);
            for (left..right) |x_px| {
                self.texture_data_u32[y_px * self.texture_width_px + x_px] = self.frag_color;
            }
        }
    }
};

pub const PixelCoord = [2]u32;

pub fn norm_to_pix_coord(coord: Vec3, width: u32, height: u32) PixelCoord {
    const height_f: f32 = @floatFromInt(height);
    return PixelCoord {
        @intFromFloat((coord[0] + 1.0) / 2 * @as(f32, @floatFromInt(width))),
        @intFromFloat(height_f * (1.0 - (coord[1] + 1.0) / 2)),
    };
}

pub fn homogenous_to_vec3(coord: Vec4) Vec3 {
    // FIXME: divide by 0
    // NOTE: rcrnstn claims that some people use w == 0 to mean do not draw
    // but thinks it's not in spec
    return Vec3{
        coord[0] / coord[3],
        coord[1] / coord[3],
        coord[2] / coord[3],
    };

}

fn homogeneousToSortedPixelCoords(homogenous_coords: [3]shader.Vec4, texture_width_px: u32, texture_height_px: u32) [3]PixelCoord {
    var coords: [3]PixelCoord = undefined;

    for (homogenous_coords, 0..) |homogenous_coord, i| {
        const norm = homogenous_to_vec3(homogenous_coord);
        coords[i] = norm_to_pix_coord(norm, texture_width_px, texture_height_px);
    }

    const smallerY = struct {
        fn f(_: void, lhs: PixelCoord, rhs: PixelCoord) bool {
            return rhs[1] < lhs[1];
        }
    }.f;

    std.mem.sort(PixelCoord, &coords, {}, smallerY);
    return coords;
}

fn vec4ColorToU32(color: shader.Vec4) u32 {
    var frag_color_u32: u32 = 0;
    frag_color_u32 |= @intFromFloat(color[2] * 255); // b
    frag_color_u32 |= @as(u32, @intFromFloat(color[1] * 255)) << 8; // g
    frag_color_u32 |= @as(u32, @intFromFloat(color[0] * 255)) << 16; // r
    frag_color_u32 |= @as(u32, @intFromFloat(color[3] * 255)) << 24; // a
    return frag_color_u32;
}

fn rasterizeTriangles(vert_outputs: []shader.Variable, frag_outputs: []shader.Variable, texture: Texture) void {
    const frag_color = vec4ColorToU32(frag_outputs[0].vec4);

    const rasterizer = TriangleRasterizer {
        .texture_data_u32 = @alignCast(std.mem.bytesAsSlice(u32, texture.data)),
        .texture_height_px = texture.calcHeight(),
        .texture_width_px = texture.width_px,
        .frag_color = frag_color,
    };

    for (0..vert_outputs.len / 3) |triangle_idx| {
        const base = triangle_idx * 3;

        const coords: [3]shader.Vec4 = .{
            vert_outputs[base].vec4,
            vert_outputs[base + 1].vec4,
            vert_outputs[base + 2].vec4,
        };

        const pixel_coords = homogeneousToSortedPixelCoords(
            coords,
            rasterizer.texture_width_px,
            rasterizer.texture_height_px,
        );

        rasterizer.rasterizeTriangle(pixel_coords);
    }
}

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

pub export fn libgpu_free_dumb(gpu: *Gpu, id: u64) void {
    gpu.freeDumb(id);
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

pub export fn libgpu_execute_graphics_pipeline(gpu: *Gpu, vs: u64, fs: u64, vb: u64, format: u64, output_tex: u64, num_elems: usize) bool {
    gpu.executeGraphicsPipeline(.{
        .vs = vs,
        .fs = fs,
        .vb = vb,
        .format = format,
        .output_tex = output_tex,
    }, num_elems) catch |e| {
        std.log.err("Failed to execute graphics pipeline: {s}", .{@errorName(e)});
        return false;
    };
    return true;
}
