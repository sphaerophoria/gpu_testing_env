const std = @import("std");
const lib = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const base_alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(base_alloc);
    defer arena.deinit();

    const alloc = arena.allocator();

    _ = try alloc.alloc(u8, 1 * 1024 * 1024);
    _ = arena.reset(.retain_capacity);

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const recording_path = args[1];
    const output_path = args[2];

    const f = try std.fs.cwd().openFile(recording_path, .{});
    defer f.close();

    var br = std.io.bufferedReader(f.reader());
    var jr = std.json.reader(alloc, br.reader());
    defer jr.deinit();

    var parsed = try std.json.parseFromTokenSource(lib.GraphicsPipelineInputs, alloc, &jr, .{});
    defer parsed.deinit();

    const start_time = try std.time.Instant.now();
    try parsed.value.execute(alloc);
    const end_time = try std.time.Instant.now();
    std.debug.print("Executed in {d}s\n", .{@as(f32, @floatFromInt(end_time.since(start_time))) / std.time.ns_per_s });

    const image_height = parsed.value.texture.calcHeight();
    const image_stride = parsed.value.texture.calcStride();
    const output_f = try std.fs.cwd().createFile(output_path, .{});
    defer output_f.close();

    var bw = std.io.bufferedWriter(output_f.writer());
    defer bw.flush() catch {};

    const output_writer = bw.writer();
    try output_writer.print("P6\n{d} {d}\n255\n", .{parsed.value.texture.width_px, image_height});
    for (0..image_height) |y| {
        for (0..parsed.value.texture.width_px) |x| {
            const start = y * image_stride + x * 4;
            try output_writer.writeByte(parsed.value.texture.data[start + 2]);
            try output_writer.writeByte(parsed.value.texture.data[start + 1]);
            try output_writer.writeByte(parsed.value.texture.data[start + 0]);
        }
    }
}
