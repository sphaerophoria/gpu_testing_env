const std = @import("std");
const Allocator = std.mem.Allocator;
const shader = @import("shader.zig");
const lin = @import("lin.zig");
const Vec3 = lin.Vec3;
const Vec4 = lin.Vec4;
const global = @import("global.zig");

// FIXME: Check signature between defined functions and headers
//

pub const Texture = struct {
    // 4 bytes per pix
    data: []u8,
    width_px: u32,

    pub fn calcHeight(self: Texture) u32 {
        return @intCast(self.data.len / self.calcStride());
    }

    pub fn calcStride(self: Texture) u32 {
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
            num_elems,
        );
        defer inputs.deinit(self.alloc);

        const record_path: ?[]const u8 = "graphics_inputs.json";
        if (record_path) |p| {
            var buf: [4096]u8 = undefined;
            std.debug.print("Recording to {s}\n", .{std.fs.cwd().realpath(p, &buf) catch "unknown"});
            inputs.record(p) catch |e| {
                std.log.err("Failed to record graphics pipeline inputs: {s}", .{@errorName(e)});
                if (@errorReturnTrace()) |t| {
                    std.log.err("Backtrace: {any}", .{t});
                }
            };
        }

        try inputs.execute(self.alloc);
   }
};

pub const GraphicsPipelineInputs = struct {
    vs: shader.Shader,
    fs: shader.Shader,
    vb: []const u8, // refrence to dumb_buffers data
    format: []shader.ShaderInput,
    texture: Texture, // shallow copy of textures data
    num_elems: usize,

    pub fn deinit(self: GraphicsPipelineInputs, alloc: Allocator) void {
        self.vs.deinit(alloc);
        self.fs.deinit(alloc);
        alloc.free(self.format);
    }

    pub fn record(self: GraphicsPipelineInputs, p: []const u8) !void {
        const f = try std.fs.cwd().createFile(p, .{});
        defer f.close();

        var bw = std.io.bufferedWriter(f.writer());
        try std.json.stringify(self, .{}, bw.writer());
        try bw.flush();
    }

    pub fn execute(inputs: GraphicsPipelineInputs, alloc: Allocator) !void {
        const vert_outputs = try inputs.vs.executeOnBuf(alloc, inputs.vb, inputs.format, inputs.num_elems);
        defer vert_outputs.deinit(alloc);

        if (vert_outputs.marked.len < 3) {
            return;
        }

        try rasterizeTriangles(alloc, vert_outputs, inputs.fs, inputs.texture);
    }
};

const GraphicsPipelineInputHandles = struct {
    vs: u64,
    fs: u64,
    vb: u64,
    format: u64,
    output_tex: u64,
};

fn getGraphicsPiplineInputs(alloc: Allocator, handles: GraphicsPipelineInputHandles, dumb_buffers: DumbBuffers, textures: Textures, num_elems: usize) !GraphicsPipelineInputs {
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
        .num_elems = num_elems,
    };
}

fn lerpInt(a: anytype, b: anytype, start: anytype, end: anytype, val: anytype) @TypeOf(a) {
    const lerp_val = @as(f32, @floatFromInt(val - start)) / @as(f32, @floatFromInt(end - start));
    return @intFromFloat(std.math.lerp(
        @as(f32, @floatFromInt(a)),
        @as(f32, @floatFromInt(b)),
        lerp_val));
}

fn findXForY(start: PixelCoord, end: PixelCoord, y: usize, max: u32) usize {
    const y_f: f32 = @floatFromInt(y);
    const lerp_val = (y_f - start.y) / (end.y - start.y);
    return clampCastF32U32(std.math.lerp(start.x, end.x, lerp_val), 0, max);
}

