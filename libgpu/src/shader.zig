const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("global.zig");
const lin = @import("lin.zig");
const Vec2 = lin.Vec2;
const Vec3 = lin.Vec3;
const Vec4 = lin.Vec4;
const libgpu = @import("lib.zig");

const ReferenceType = enum {
    input,
    output,
    variable,
};

const Reference = struct {
    source: ReferenceType,
    index: u32,
};

const ChannelReference = struct {
    source: ReferenceType,
    index: u32,
    sub_index: u32,
};

const VariableType = enum {
    vec2,
    vec3,
    vec4,
    u32,
    reference,
    channel_reference,
    unassigned,
};

pub const Variable = union(VariableType) {
    vec2: Vec2,
    vec3: Vec3,
    vec4: Vec4,
    // FIXME: This should just store that it's 4 bytes, and cast when necessary
    u32: u32,
    reference: Reference,
    channel_reference: ChannelReference,
    unassigned,


    pub fn asi32(self: Variable) !i32 {
        return self.as32(i32);
    }

    pub fn asu32(self: Variable) !u32 {
        return self.as32(u32);
    }

    pub fn asf32(self: Variable) !f32 {
        return self.as32(f32);
    }

    pub fn asvec2(self: Variable) !Vec2 {
        if (self != .vec2) {
            return error.InvalidType;
        }
        return self.vec2;
    }

    fn as32(self: Variable, comptime T: type) !T {
        if (self != .u32) {
            return error.InvalidType;
        }

        return @bitCast(self.u32);
    }
};

const Command = union(enum) {
    load_reference: struct {
        id: u32,
        reference: Reference,
    },
    load_channel_ref: struct {
        id: u32,
        reference: ChannelReference,
    },
    load_ubo_vec4: struct {
        id: u32,
        a: u32, // Likely which ubo
        b: u32, // Likely offset within ubo
    },
    load_constant: struct {
        id: u32,
        val: Variable,
    },
    load: struct {
        input: u32,
        output: u32,
    },
    store: struct {
        input: u32,
        output: u32,
    },
    mov4: struct {
        input: [4]ChannelReference,
        output: u32,
    },
    fmul: struct {
        a: u32,
        b: u32,
        output: u32,
    },
    fmul_by_v4_swizzle: struct {
        a: u32,
        b: [4]ChannelReference,
        output: u32,
    },
    fsin: struct {
        input: u32,
        output: u32,
    },
    fadd: struct {
        a: u32,
        b: u32,
        output: u32,
    },
    iadd: struct {
        a: u32,
        b: u32,
        output: u32,
    },
    sample_tex: struct {
        src: u32,
        output: u32,
    },
};

pub const ShaderInput = struct {
    typ: VariableType,
    offs: u32,
    stride: u32,
};


pub const ShaderOutput = struct {
    marked: []Variable,
    unmarked: []?Variable,

    pub fn deinit(self: ShaderOutput, alloc: Allocator) void {
        alloc.free(self.marked);
        alloc.free(self.unmarked);
    }
};

pub const SingleShaderOutput = struct {
    marked: Variable,
    // FIXME: This only supports a shader with 1 or 2 outputs
    unmarked: ?Variable,
};

