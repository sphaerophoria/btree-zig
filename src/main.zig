const std = @import("std");
const Allocator = std.mem.Allocator;

const btree_mod = @import("btree.zig");
const BTree = btree_mod.BTree;


const Target = enum {
    @"/",
    @"/index.html",
    @"/index.js",
    @"/data",
    @"/step",
    @"/reset",
    @"/delete",
};

fn serveFile(alloc: Allocator, path: []const u8, req: *std.http.Server.Request) !void {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const data = try f.readToEndAlloc(alloc, 1<<20);
    defer alloc.free(data);

    try req.respond(data, .{});
}

fn serializeNode(json_writer: anytype, node: anytype) !void {
    try json_writer.beginArray();
    for (0..node.num_elems) |i| {
        try json_writer.write(node.elems[i]);
    }
    try json_writer.endArray();
}

fn serializeTree(alloc: Allocator, btree: anytype, worker: anytype) ![]const u8 {
    var ret = std.ArrayList(u8).init(alloc);

    var json_writer = std.json.writeStream(ret.writer(), .{.whitespace = .indent_2});
    try json_writer.beginObject();

    try json_writer.objectField("root_node");
    try json_writer.write(btree.root_node);

    try json_writer.objectField("node_capacity");
    try json_writer.write(@TypeOf(btree.*).node_capacity);

    switch (worker) {
        .inserter => |i| {
            try json_writer.objectField("to_insert");
            try json_writer.write(i.val);

            try json_writer.objectField("target");
            try json_writer.write(i.target);

            try json_writer.objectField("to_insert_child");
            if (i.in_progress_tree) |t| {
                try json_writer.write(t);
            } else {
                try json_writer.write(null);
            }
        },
        .deleter => |d| {
            switch (d.state) {
                .remove_val => |target_key| {
                    try json_writer.objectField("to_delete");
                    try json_writer.write(target_key);
                },
                .merge_nodes => |parent_key_idx| {
                    try json_writer.objectField("to_merge");

                    try json_writer.beginObject();

                    try json_writer.objectField("parent_node");
                    try json_writer.write(d.parent_stack.getLast());

                    try json_writer.objectField("key_idx");
                    try json_writer.write(parent_key_idx);

                    try json_writer.endObject();
                },
                .find_merge_target, .finished => {},

            }
        },
        .none => {},
    }

    try json_writer.objectField("inner_nodes");
    try json_writer.beginArray();

    for (btree.inner_nodes.items) |node| {
        try json_writer.beginObject();

        try json_writer.objectField("keys");
        try json_writer.beginArray();
        for (0..node.numKeys()) |i| {
            try json_writer.write(node.keys[i]);
        }
        try json_writer.endArray();

        try json_writer.objectField("children");
        try json_writer.beginArray();
        for (0..node.num_children) |i| {
            try json_writer.write(node.children[i]);
        }
        try json_writer.endArray();
        try json_writer.endObject();
    }

    try json_writer.endArray();

    try json_writer.objectField("leaf_nodes");
    try json_writer.beginArray();

    for (btree.leaf_nodes.items) |node| {
        try json_writer.beginObject();

        try json_writer.objectField("keys");
        try json_writer.beginArray();
        for (0..node.num_keys) |i| {
            try json_writer.write(node.keys[i]);
        }
        try json_writer.endArray();
        try json_writer.endObject();
    }

    try json_writer.endArray();
    try json_writer.endObject();
    return try ret.toOwnedSlice();
}

const insert_sequence_size = 1000;
fn createInsertSequence() [insert_sequence_size]i32 {
    var ret: [insert_sequence_size]i32 = undefined;

    var rng = std.Random.DefaultPrng.init(0);
    const rand = rng.random();
    for (0..insert_sequence_size) |i| {
        ret[i] = rand.intRangeAtMost(i32, 0, 99);
    }
    return ret;
}

const TestBtree = BTree(4, i32);

const BTreeWorker = union(enum) {
    inserter: TestBtree.Inserter,
    deleter: TestBtree.Deleter,
    none,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();


    const addy = try std.net.Address.parseIp("0.0.0.0", 8080);
    var server = try addy.listen(.{
        .reuse_port = true,
    });

    var btree = try TestBtree.init(alloc);
    defer btree.deinit();

    const insert_sequence = createInsertSequence();
    const test_start = 0;
    //const test_start = 33 + 8;
    var insert_idx: usize = test_start;
    for (0..test_start) |i| {
        try btree.insert(alloc, insert_sequence[i]);
    }

    var worker: BTreeWorker = .none;

    // ROOT c1 c2 c3 c11 c12 c13 c21 c22 c23
    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();

        while (true) {
            var read_buf: [4096]u8 = undefined;
            var http_server = std.http.Server.init(connection, &read_buf);
            var req = http_server.receiveHead() catch break;

            const query_param_start = std.mem.indexOfScalar(u8, req.head.target, '?') orelse req.head.target.len;
            const target = std.meta.stringToEnum(Target, req.head.target[0..query_param_start]) orelse {
                try req.respond("", .{.status = .not_found});
                continue;
            };
            std.debug.print("Got request for {s}\n" ,.{@tagName(target)});
            switch (target) {
                .@"/", .@"/index.html" => {
                    try serveFile(alloc, "res/index.html", &req);
                },
                .@"/index.js" => {
                    try serveFile(alloc, "res/index.js", &req);
                },
                .@"/data" => {
                    const response = try serializeTree(alloc, &btree, worker);
                    defer alloc.free(response);

                    std.debug.print("Sending response: {s}", .{response});
                    try req.respond(response, .{
                        .extra_headers = &.{
                            .{
                                .name = "Content-Type",
                                .value = "application/json",
                            }
                        },
                    });
                },
                .@"/step" => {
                    switch (worker) {
                        .inserter => |*i| {
                            if (!try i.step()) {
                                i.deinit();
                                worker = .none;
                            }
                        },
                        .deleter => |*d| {
                            if (!d.step()) {
                                d.deinit();
                                worker = .none;
                            }
                        },
                        .none => {
                            if (insert_idx < insert_sequence.len) {
                                worker = .{ .inserter = try btree.inserter(alloc, insert_sequence[insert_idx]) };
                                insert_idx += 1;
                            }
                        },
                    }
                    try req.respond("", .{});
                },
                .@"/reset" => {
                    btree.deinit();
                    btree = try TestBtree.init(alloc);
                    worker = .none;
                    insert_idx = test_start;
                    for (0..test_start) |i| {
                        try btree.insert(alloc, insert_sequence[i]);
                    }
                    try req.respond("", .{});
                },
                .@"/delete" => blk: {
                    const expected_query_start = "?val=";
                    const val_start = query_param_start + expected_query_start.len;
                    if (val_start >= req.head.target.len) {
                        std.log.err("Delete missing val param", .{});
                        break :blk;
                    }

                    const val_s = req.head.target[val_start..];
                    const val = std.fmt.parseInt(i32, val_s, 0) catch {
                        std.log.err("Delete val not a valid i32", .{});
                        break :blk;
                    };

                    worker = .{ .deleter = try btree.deleter(alloc, val) };
                    try req.respond("", .{});
                }
            }


        }
    }
}
