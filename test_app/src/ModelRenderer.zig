const std = @import("std");
const Allocator = std.mem.Allocator;

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "");
    @cInclude("GL/gl.h");
});
const stbi = @cImport({
    @cInclude("stb_image.h");
});
const ModelRenderer = @This();

model_transform: Mat4 = Mat4.identity(),
fov: f32 = std.math.pi / 8.0,
x_rot: f32 = 0.0,
y_rot: f32 = 0.0,
buffers: BufferPair,
program: gl.GLuint,
num_vertices: c_int,
transform_loc: c_int,
texture: gl.GLuint,

pub fn init(alloc: Allocator) !ModelRenderer {
    var model = try Model.load(alloc, @embedFile("ModelRenderer/model.obj"));
    defer model.deinit(alloc);

    const buffers = try bindModel(alloc, model);
    //errdefer buffers.deinit();

    var img = try Img.init(@embedFile("ModelRenderer/model.png"));
    defer img.deinit();

    const texture = texFromImg(img);
    //errdefer gl.glDeleteTextures(1, &texture);

    const program = try compileLinkProgram(
        @embedFile("ModelRenderer/vertex.glsl"),
        @embedFile("ModelRenderer/fragment.glsl"),
    );
    errdefer gl.glDeleteProgram(program);

    const transform_loc = gl.glGetUniformLocation(program, "transform");
    const num_vertices: c_int = @intCast(model.faces.len * 3);

    return .{
        .buffers = buffers,
        .program = program,
        .transform_loc = transform_loc,
        .num_vertices = num_vertices,
        .texture = texture,
    };
}

pub fn deinit(self: *ModelRenderer) void {
    self.buffers.deinit();
    gl.glDeleteTextures(1, &self.texture);
    gl.glDeleteProgram(self.program);
}

pub fn render(self: *ModelRenderer, aspect: f32) void {
    gl.glUseProgram(self.program);
    gl.glBindVertexArray(self.buffers.vao);
    gl.glActiveTexture(gl.GL_TEXTURE0); // activate the texture unit first before binding texture
    gl.glBindTexture(gl.GL_TEXTURE_2D, self.texture);

    const perspective = Mat4.perspective(self.fov, 0.1, aspect);
    const transform = perspective.matmul(Mat4.translation(0.0, 0.0, -10.0).matmul(self.model_transform));
    gl.glUniformMatrix4fv(self.transform_loc, 1, 1, @ptrCast(&transform));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, self.num_vertices);
}

pub fn rotate(self: *ModelRenderer, x_amount: f32, y_amount: f32) void {
    self.x_rot += x_amount;
    self.y_rot += y_amount;
    self.x_rot = @mod(self.x_rot, 2 * std.math.pi);
    self.y_rot = @mod(self.y_rot, 2 * std.math.pi);
    const x_transform = Mat4.rotAroundY(self.x_rot);
    const y_transform = Mat4.rotAroundX(self.y_rot);
    self.model_transform = y_transform.matmul(x_transform);
}

fn compileLinkProgram(vs: []const u8, fs: []const u8) !gl.GLuint {
    const vertex_shader = gl.glCreateShader(gl.GL_VERTEX_SHADER);
    const vs_len_i: i32 = @intCast(vs.len);
    gl.glShaderSource(vertex_shader, 1, &vs.ptr, &vs_len_i);
    gl.glCompileShader(vertex_shader);

    var success: c_int = 0;
    gl.glGetShaderiv(vertex_shader, gl.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var buf: [1024]u8 = undefined;
        var print_len: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(vertex_shader, @intCast(buf.len), &print_len, &buf);
        std.log.err("Vertex shader compilation failed", .{});
        std.log.err("{s}", .{buf[0..@intCast(print_len)]});
        return error.VertexShaderCompile;
    }

    const fragment_shader = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
    const fs_len_i: i32 = @intCast(fs.len);
    gl.glShaderSource(fragment_shader, 1, &fs.ptr, &fs_len_i);
    gl.glCompileShader(fragment_shader);
    gl.glGetShaderiv(fragment_shader, gl.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var buf: [1024]u8 = undefined;
        var print_len: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(fragment_shader, @intCast(buf.len), &print_len, &buf);
        std.log.err("Fragment shader compilation failed", .{});
        std.log.err("{s}", .{buf[0..@intCast(print_len)]});
        return error.FragmentShaderCompile;
    }

    const program = gl.glCreateProgram();
    gl.glAttachShader(program, vertex_shader);
    gl.glAttachShader(program, fragment_shader);
    gl.glLinkProgram(program);
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &success);
    if (success != 1) {
        var buf: [1024]u8 = undefined;
        var print_len: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(program, @intCast(buf.len), &print_len, &buf);
        std.log.err("Linking program failed", .{});
        std.log.err("{s}", .{buf[0..@intCast(print_len)]});
        return error.LinkProgram;
    }
    return program;
}