const ShaderExecutor = struct {
    alloc: Allocator,
    shader: Shader,

    pub fn executeOnBuf(self: ShaderExecutor, input_data: []const u8, input_defs: []const ShaderInput, ubo: []const u8, sampler_texture: libgpu.Texture, num_indices: usize) !ShaderOutput {
        const marked_outputs = try self.alloc.alloc(Variable, num_indices);
        const unmarked_outputs = try self.alloc.alloc(?Variable, num_indices);

        for (0..num_indices) |group_idx| {
            const input_group = try extractInputsFromBuf(self.alloc, group_idx, input_data, input_defs);
            defer self.alloc.free(input_group);

            const one_ret =  try self.executeOnInputs(input_group, ubo, sampler_texture);

            marked_outputs[group_idx] = one_ret.marked;
            unmarked_outputs[group_idx] = one_ret.unmarked;
        }
        return .{
            .marked = marked_outputs,
            .unmarked = unmarked_outputs,
        };
    }

    // inputs may be modified
    pub fn executeOnInputs(self: ShaderExecutor, inputs: []Variable, ubo: []const u8, sampler_texture: libgpu.Texture) !SingleShaderOutput {
        const outputs = try makeShaderOutputs(self.alloc, self.shader.output_types);
        defer self.alloc.free(outputs);

        var ssas = std.AutoHashMapUnmanaged(u32, Variable){};
        try ssas.ensureTotalCapacity(self.alloc, @intCast(self.shader.commands.len));
        defer ssas.deinit(self.alloc);

        for (self.shader.commands) |command| {
            switch (command) {
                .load_reference => |l| {
                    try ssas.put(self.alloc, l.id, .{ .reference = l.reference });
                },
                .load_constant => |l| {
                    try ssas.put(self.alloc, l.id, l.val);
                },
                .load_channel_ref => |l| {
                    try ssas.put(self.alloc, l.id, .{ .channel_reference = l.reference });
                },
                .load => |d| {
                    const input = ssas.get(d.input) orelse return error.InvalidReference;
                    const reference_ptr = try resolveReference(inputs, outputs, try variableAsReference(input));
                    try ssas.put(self.alloc, d.output, reference_ptr.*);
                },
                .store => |s| {
                    const input = ssas.get(s.input) orelse return error.InvalidReference;
                    const output = ssas.get(s.output) orelse return error.InvalidReference;
                    const reference_ptr = try resolveReference(inputs, outputs, try variableAsReference(output));
                    reference_ptr.* = input;
                },
                .mov4 => |m| {
                    const x = try resolveChannelRef(m.input[0], inputs, outputs, ssas);
                    const y = try resolveChannelRef(m.input[1], inputs, outputs, ssas);
                    const z = try resolveChannelRef(m.input[2], inputs, outputs, ssas);
                    const w = try resolveChannelRef(m.input[3], inputs, outputs, ssas);
                    try ssas.put(self.alloc, m.output, .{ .vec4 = .{x, y, z, w }});
                },
                .fsin => |f| {
                    const input = ssas.get(f.input) orelse return error.InvalidReference;
                    const output: f32 = @sin(try input.asf32());
                    try ssas.put(self.alloc, f.output , .{ .u32 = @bitCast(output) });
                },
                .fmul => |f| {
                    const a = ssas.get(f.a) orelse return error.InvalidReference;
                    const b = ssas.get(f.b) orelse return error.InvalidReference;
                    const output = try a.asf32() * try b.asf32();
                    try ssas.put(self.alloc, f.output , .{ .u32 = @bitCast(output)});
                },
                .fmul_by_v4_swizzle => |f| {
                    const a_var = ssas.get(f.a) orelse return error.InvalidReference;
                    if (a_var != .vec4) {
                        return error.InvalidType;
                    }
                    const a = a_var.vec4;
                    const b = Vec4{
                        try resolveChannelRef(f.b[0], inputs, outputs, ssas),
                        try resolveChannelRef(f.b[1], inputs, outputs, ssas),
                        try resolveChannelRef(f.b[2], inputs, outputs, ssas),
                        try resolveChannelRef(f.b[3], inputs, outputs, ssas),
                    };

                    try ssas.put(self.alloc, f.output, .{ .vec4 = a * b });
                },
                .iadd => |instr| {
                    const a = ssas.get(instr.a) orelse return error.InvalidReference;
                    const b = ssas.get(instr.b) orelse return error.InvalidReference;
                    const output = try a.asi32() + try b.asi32();
                    try ssas.put(self.alloc, instr.output , .{ .u32 = @bitCast(output)});
                },
                .load_ubo_vec4 => |lub| {
                    const a = ssas.get(lub.a) orelse return error.InvalidReference;
                    const b = ssas.get(lub.b) orelse return error.InvalidReference;
                    std.debug.assert(try a.asu32() == 0); // Only have one ubo :)

                    const v4_size = 16;
                    const start = try b.asu32() * v4_size;
                    const end = start + v4_size;

                    const out = std.mem.bytesToValue(Vec4, ubo[start..end]);
                    try ssas.put(self.alloc, lub.id, .{ .vec4 = out });
                },
                .fadd => |f| {
                    const a = ssas.get(f.a) orelse return error.InvalidReference;
                    const b = ssas.get(f.b) orelse return error.InvalidReference;

                    switch (a) {
                        .vec4 => |v| {
                            if (b != .vec4) {
                                return error.InvalidAdd;
                            }
                            try ssas.put(self.alloc, f.output, .{ .vec4 = v + b.vec4 });
                        },
                        else => {
                            std.log.err("Unimplemented fadd for type: {s}", .{@tagName(a)});
                            @panic("Unimplemented");
                        },
                    }
                },
                .sample_tex => |t| {
                    const height = sampler_texture.calcHeight();
                    const stride = sampler_texture.calcStride();
                    const src = ssas.get(t.src) orelse return error.InvalidReference;
                    const uv = src.vec2;
                    const x: i64 = @intFromFloat(uv[0] * @as(f32, @floatFromInt(sampler_texture.width_px)));
                    const y: i64 = @intFromFloat(uv[1] * @as(f32, @floatFromInt(height)));
                    const y_u: usize = @intCast(@mod(y, height));
                    const x_u: usize = @intCast(@mod(x, sampler_texture.width_px));
                    const start = y_u * stride + x_u * 4;

                    const r: f32 = @floatFromInt(sampler_texture.data[start + 2]);
                    const g: f32 = @floatFromInt(sampler_texture.data[start + 1]);
                    const b: f32 = @floatFromInt(sampler_texture.data[start + 0]);
                    const a: f32 = @floatFromInt(sampler_texture.data[start + 3]);

                    try ssas.put(self.alloc, t.output, .{ .vec4 = .{
                        r / 255.0,
                        g / 255.0,
                        b / 255.0,
                        a / 255.0,
                    }});
                },
            }
        }

        const unmarked: ?Variable  = if (outputs.len > 1) outputs[(self.shader.marked_output_pos + 1) % outputs.len] else null;

        return .{
            .marked = outputs[self.shader.marked_output_pos],
            .unmarked = unmarked,
        };
    }

    fn resolveReference(inputs: []Variable, outputs: []Variable, reference: Reference) !*Variable {
        return switch (reference.source) {
            .input => &inputs[reference.index],
            .output => &outputs[reference.index],
            .variable => return error.Unimplemented,
        };
    }

    fn resolveChannelRef(ref: ChannelReference, inputs: []Variable, outputs: []Variable, ssas: std.AutoHashMapUnmanaged(u32, Variable)) !f32 {
        const val = switch (ref.source) {
            .input => inputs[ref.index],
            .output => outputs[ref.index],
            .variable => ssas.get(ref.index) orelse return error.InvalidReference,
        };

        switch (val) {
            .vec2 => |v| return v[ref.sub_index],
            .vec3 => |v| return v[ref.sub_index],
            .vec4 => |v| return v[ref.sub_index],
            .u32 => |v| {
                std.debug.assert(ref.sub_index == 0);
                return @bitCast(v);
            },
            else => {
                std.log.err("unhandled ref type {any}", .{val});
                return error.Unimplemented;
            }
        }
    }
};