const TriangleRasterizer = struct {
    alloc: Allocator,
    texture_data_u32: []u32,
    texture_width_px: u32,
    texture_height_px: u32,
    frag_shader: shader.Shader,

    fn rasterizeTriangle(self: TriangleRasterizer, sorted_triangle: [3]PixelCoord, frag_inputs: [3]shader.Variable) !void {
        const a_px, const b_px, const c_px = sorted_triangle;

        try self.rasterizeHalfTriangle(c_px, b_px, c_px, a_px, sorted_triangle, frag_inputs);
        try self.rasterizeHalfTriangle(b_px, a_px, c_px, a_px, sorted_triangle, frag_inputs);
    }

    fn rasterizeHalfTriangle(self: TriangleRasterizer, start: PixelCoord, end: PixelCoord, long_start: PixelCoord, long_end: PixelCoord, sorted_triangle: [3]PixelCoord, frag_inputs: [3]shader.Variable) !void {
        const start_y: usize = clampCastF32U32(start.y, 0, self.texture_height_px);
        const end_y: usize  = clampCastF32U32(end.y, 0, self.texture_height_px);

        std.debug.print("start y: {d}, end y: {d}", .{start_y, end_y});

        const total_area = lin.cross(
            sorted_triangle[1].vec2() - sorted_triangle[0].vec2(),
            sorted_triangle[2].vec2() - sorted_triangle[0].vec2(),
        );
        const bc = BaryCalculator {
            .total_area = total_area,
            .triangle = sorted_triangle,
        };

        for (start_y..end_y) |y_px| {
            const x1_px = findXForY(long_start, long_end, y_px, self.texture_width_px);
            const x2_px = findXForY(start, end, y_px, self.texture_width_px);

            const left = @min(x1_px, x2_px);
            const right = @max(x1_px, x2_px);

            for (left..right) |x_px| {
                const p = lin.Vec2{@floatFromInt(x_px), @floatFromInt(y_px)};
                const bary_a, const bary_b, const bary_c = bc.calc(p);
                const frag_input = try interpolateVars(frag_inputs, bary_a, bary_b, bary_c);

                var frag_inputs_mut = [1]shader.Variable{frag_input};
                const frag_output = try self.frag_shader.executeOnInputs(self.alloc, &frag_inputs_mut);
                const color = vec4ColorToU32(frag_output.marked.vec4);
                self.texture_data_u32[y_px * self.texture_width_px + x_px] = color;
            }
        }
    }
};

const BaryCalculator = struct {
    total_area: f32,
    triangle: [3]PixelCoord,

    fn calc(self: BaryCalculator, p: lin.Vec2) [3]f32 {
        const pa = p - self.triangle[0].vec2();
        const pb = p - self.triangle[1].vec2();
        const pc = p - self.triangle[2].vec2();

        const bary_projected_a = lin.cross(pb, pc) / self.total_area;
        const bary_projected_b = lin.cross(pc, pa) / self.total_area;
        const bary_projected_c = lin.cross(pa, pb) / self.total_area;

        const bary_a_inter = bary_projected_a / self.triangle[0].w;
        const bary_b_inter = bary_projected_b / self.triangle[1].w;
        const bary_c_inter = bary_projected_c / self.triangle[2].w;

        const bary_denom = bary_a_inter + bary_b_inter + bary_c_inter;

        return .{
            bary_a_inter / bary_denom,
            bary_b_inter / bary_denom,
            bary_c_inter / bary_denom,
        };
    }
};


fn clampCastF32U32(val: f32, min: u32, max: u32) u32 {
    const min_f: f32 = @floatFromInt(min);
    const max_f: f32 = @floatFromInt(max);
    if (val <= min_f) return min;
    if (val >= max_f) return max;

    return @intFromFloat(val);
}

const PixelCoord = struct {
    x: f32,
    y: f32,
    w: f32,

    pub fn vec2(self: PixelCoord) lin.Vec2 {
        return .{self.x, self.y};
    }
};

fn interpolateVars(v: [3]shader.Variable, a: f32, b: f32, c: f32) !shader.Variable {
    if (std.meta.activeTag(v[0]) != std.meta.activeTag(v[1])
        or std.meta.activeTag(v[0]) != std.meta.activeTag(v[2])
) {
        return error.TypesNotMatched;
    }

    switch(v[0]) {
        .f32 => {
            return .{
                .f32 = a * v[0].f32 + b * v[1].f32 + c * v[2].f32,
            };
        },
        else => {
            return error.UnhandledInterpolation;
        }
    }
}