const Vec4 = struct {
    inner: [4]f32,

    fn dot(a: Vec4, b: Vec4) f32 {
        var sum: f32 = 0;
        for (0..4) |i| {
            sum += a.inner[i] * b.inner[i];
        }
        return sum;
    }
};

const Mat4 = struct {
    inner: [4]Vec4,

    fn matmul(self: Mat4, mat: Mat4) Mat4 {
        var ret: Mat4 = undefined;
        for (0..4) |y| {
            for (0..4) |x| {
                var sum: f32 = 0;
                for (0..4) |i| {
                    const a = self.inner[y].inner[i];
                    const b = mat.inner[i].inner[x];
                    sum += a * b;
                }

                ret.inner[y].inner[x] = sum;
            }
        }

        return ret;
    }

    fn mul(self: Mat4, vec: Vec4) Vec4 {
        return .{ .inner = .{
            self.inner[0].dot(vec),
            self.inner[1].dot(vec),
            self.inner[2].dot(vec),
            self.inner[3].dot(vec),
        } };
    }

    fn rotAroundY(rot: f32) Mat4 {
        const cos = @cos(rot);
        const sin = @sin(rot);
        const inner: [4]Vec4 = .{
            .{ .inner = .{ cos, 0, -sin, 0 } },
            .{ .inner = .{ 0, 1, 0, 0 } },
            .{ .inner = .{ sin, 0, cos, 0 } },
            .{ .inner = .{ 0, 0, 0, 1 } },
        };
        return .{ .inner = inner };
    }

    fn rotAroundX(rot: f32) Mat4 {
        const cos = @cos(rot);
        const sin = @sin(rot);
        const inner: [4]Vec4 = .{
            .{ .inner = .{ 1, 0, 0, 0 } },
            .{ .inner = .{ 0, cos, -sin, 0 } },
            .{ .inner = .{ 0, sin, cos, 0 } },
            .{ .inner = .{ 0, 0, 0, 1 } },
        };
        return .{ .inner = inner };
    }

    // https://www.songho.ca/opengl/gl_projectionmatrix.html
    fn perspective(fov: f32, n: f32, aspect: f32) Mat4 {
        const t = @tan(fov / 2) * n;
        const r = t * aspect;

        const inner: [4]Vec4 = .{
            .{ .inner = .{ n / r, 0, 0, 0 } },
            .{ .inner = .{ 0, n / t, 0, 0 } },
            .{ .inner = .{ 0, 0, -1, -2 * n } },
            .{ .inner = .{ 0, 0, -1, 0 } },
        };

        return Mat4{
            .inner = inner,
        };
    }

    fn translation(x: f32, y: f32, z: f32) Mat4 {
        return .{ .inner = .{
            .{ .inner = .{ 1.0, 0, 0, x } },
            .{ .inner = .{ 0, 1.0, 0, y } },
            .{ .inner = .{ 0, 0, 1.0, z } },
            .{ .inner = .{ 0, 0, 0.0, 1.0 } },
        } };
    }

    fn scale(x: f32, y: f32, z: f32) Mat4 {
        return .{ .inner = .{
            .{ .inner = .{ x, 0, 0, 0 } },
            .{ .inner = .{ 0, y, 0, 0 } },
            .{ .inner = .{ 0, 0, z, 0 } },
            .{ .inner = .{ 0, 0, 0.0, 1.0 } },
        } };
    }

    fn identity() Mat4 {
        return .{ .inner = .{
            .{ .inner = .{ 1.0, 0, 0, 0 } },
            .{ .inner = .{ 0, 1.0, 0, 0 } },
            .{ .inner = .{ 0, 0, 1.0, 0 } },
            .{ .inner = .{ 0, 0, 0.0, 1.0 } },
        } };
    }
};