fn variableAsReference(variable: Variable) !Reference {
    if (variable != .reference) {
        return error.ReferenceNotReference;
    }
    return variable.reference;
}

fn extractInputsFromBuf(alloc: Allocator, group_idx: usize, input_data: []const u8, input_defs: []const ShaderInput) ![]Variable {
    const inputs = try alloc.alloc(Variable, input_defs.len);
    errdefer alloc.free(inputs);

    for (input_defs, 0..) |def, input_idx| {
        const input_start = def.offs + def.stride * group_idx;
        inputs[input_idx] = switch(def.typ) {
            .u32 => blk: {
                const input_end = input_start + @sizeOf(u32);
                break :blk .{
                    .u32 = std.mem.bytesToValue(u32, input_data[input_start..input_end])
                };
            },
            .vec2 => blk: {
                const input_end = input_start + @sizeOf(Vec2);
                break :blk .{
                    .vec2 = std.mem.bytesToValue(Vec2, input_data[input_start..input_end])
                };
            },
            .vec3 => blk: {
                const input_end = input_start + @sizeOf(Vec3);
                break :blk .{
                    .vec3 = std.mem.bytesToValue(Vec3, input_data[input_start..input_end])
                };
            },
            .vec4 => blk: {
                const input_end = input_start + @sizeOf(Vec4);
                break :blk .{
                    .vec4 = std.mem.bytesToValue(Vec4, input_data[input_start..input_end])
                };
            },
            else => return error.UnimplementedInputParser,
        };
    }

    return inputs;
}

fn makeShaderOutputs(alloc: Allocator, output_types: []VariableType) ![]Variable {
    const outputs = try alloc.alloc(Variable, output_types.len);
    @memset(outputs, .unassigned);
    return outputs;
}

pub const Shader = struct {
    commands: []Command,
    input_types: []VariableType,
    output_types: []VariableType,
    marked_output_pos: usize,

    pub fn load(alloc: Allocator, data: []const u8) !Shader {
        const val = try std.json.parseFromSlice(Shader, alloc, data, .{});
        defer val.deinit();

        return .{
            .commands = try alloc.dupe(Command, val.value.commands),
            .input_types = try alloc.dupe(VariableType, val.value.input_types),
            .output_types = try alloc.dupe(VariableType, val.value.output_types),
            .marked_output_pos = val.value.marked_output_pos,
        };
    }

    pub fn deinit(self: Shader, alloc: Allocator) void {
        alloc.free(self.commands);
        alloc.free(self.input_types);
        alloc.free(self.output_types);
    }

    pub fn executeOnBuf(self: Shader, alloc: Allocator, vertex_buf: []const u8, format: []ShaderInput, ubo: []const u8,  sampler_texture: libgpu.Texture, num_elems: usize) !ShaderOutput {
        const executor = ShaderExecutor {
            .alloc = alloc,
            .shader = self,
        };

        return try executor.executeOnBuf(vertex_buf, format, ubo, sampler_texture, num_elems);
    }

    pub fn executeOnInputs(self: Shader, alloc: Allocator, inputs: []Variable, ubo: []const u8, sampler_texture: libgpu.Texture) !SingleShaderOutput {
        const executor = ShaderExecutor {
            .alloc = alloc,
            .shader = self,
        };

        return try executor.executeOnInputs(inputs, ubo, sampler_texture);
    }
};

