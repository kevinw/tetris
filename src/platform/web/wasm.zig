const std = @import("std");

pub extern fn getRandomSeed() c_uint;
pub extern fn getRandomString() [*]const u8;
pub extern fn consoleLog(_: c_int) void;
pub extern fn consoleLogF(_: f32) void;
pub extern fn consoleLogS(_: [*]const u8, _: c_uint) void;
pub extern fn fetchBytes(_: [*]const u8, _: c_uint) void;

pub export fn _wasm_alloc(len: usize) u32 {
    var buf = std.heap.wasm_allocator.alloc(u8, len) catch |err| return 0;
    return @ptrToInt(buf.ptr);
}