test "matmul" {
    const a = Mat4{
        .inner = .{
            .{ .inner = .{ 0, 1, 2, 3 } },
            .{ .inner = .{ 4, 5, 6, 7 } },
            .{ .inner = .{ 8, 9, 10, 11 } },
            .{ .inner = .{ 12, 13, 14, 15 } },
        },
    };

    const b = Mat4{
        .inner = .{
            .{ .inner = .{ 1, 2, 3, 4 } },
            .{ .inner = .{ 5, 6, 7, 8 } },
            .{ .inner = .{ 9, 10, 11, 12 } },
            .{ .inner = .{ 13, 14, 15, 16 } },
        },
    };

    const ret = a.matmul(b);
    const expected = Mat4{ .inner = .{
        .{ .inner = .{ 62, 68, 74, 80 } },
        .{ .inner = .{ 174, 196, 218, 240 } },
        .{ .inner = .{ 286, 324, 362, 400 } },
        .{ .inner = .{ 398, 452, 506, 560 } },
    } };

    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(expected.inner[0].inner[i], ret.inner[0].inner[i], 0.001);
        try std.testing.expectApproxEqAbs(expected.inner[1].inner[i], ret.inner[1].inner[i], 0.001);
        try std.testing.expectApproxEqAbs(expected.inner[2].inner[i], ret.inner[2].inner[i], 0.001);
        try std.testing.expectApproxEqAbs(expected.inner[3].inner[i], ret.inner[3].inner[i], 0.001);
    }
}

test "matvecmul" {
    const a = Mat4{
        .inner = .{
            .{ .inner = .{ 0, 1, 2, 3 } },
            .{ .inner = .{ 4, 5, 6, 7 } },
            .{ .inner = .{ 8, 9, 10, 11 } },
            .{ .inner = .{ 12, 13, 14, 15 } },
        },
    };

    const b = Vec4{ .inner = .{ 1, 2, 3, 4 } };

    const ret = a.mul(b);
    const expected = Vec4{ .inner = .{
        0 + 2 + 6 + 12,
        4 + 10 + 18 + 28,
        8 + 18 + 30 + 44,
        12 + 26 + 42 + 60,
    } };

    try std.testing.expectApproxEqAbs(expected.inner[0], ret.inner[0], 0.001);
    try std.testing.expectApproxEqAbs(expected.inner[1], ret.inner[1], 0.001);
    try std.testing.expectApproxEqAbs(expected.inner[2], ret.inner[2], 0.001);
    try std.testing.expectApproxEqAbs(expected.inner[3], ret.inner[3], 0.001);
}

const Vert = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Uv = struct {
    u: f32,
    v: f32,
};

const Face = struct {
    vert_ids: [3]u32,
    uv_ids: [3]u32,
};

fn nextAsF32(it: anytype) !f32 {
    const s = it.next() orelse return error.InvalidF32;
    return try std.fmt.parseFloat(f32, s);
}