pub fn homogenousToPixelCoord(coord: Vec4, width: u32, height: u32) PixelCoord {
    const height_f: f32 = @floatFromInt(height);
    const x_norm = coord[0] / coord[3];
    const y_norm = coord[1] / coord[3];
    const w_norm = coord[3];
    return PixelCoord {
        .x = (x_norm + 1.0) / 2 * @as(f32, @floatFromInt(width)),
        .y = height_f * (1.0 - (y_norm + 1.0) / 2),
        .w = w_norm,
    };
}

fn homogeneousToPixelCoords(homogenous_coords: [3]Vec4, texture_width_px: u32, texture_height_px: u32) [3]PixelCoord {
    var coords: [3]PixelCoord = undefined;

    for (homogenous_coords, 0..) |homogenous_coord, i| {
        coords[i] = homogenousToPixelCoord(homogenous_coord, texture_width_px, texture_height_px);
    }
    return coords;
}

fn sortCoordsByPixelY(pixel_coords: [3]PixelCoord) [3]u8 {
    var ret: [3]u8 = .{ 0, 1, 2 };

    const greaterY = struct {
        fn f(ctx: []const PixelCoord, lhs: u8, rhs: u8) bool {
            return ctx[rhs].y < ctx[lhs].y;
        }
    }.f;

    const coords_slice: []const PixelCoord = &pixel_coords;

    std.mem.sort(u8, &ret, coords_slice, greaterY);
    return ret;
}

fn colorComponentTou32(color: f32, shift: u5) u32 {
    return @as(u32, @intFromFloat(std.math.clamp(color * 255.0, 0.0, 255.0))) << shift;
}

fn vec4ColorToU32(color: Vec4) u32 {
    var frag_color_u32: u32 = 0;
    frag_color_u32 |= colorComponentTou32(color[2], 0); // b
    frag_color_u32 |= colorComponentTou32(color[1], 8); // g
    frag_color_u32 |= colorComponentTou32(color[0], 16); // r
    frag_color_u32 |= colorComponentTou32(color[3], 24); // a
    return frag_color_u32;
}

fn rasterizeTriangles(alloc: Allocator, vert_outputs: shader.ShaderOutput, frag_shader: shader.Shader, texture: Texture) !void {
    const rasterizer = TriangleRasterizer {
        .alloc = alloc,
        .texture_data_u32 = @alignCast(std.mem.bytesAsSlice(u32, texture.data)),
        .texture_height_px = texture.calcHeight(),
        .texture_width_px = texture.width_px,
        .frag_shader = frag_shader,
    };

    for (0..vert_outputs.marked.len / 3) |triangle_idx| {
        const base = triangle_idx * 3;

        const coords: [3]Vec4 = .{
            vert_outputs.marked[base].vec4,
            vert_outputs.marked[base + 1].vec4,
            vert_outputs.marked[base + 2].vec4,
        };

        // FIXME: What if the shader has no inputs
        // FIXME: What if the input is not a vec3
        const frag_inputs: [3]shader.Variable = .{
            vert_outputs.unmarked[base].?,
            vert_outputs.unmarked[base + 1].?,
            vert_outputs.unmarked[base + 2].?,
        };

        const pixel_coords = homogeneousToPixelCoords(
            coords,
            rasterizer.texture_width_px,
            rasterizer.texture_height_px,
        );

        const sorted_indices = sortCoordsByPixelY(pixel_coords);

        try rasterizer.rasterizeTriangle(.{
            pixel_coords[sorted_indices[0]],
            pixel_coords[sorted_indices[1]],
            pixel_coords[sorted_indices[2]],
        }, .{
            frag_inputs[sorted_indices[0]],
            frag_inputs[sorted_indices[1]],
            frag_inputs[sorted_indices[2]],
        });
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
