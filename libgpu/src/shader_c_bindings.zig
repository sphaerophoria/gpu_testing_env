const std = @import("std");
const shader_mod = @import("shader.zig");
const global = @import("global.zig");
const lin = @import("lin.zig");
const ShaderBuilder = shader_mod.ShaderBuilder;
const ShaderInputBuilder = std.ArrayList(shader_mod.ShaderInput);
const Vec3 = lin.Vec3;
const Vec4 = lin.Vec4;

pub export fn libgpu_create_shader() ?*ShaderBuilder {
    const alloc = global.gpa.allocator();
    const shader = alloc.create(ShaderBuilder) catch return null;
    shader.* = ShaderBuilder { .alloc = alloc };
    return shader;
}

pub export fn libgpu_shader_push_input_float(shader: *ShaderBuilder) bool {
    shader.pushInput(.f32) catch return false;
    return true;
}

pub export fn libgpu_shader_push_input_vec3(shader: *ShaderBuilder) bool {
    shader.pushInput(.vec3) catch return false;
    return true;
}

pub export fn libgpu_shader_push_input_vec4(shader: *ShaderBuilder) bool {
    shader.pushInput(.vec4) catch return false;
    return true;
}

pub export fn libgpu_shader_push_output_float(shader: *ShaderBuilder) bool {
    shader.pushOutput(.f32) catch return false;
    return true;
}

pub export fn libgpu_shader_push_output_vec4(shader: *ShaderBuilder) bool {
    shader.pushOutput(.vec4) catch return false;
    return true;
}

pub export fn libgpu_shader_push_output_vec3(shader: *ShaderBuilder) bool {
    shader.pushOutput(.vec3) catch return false;
    return true;
}

pub export fn libgpu_shader_push_output_vertex_position(shader: *ShaderBuilder) bool {
    shader.marked_output_pos = shader.output_types.items.len;
    shader.pushOutput(.vec4) catch return false;
    return true;
}

pub export fn libgpu_shader_push_command_load_input_reference(shader: *ShaderBuilder, id: u32, input_idx: u32) bool {
    shader.pushCommand(.{
        .load_reference = .{
            .id = id,
            .reference = .{
                .source = .input,
                .index = input_idx,
            },
        },
    }) catch return false;
    return true;
}

pub export fn libgpu_shader_push_command_load_output_reference(shader: *ShaderBuilder, id: u32, output_idx: u32) bool {
    shader.pushCommand(.{
        .load_reference = .{
            .id = id,
            .reference = .{
                .source = .output,
                .index = output_idx,
            },
        },
    }) catch return false;
    return true;
}

pub export fn libgpu_shader_push_command_load_constant_f32(shader: *ShaderBuilder, id: u32, val: f32) bool {
    shader.pushCommand(.{
        .load_constant = .{
            .id = id,
            .val = .{
                .f32 = val,
            },
        },
    }) catch return false;
    return true;
}

pub export fn libgpu_shader_push_command_load_constant_vec4(shader: *ShaderBuilder, id: u32, x: f32, y: f32, z: f32, w: f32) bool {
    shader.pushCommand(.{
        .load_constant = .{
            .id = id,
            .val = .{
                .vec4 = .{ x, y, z, w },
            },
        },
    }) catch return false;
    return true;
}

pub export fn libgpu_shader_push_command_load(shader: *ShaderBuilder, src: u32, dest: u32) bool {
    shader.pushCommand(.{
        .load = .{
            .input = src,
            .output = dest,
        },
    }) catch return false;
    return true;
}

pub export fn libgpu_shader_push_command_store(shader: *ShaderBuilder, src: u32, dest: u32) bool {
    shader.pushCommand(.{
        .store = .{
            .input = src,
            .output = dest,
        },
    }) catch return false;
    return true;

}

