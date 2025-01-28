const std = @import("std");
const btree_mod = @import("btree.zig");
const BTree = btree_mod.BTree;


pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var rng = std.Random.DefaultPrng.init(0);
    const num_elems = 100000;
    var insert_sequence: [num_elems]i32 = undefined;
    for (0..num_elems) |i| {
        insert_sequence[i] = @intCast(i);
    }
    rng.random().shuffle(i32, &insert_sequence);

    var btree = try BTree(4, i32).init(alloc);

    {
        var buf: [4096]u8 = undefined;
        var tmp_alloc = std.heap.FixedBufferAllocator.init(&buf);

        const start = try std.time.Instant.now();
        for (insert_sequence) |i| {
            try btree.insert(tmp_alloc.allocator(), i);
        }
        const end = try std.time.Instant.now();

        //Took 25022us
        //Took 23498us
        //Took 28821us
        //Took 27218us
        //Took 24015us
        //Took 33312us
        //Took 30932us
        //Took 35405us
        //Took 40703us
        //Took 39671us
        //Took 27228us
        //Took 32513us
        //Took 29478us
        //Took 38524us
        std.debug.print("Took {d}us\n", .{end.since(start) / std.time.ns_per_us});
    }

}