pub const ShaderBuilder = struct {
    alloc: Allocator,

    commands: std.ArrayListUnmanaged(Command) = .{},
    input_types: std.ArrayListUnmanaged(VariableType) = .{},
    output_types: std.ArrayListUnmanaged(VariableType) = .{},
    marked_output_pos: usize = 0,

    pub fn deinit(self: *ShaderBuilder) void {
        self.input_types.deinit(self.alloc);
        self.output_types.deinit(self.alloc);
        self.commands.deinit(self.alloc);
    }

    pub fn pushInput(self: *ShaderBuilder, input: VariableType) !void {
        try self.input_types.append(self.alloc, input);
    }

    pub fn pushOutput(self: *ShaderBuilder, output: VariableType) !void {
        try self.output_types.append(self.alloc, output);
    }

    pub fn pushCommand(self: *ShaderBuilder, command: Command) !void {
        try self.commands.append(self.alloc, command);
    }

    pub fn compile(self: ShaderBuilder) ![]u8 {
        const to_stringify = Shader {
            .commands = self.commands.items,
            .input_types = self.input_types.items,
            .output_types =  self.output_types.items,
            .marked_output_pos = self.marked_output_pos,
        };

        var output = std.ArrayList(u8).init(self.alloc);
        const writer = output.writer();
        try std.json.stringify(to_stringify, .{
            .whitespace = .indent_2,
        }, writer);
        std.debug.print("shader: \"{s}\"", .{output.items});

        return try output.toOwnedSlice();
    }
};

test "shader basic execution" {
    const alloc = std.testing.allocator;
    var shader_builder = ShaderBuilder {
        .alloc = alloc,
    };
    defer shader_builder.deinit();

    try shader_builder.pushInput(.vec3);
    try shader_builder.pushOutput(.vec4);

    try shader_builder.pushCommand(.{
        .load_reference = .{
            .id = 0,
            .reference = .{
                .source = .input,
                .index = 0,
            },
        },
    });

    try shader_builder.pushCommand(.{
        .load = .{
            .input = 0,
            .output = 1,
        },
    });

    try shader_builder.pushCommand(.{
        .load_constant = .{
            .id = 2,
            .val = .{
                .f32 = 1.0,
            },
        },
    });

    try shader_builder.pushCommand(.{
        .load_reference = .{
            .id = 3,
            .reference = .{
                .source = .output,
                .index = 0,
            },
        },
    });

    try shader_builder.pushCommand(.{
        .mov4 = .{
            .input = .{
                .{
                    .source = .variable,
                    .index = 1,
                    .sub_index = 0,
                },
                .{
                    .source = .variable,
                    .index = 1,
                    .sub_index = 1,
                },
                .{
                    .source = .variable,
                    .index = 1,
                    .sub_index = 2,
                },
                .{
                    .source = .variable,
                    .index = 2,
                    .sub_index = 0,
                },
            },
            .output = 4,
        },
    });

    try shader_builder.pushCommand(.{
        .store = .{
            .input = 4,
            .output = 3,
        },
    });

    const shader_data = try shader_builder.compile();
    defer alloc.free(shader_data);

    const shader = try Shader.load(alloc, shader_data);
    defer shader.deinit(alloc);

    const input_buf: []const f32 = &[_]f32{
        1.0, 2.0, 3.0,
        2.0, 5.0, 8.0,
        3.0, 6.0, 9.0,
        4.0, 7.0, 10.0,
    };

    var shader_inputs = [_]ShaderInput {
        .{
            .typ = .vec3,
            .offs = 0,
            .stride = 12
        }
    };
    const outputs = try shader.executeOnBuf(alloc, std.mem.sliceAsBytes(input_buf), &shader_inputs, 4);
    defer alloc.free(outputs);

    try std.testing.expectEqual(4, outputs.len);
    try std.testing.expectEqualSlices(Variable,
        &[_]Variable{
            .{ .vec4 = .{ 1.0, 2.0, 3.0, 1.0 }, },
            .{ .vec4 = .{ 2.0, 5.0, 8.0, 1.0 }, },
            .{ .vec4 = .{ 3.0, 6.0, 9.0, 1.0 }, },
            .{ .vec4 = .{ 4.0, 7.0, 10.0, 1.0 }, },
        }, outputs,
    );
}