pub export fn libgpu_shader_push_command_mov4(
    shader: *ShaderBuilder,
    id: u32,
    x_id: u32, x_sub_id: u8,
    y_id: u32, y_sub_id: u8,
    z_id: u32, z_sub_id: u8,
    w_id: u32, w_sub_id: u8
) bool {
    shader.pushCommand(.{
        .mov4 = .{
            .input = .{
                .{
                    .source = .variable,
                    .index = x_id,
                    .sub_index = x_sub_id,
                },
                .{
                    .source = .variable,
                    .index = y_id,
                    .sub_index = y_sub_id,
                },
                .{
                    .source = .variable,
                    .index = z_id,
                    .sub_index = z_sub_id,
                },
                .{
                    .source = .variable,
                    .index = w_id,
                    .sub_index = w_sub_id,
                },
            },
            .output = id,
        },
    }) catch return false;

    return true;
}

pub export fn  libgpu_shader_push_command_fsin(shader: *ShaderBuilder, id: u32, input_id: u32) bool {
    shader.pushCommand(.{
        .fsin = .{
            .input = input_id,
            .output = id,
        },
    }) catch return false;
    return true;
}

pub export fn  libgpu_shader_push_command_fmul(shader: *ShaderBuilder, id: u32, a_id: u32, b_id: u32) bool {
    shader.pushCommand(.{
        .fmul = .{
            .a = a_id,
            .b = b_id,
            .output = id,
        },
    }) catch return false;
    return true;
}

pub export fn libgpu_compile_shader(shader: *ShaderBuilder, data_opt: ?**anyopaque, len_opt: ?*usize) bool {
    const ret = shader.compile() catch return false;
    const data = data_opt orelse return false;
    const len = len_opt orelse return false;
    data.* = ret.ptr;
    len.* = ret.len;
    return true;
}

pub export fn libgpu_shader_create_input_defs() ?*ShaderInputBuilder {
    const alloc = global.gpa.allocator();
    const ret = alloc.create(ShaderInputBuilder) catch return null;
    ret.* = ShaderInputBuilder.init(alloc);
    return ret;
}

pub export fn libgpu_shader_free_input_defs(defs: ?*ShaderInputBuilder) void {
    const alloc = global.gpa.allocator();
    alloc.destroy(defs orelse return);
}

pub export fn libgpu_shader_input_defs_push_float(builder: *ShaderInputBuilder, offs: u32, stride: u32) bool {
    builder.append(.{
        .typ = .f32,
        .offs = offs,
        .stride = stride,
    }) catch return false;

    return true;
}

pub export fn libgpu_shader_input_defs_push_vec3(builder: *ShaderInputBuilder, offs: u32, stride: u32) bool {
    builder.append(.{
        .typ = .vec3,
        .offs = offs,
        .stride = stride,
    }) catch return false;

    return true;
}

pub export fn libgpu_shader_input_defs_push_vec4(builder: *ShaderInputBuilder, offs: u32, stride: u32) bool {
    builder.append(.{
        .typ = .vec4,
        .offs = offs,
        .stride = stride,
    }) catch return false;

    return true;
}

pub export fn libgpu_shader_input_compile(builder: *ShaderInputBuilder, out_data: ?**anyopaque, out_len: ?*usize) bool {
    const alloc = global.gpa.allocator();
    var output = std.ArrayList(u8).init(alloc);
    const writer = output.writer();
    if (out_data == null) {
        std.log.err("No output data", .{});
        return false;
    }
    if (out_len == null) {
        std.log.err("No output len", .{});
        return false;
    }
    std.json.stringify(builder.items, .{
        .whitespace = .indent_2,
    }, writer) catch {
        std.log.err("Failed to compile shader inputs", .{});
        return false;
    };

    const serialized = output.toOwnedSlice() catch {
        std.log.err("Failed to realloc shader input defs", .{});
        return false;
    };

    out_data.?.* = serialized.ptr;
    out_len.?.* = serialized.len;
    return true;
}