const Model = struct {
    // Grouped in 3s
    verts: []Vert,
    // Grouped in 2s
    uvs: []Uv,
    // Grouped in 3s, indexes into vertices
    faces: []Face,

    fn deinit(self: *Model, alloc: Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.uvs);
        alloc.free(self.faces);
    }

    fn load(alloc: Allocator, data: []const u8) !Model {
        var line_it = std.mem.splitScalar(u8, data, '\n');

        var verts = std.ArrayList(Vert).init(alloc);
        defer verts.deinit();

        var uvs = std.ArrayList(Uv).init(alloc);
        defer uvs.deinit();

        var faces = std.ArrayList(Face).init(alloc);
        defer faces.deinit();

        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, "v ")) {
                var vert_it = std.mem.splitScalar(u8, line, ' ');
                _ = vert_it.next();

                const vert = Vert{
                    .x = try nextAsF32(&vert_it),
                    .y = try nextAsF32(&vert_it),
                    .z = try nextAsF32(&vert_it),
                };

                try verts.append(vert);

                if (vert_it.next()) |_| {
                    std.log.warn("Unexpected 4th vertex dimension", .{});
                }
            } else if (std.mem.startsWith(u8, line, "vt ")) {
                var uv_it = std.mem.splitScalar(u8, line, ' ');
                _ = uv_it.next();

                const uv = Uv{
                    .u = try nextAsF32(&uv_it),
                    .v = try nextAsF32(&uv_it),
                };

                try uvs.append(uv);

                if (uv_it.next()) |_| {
                    std.log.warn("Unexpected 3rd uv dimension", .{});
                }
            } else if (std.mem.startsWith(u8, line, "f ")) {
                var face_it = std.mem.splitScalar(u8, line, ' ');
                _ = face_it.next();

                var vert_ids: [3]u32 = undefined;
                var uv_ids: [3]u32 = undefined;

                for (0..3) |i| {
                    const face = face_it.next() orelse return error.InvalidFace;
                    var component_it = std.mem.splitScalar(u8, face, '/');

                    const vert_id_s = component_it.next() orelse return error.NoFaceVertex;
                    const vert_id = try std.fmt.parseInt(u32, vert_id_s, 10) - 1;

                    const uv_id_s = component_it.next() orelse return error.NoFaceUV;
                    const uv_id = try std.fmt.parseInt(u32, uv_id_s, 10) - 1;

                    vert_ids[i] = vert_id;
                    uv_ids[i] = uv_id;
                }

                try faces.append(Face{
                    .vert_ids = vert_ids,
                    .uv_ids = uv_ids,
                });

                if (face_it.next()) |_| {
                    std.log.err("Faces should be triangulated", .{});
                    return error.NonTriangulatedMesh;
                }
            }
        }

        return .{
            .verts = try verts.toOwnedSlice(),
            .uvs = try uvs.toOwnedSlice(),
            .faces = try faces.toOwnedSlice(),
        };
    }
};

const BufferPair = struct {
    vao: gl.GLuint,
    vbo: gl.GLuint,

    pub fn deinit(self: *BufferPair) void {
        gl.glDeleteVertexArrays(1, &self.vao);
        gl.glDeleteBuffers(1, &self.vbo);
    }
};

fn bindModel(alloc: Allocator, model: Model) !BufferPair {
    var vertex_buffer = try std.ArrayList(f32).initCapacity(alloc, model.faces.len * 15);
    defer vertex_buffer.deinit();

    for (model.faces) |face| {
        for (0..3) |i| {
            const vert = model.verts[face.vert_ids[i]];
            const uv = model.uvs[face.uv_ids[i]];

            try vertex_buffer.appendSlice(&.{ vert.x, vert.y, vert.z, uv.u, uv.v });
        }
    }
    std.debug.assert(vertex_buffer.items.len == model.faces.len * 15);

    var vao: gl.GLuint = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);

    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);

    gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(@sizeOf(f32) * vertex_buffer.items.len), vertex_buffer.items.ptr, gl.GL_STATIC_DRAW);

    gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, 5 * @sizeOf(f32), @ptrFromInt(0));
    gl.glEnableVertexAttribArray(0);

    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 5 * @sizeOf(f32), @ptrFromInt(12));
    gl.glEnableVertexAttribArray(1);

    return .{
        .vao = vao,
        .vbo = vbo,
    };
}

const Img = struct {
    data: []u32,
    width: usize,

    pub fn init(data: []const u8) !Img {
        var width: c_int = 0;
        var height_out: c_int = 0;
        stbi.stbi_set_flip_vertically_on_load(1);
        const img_opt = stbi.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height_out, null, 4);
        const img_ptr: [*]u8 = img_opt orelse return error.FailedToOpen;
        const img_u32: [*]u32 = @ptrCast(@alignCast(img_ptr));

        return .{
            .data = img_u32[0..@intCast(width * height_out)],
            .width = @intCast(width),
        };
    }

    pub fn deinit(self: *Img) void {
        stbi.stbi_image_free(@ptrCast(self.data));
    }

    pub fn height(self: Img) usize {
        return self.data.len / self.width;
    }
};

fn texFromImg(img: Img) gl.GLuint {
    var texture: gl.GLuint = 0;
    gl.glGenTextures(1, &texture);

    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(img.width), @intCast(img.height()), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, img.data.ptr);

    return texture;
}
