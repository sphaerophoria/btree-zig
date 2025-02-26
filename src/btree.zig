const std = @import("std");
const Allocator = std.mem.Allocator;

const ChildIdx = u8;

const NodeType = enum(u1) {
    inner,
    leaf,
};

const NodeId = packed struct (u32) {
    node_type: NodeType,
    index: u31,

    fn eql(self: NodeId, other: NodeId) bool {
        return std.meta.eql(self, other);
    }
};

pub fn BTree(comptime node_capacity_: comptime_int, comptime T: type) type {
    return struct {
        pub const node_capacity = node_capacity_;
        pub const children_capacity = node_capacity + 1;
        pub const min_node_keys  = node_capacity / 2;

        alloc: Allocator,
        inner_nodes: std.ArrayListUnmanaged(InnerNode),
        leaf_nodes: std.ArrayListUnmanaged(LeafNode),

        // FIXME: Free correctly, reset whatever we gotta do
        free_leaves: std.ArrayListUnmanaged(usize),
        free_inners: std.ArrayListUnmanaged(usize),

        root_node: NodeId = .{ .node_type = .leaf, .index = 0 },

        const InnerNode = struct {
            // FIXME: StackArrayList type might be useful here
            //
            //23 28 76 92
            keys: [node_capacity]T = undefined,
            //
            children: [children_capacity]NodeId = undefined,
            // FIXME: u8 should be u(log_2(node_capacity)) or something
            num_children: ChildIdx = 0,

            pub fn numKeys(self: *const InnerNode) usize {
                return self.num_children -| 1;
            }

            fn remove(self: *InnerNode, key: T) NodeId {

                const num_keys = self.numKeys();
                const idx = std.mem.indexOfScalar(T, self.keys[0..num_keys], key) orelse unreachable;
                std.mem.copyForwards(
                    T,
                    self.keys[idx..num_keys - 1],
                    self.keys[idx + 1..num_keys],
                );
                const removed_child_id = self.children[idx + 1];
                std.mem.copyForwards(
                    NodeId,
                    self.children[idx + 1..self.num_children - 1],
                    self.children[idx + 2..self.num_children],
                );
                self.num_children -= 1;

                return removed_child_id;
            }

            fn findChild(self: *const InnerNode, search_key: NodeId) usize {
                for (0..self.num_children) |i| {
                    const child_id = self.children[i];
                    if (child_id.eql(search_key)) {
                        return i;
                    }
                }
                unreachable;
            }

            fn insert(self: *InnerNode, key_idx: ChildIdx, key: T, child: NodeId) void {
                const num_keys = self.numKeys();

                std.mem.copyBackwards(
                    T,
                    self.keys[key_idx + 1..num_keys + 1],
                    self.keys[key_idx..num_keys],
                );

                std.mem.copyBackwards(
                    NodeId,
                    self.children[key_idx + 1..self.num_children + 1],
                    self.children[key_idx..self.num_children],
                );

                self.keys[key_idx] = key;
                self.children[key_idx + 1] = child;
                self.num_children += 1;
            }

            // FIXME: Only needs children if inner node
            fn setContents(self: *InnerNode, keys: []const T, children: []const NodeId) void {
                std.debug.assert(children.len == keys.len + 1);

                @memcpy(self.keys[0..keys.len], keys);
                @memcpy(self.children[0..children.len], children);
                self.num_children = @intCast(children.len);
            }
        };

        const LeafNode = struct {
            keys: [node_capacity]T = undefined,
            num_keys: ChildIdx = 0,

            fn insert(self: *LeafNode, key_idx: ChildIdx, key: T) void {
                std.mem.copyBackwards(
                    T,
                    self.keys[key_idx + 1..self.num_keys + 1],
                    self.keys[key_idx..self.num_keys],
                );

                self.keys[key_idx] = key;
                self.num_keys += 1;
            }

            fn remove(self: *LeafNode, key: T) void {
                const idx = std.mem.indexOfScalar(T, self.keys[0..self.num_keys], key) orelse unreachable;
                std.mem.copyForwards(
                    T,
                    self.keys[idx..self.num_keys - 1],
                    self.keys[idx + 1..self.num_keys],
                );
                self.num_keys -= 1;
            }

            fn setContents(self: *LeafNode, keys: []const T) void {
                @memcpy(self.keys[0..keys.len], keys);
                self.num_keys = @intCast(keys.len);
            }
        };

        const Node = union(enum) {
            inner: *InnerNode,
            leaf: *LeafNode,

            fn numKeys(self: Node) usize {
                return switch (self) {
                    .inner => |i| i.numKeys(),
                    .leaf => |l| l.num_keys,
                };
            }
        };

        // FIXME: how do we dedup with Node
        const ConstNode = union(enum) {
            inner: *const InnerNode,
            leaf: *const LeafNode,
        };

        const Self = @This();
        pub fn init(alloc: Allocator) !Self {

            var leaf_nodes = std.ArrayListUnmanaged(LeafNode){};
            errdefer leaf_nodes.deinit(alloc);

            try leaf_nodes.append(alloc, .{});

            return .{
                .alloc = alloc,
                .inner_nodes = .{},
                .leaf_nodes = leaf_nodes,
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner_nodes.deinit(self.alloc);
            self.leaf_nodes.deinit(self.alloc);
        }

        // FIXME: Dedup with InnerNodeSplitter
        const LeafNodeSplitter = struct {
            const split_size = children_capacity / 2;

            with_extra: [children_capacity]T,

            // FIXME: Unsure if this results in a copy, might be better to
            // initPinned
            fn init(node: *const LeafNode, extra_key: T) LeafNodeSplitter {
                std.debug.assert(children_capacity % 2 == 1);

                var ret = LeafNodeSplitter {
                    .with_extra = undefined,
                };

                var key_idx: usize = 0;
                while (key_idx < node.keys.len and node.keys[key_idx] < extra_key) {
                    defer key_idx += 1;
                    ret.with_extra[key_idx] = node.keys[key_idx];
                }

                ret.with_extra[key_idx] = extra_key;

                while (key_idx < node_capacity) {
                    defer key_idx += 1;
                    ret.with_extra[key_idx + 1] = node.keys[key_idx];
                }

                return ret;
            }


            fn centerKey(self: LeafNodeSplitter) T {
                return self.with_extra[split_size];
            }

            fn leftKeys(self: *const LeafNodeSplitter) []const T {
                return self.with_extra[0..split_size];
            }

            fn rightKeys(self: *const LeafNodeSplitter) []const T {
                return self.with_extra[split_size + 1..];
            }
        };

        const InnerNodeSplitter = struct {
            const split_size = children_capacity / 2;

            with_extra: [children_capacity]T,
            children: [children_capacity + 1]NodeId,


            // FIXME: Unsure if this results in a copy, might be better to
            // initPinned
            fn init(node: *const InnerNode, extra_key: T, extra_node: NodeId) InnerNodeSplitter {
                std.debug.assert(node.num_children == children_capacity);
                std.debug.assert(children_capacity % 2 == 1);

                var ret = InnerNodeSplitter {
                    .with_extra = undefined,
                    .children = undefined,
                };

                var key_idx: usize = 0;
                ret.children[0] = node.children[0];
                while (key_idx < node.keys.len and node.keys[key_idx] < extra_key) {
                    defer key_idx += 1;
                    ret.with_extra[key_idx] = node.keys[key_idx];
                    ret.children[key_idx + 1] = node.children[key_idx + 1];
                }

                ret.with_extra[key_idx] = extra_key;
                ret.children[key_idx + 1] = extra_node;

                while (key_idx < node_capacity) {
                    defer key_idx += 1;
                    ret.with_extra[key_idx + 1] = node.keys[key_idx];
                    ret.children[key_idx + 2] = node.children[key_idx + 1];
                }

                return ret;
            }


            fn centerKey(self: InnerNodeSplitter) T {
                return self.with_extra[split_size];
            }

            fn leftKeys(self: *const InnerNodeSplitter) []const T {
                return self.with_extra[0..split_size];
            }

            fn leftChildren(self: *const InnerNodeSplitter) []const NodeId {
                return self.children[0..split_size + 1];
            }

            fn rightKeys(self: *const InnerNodeSplitter) []const T {
                return self.with_extra[split_size + 1..];
            }

            fn rightChildren(self: *const InnerNodeSplitter) []const NodeId {
                return self.children[split_size + 1..];
            }
        };

        pub const Inserter = struct {
            val: T,
            target: NodeId,
            btree: *Self,
            in_progress_tree: ?NodeId = null,
            // FIXME: Allocating here seems kinda lame
            parent_stack: std.ArrayList(NodeId),
            state: enum {
                append,
                split,
                finished,
            } = .append,

            pub fn deinit(self: *Inserter) void {
                self.parent_stack.deinit();
            }

            pub fn step(self: *Inserter) !bool {
                while (true) {
                    switch (self.state) {
                        .append => {
                            const success = try self.btree.addToNode(self.target, self.val, self.in_progress_tree);
                            if (success) {
                                self.state = .finished;
                            } else {
                                self.state = .split;
                            }
                        },
                        .split => {
                            if (self.parent_stack.items.len == 0) {
                                try self.splitRoot();
                                self.state = .finished;
                            } else {
                                const next = try self.splitNode();
                                self.target = next.target;
                                self.val = next.val;
                                self.state = .append;
                                return true;
                            }
                        },
                        .finished => return false,
                    }
                }
            }

            const NextStep = struct {
                target: NodeId,
                val: T,
            };

            // FIXME: heavily duplicated with splitRoot
            fn splitNode(self: *Inserter) !NextStep {
                const new_node_id, const parent_elem = switch (self.target.node_type) {
                    .leaf => blk:{
                        const new_node_id = self.btree.nextNodeId(.leaf);
                        try self.btree.leaf_nodes.append(self.btree.alloc, .{});

                        const node = self.btree.getByNodeId(self.target);
                        const node_splitter = LeafNodeSplitter.init(node.leaf, self.val);

                        node.leaf.setContents(
                            node_splitter.leftKeys(),
                        );

                        const new_node = self.btree.getByNodeId(new_node_id);
                        new_node.leaf.setContents(
                            node_splitter.rightKeys(),
                        );

                        break :blk .{new_node_id, node_splitter.centerKey()};
                    },
                    .inner => blk: {
                        const new_node_id = self.btree.nextNodeId(.inner);
                        try self.btree.inner_nodes.append(self.btree.alloc, .{});

                        const new_grandchild = self.in_progress_tree.?;

                        const node = self.btree.getByNodeId(self.target);
                        const node_splitter = InnerNodeSplitter.init(node.inner, self.val, new_grandchild);

                        node.inner.setContents(
                            node_splitter.leftKeys(),
                            node_splitter.leftChildren()
                        );

                        const new_node = self.btree.getByNodeId(new_node_id);
                        new_node.inner.setContents(
                            node_splitter.rightKeys(),
                            node_splitter.rightChildren(),
                        );

                        break :blk .{new_node_id, node_splitter.centerKey()};
                    },
                };

                self.in_progress_tree = new_node_id;

                return .{
                    .target = self.parent_stack.pop(),
                    .val = parent_elem,
                };
                // right half gets new node
                // Middle element injected into parent
                // When injected insert tree segment into correct spot
            }

            fn splitRoot(self: *Inserter) !void {
                const new_root_id = self.btree.nextNodeId(.inner);
                try self.btree.inner_nodes.append(self.btree.alloc, .{});
                // FIXME: errdefers

                const root_node = self.btree.getByNodeId(self.btree.root_node);
                switch (root_node) {
                    .inner => {
                        const new_child_id = self.btree.nextNodeId(.inner);
                        try self.btree.inner_nodes.append(self.btree.alloc, .{});

                        const new_grandchild_id = if (self.in_progress_tree) |t| t else blk: {
                            const new_id = self.btree.nextNodeId(.leaf);
                            try self.btree.leaf_nodes.append(self.btree.alloc, .{});
                            break :blk new_id;
                        };
                        // FIXME: errdefers

                        // Re-fetch because memory could have moved
                        const old_root = self.btree.getByNodeId(self.target).inner;
                        const node_splitter = InnerNodeSplitter.init(old_root, self.val, new_grandchild_id);

                        old_root.setContents(
                            node_splitter.leftKeys(),
                            node_splitter.leftChildren()
                        );

                        const new_child = self.btree.getByNodeId(new_child_id).inner;
                        new_child.setContents(
                            node_splitter.rightKeys(),
                            node_splitter.rightChildren()
                        );


                        const root = self.btree.getByNodeId(new_root_id).inner;
                        root.setContents(
                            &.{node_splitter.centerKey()},
                            &.{self.target, new_child_id}
                        );
                        self.btree.root_node = new_root_id;
                        // Take the left N elements
                        // Take the right N elements

                    },
                    .leaf => {
                        const new_child_id = self.btree.nextNodeId(.leaf);
                        try self.btree.leaf_nodes.append(self.btree.alloc, .{});

                        // Re-fetch because memory could have moved
                        const old_root = self.btree.getByNodeId(self.target).leaf;
                        const node_splitter = LeafNodeSplitter.init(old_root, self.val);

                        old_root.setContents(
                            node_splitter.leftKeys(),
                        );

                        const new_child = self.btree.getByNodeId(new_child_id).leaf;
                        new_child.setContents(
                            node_splitter.rightKeys(),
                        );


                        const root = self.btree.getByNodeId(new_root_id).inner;
                        root.setContents(
                            &.{node_splitter.centerKey()},
                            &.{self.target, new_child_id}
                        );
                        self.btree.root_node = new_root_id;
                    },
                }

            }

            const NextNode = struct {
                target: NodeId,
                val: T,
            };
        };

        pub fn insert(self: *Self, tmp_alloc: Allocator, val: T) !void {
            var val_inserter = try self.inserter(tmp_alloc, val);
            defer val_inserter.deinit();
            while (try val_inserter.step()) {}

        }

        pub fn inserter(self: *Self, alloc: Allocator, val: T) !Inserter {
            var res = try self.findKey(alloc, val);
            if (res.exists) {
                return .{
                    .val = val,
                    .btree = self,
                    .state = .finished,
                    .target = res.parent_stack.pop(),
                    .parent_stack = res.parent_stack,
                };
            }

            return .{
                .val = val,
                .btree = self,
                .target = res.parent_stack.pop(),
                .parent_stack = res.parent_stack,
            };
        }

        pub const Deleter = struct {
            btree: *Self,
            target: NodeId,
            parent_stack: std.ArrayList(NodeId),
            state: State,

            const TargetAction = union(enum) {
                delete: T,
                merge: NodeId,
                none,
            };

            const State = union(enum) {
                remove_val: T,
                find_merge_target,
                merge_nodes: usize, // parent key idx
                finished,
            };

            pub fn deinit(self: *Deleter) void {
                self.parent_stack.deinit();
            }

            pub fn step(self: *Deleter) bool {
                while (true) {
                    switch (self.state) {
                        .remove_val => |v| {
                            const next_state = self.doRemove(v);
                            self.state = next_state;
                        },
                        .find_merge_target => {
                            const next_state = self.doFindMergeTarget();
                            self.state = next_state;
                            return true;
                        },
                        .merge_nodes => |parent_key_idx| {
                            self.doMerge(parent_key_idx);
                            return true;
                        },
                        // Find merge neighbor
                        // Pull parent down
                        // Delete empty node
                        .finished => return false,
                    }
                }
            }

            // FIXME: API should probably be key_idx, not val
            fn doRemove(self: *Deleter, val: T) State {
                switch (self.target.node_type) {
                    .leaf => {
                        const node = self.btree.getByNodeId(self.target);
                        node.leaf.remove(val);

                        if (node.leaf.num_keys < min_node_keys) {
                            return .find_merge_target;
                        }
                    },
                    .inner => {
                        // FIXME: duplication with leaf
                        const node = self.btree.getByNodeId(self.target);
                        const removed_node_id = node.inner.remove(val);
                        self.btree.removeNode(removed_node_id);

                        if (node.inner.numKeys() < min_node_keys) {
                            return .find_merge_target;
                        }
                    },
                }

                return .finished;
            }

            fn doFindMergeTarget(self: *Deleter) State {
                // Look left
                // Look right
                if (self.parent_stack.items.len == 0) {
                    return .finished;
                }

                const parent_id = self.parent_stack.items[self.parent_stack.items.len - 1];
                const parent_node = self.btree.getByNodeId(parent_id);

                // FIXME: Maybe we should store our child idx with the parent stack?
                const target_idx = parent_node.inner.findChild(self.target);

                if (target_idx != 0) {
                    const left_node_id = parent_node.inner.children[target_idx - 1];
                    const left_node = self.btree.getByNodeId(left_node_id);
                    if (left_node.numKeys() != node_capacity) {
                        return .{
                            .merge_nodes = target_idx - 1
                        };
                    }
                }

                // FIXME: Super duplicated with left node stuff
                if (target_idx != children_capacity) {
                    const right_node_id = parent_node.inner.children[target_idx + 1];
                    const right_node = self.btree.getByNodeId(right_node_id);
                    if (right_node.numKeys() != node_capacity) {
                        return .{
                            .merge_nodes = target_idx,
                        };
                    }
                }

                unreachable;
            }

            fn doMerge(self: *Deleter, parent_key_idx: usize) void {
                const parent_id = self.parent_stack.items[self.parent_stack.items.len - 1];
                const parent = self.btree.getByNodeId(parent_id);

                const left_id = parent.inner.children[parent_key_idx];
                const right_id = parent.inner.children[parent_key_idx + 1];

                const left_node = self.btree.getByNodeId(left_id);
                const right_node = self.btree.getByNodeId(right_id);

                std.debug.assert(left_id.node_type == right_id.node_type);

                switch (left_id.node_type) {
                    .leaf => {
                        left_node.leaf.keys[left_node.leaf.num_keys] = parent.inner.keys[parent_key_idx];
                        left_node.leaf.num_keys += 1;
                        const num_right_keys = right_node.leaf.num_keys;
                        const left_insert_start = left_node.leaf.num_keys;
                        const left_insert_end = left_insert_start + num_right_keys;
                        @memcpy(
                            left_node.leaf.keys[left_insert_start..left_insert_end],
                            right_node.leaf.keys[0..num_right_keys],
                        );
                        left_node.leaf.num_keys += num_right_keys;

                        self.target = self.parent_stack.pop();
                        self.state = .{
                            .remove_val = parent.inner.keys[parent_key_idx],
                        };
                        return;
                    },
                    .inner => unreachable,
                }

                unreachable;
            }
        };

        pub fn deleter(self: *Self, alloc: Allocator, val: T) !Deleter {
            var res = try self.findKey(alloc, val);
            const state: Deleter.State = if (res.exists) .{ .remove_val = val} else .finished;

            return .{
                .btree = self,
                .target = res.parent_stack.pop(),
                .parent_stack = res.parent_stack,
                .state = state,
            };
        }

        const FindResult = struct {
            exists: bool,
            parent_stack: std.ArrayList(NodeId),
        };

        fn findKey(self: *const Self, alloc: Allocator, val: T) !FindResult {
            var parent_stack = std.ArrayList(NodeId).init(alloc);
            errdefer parent_stack.deinit();

            try parent_stack.append(self.root_node);

            while (true) {
                const node = self.getByNodeIdConst(parent_stack.getLast());

                switch (node) {
                    .inner => |inner_node| {
                        const num_keys = inner_node.numKeys();
                        var next_node_id = inner_node.children[inner_node.num_children -| 1];
                        for (0..num_keys) |i| {
                            const key = inner_node.keys[i];
                            const ord = std.math.order(val, key);
                            switch (ord) {
                                .lt => {
                                    next_node_id = inner_node.children[i];
                                    break;
                                },
                                .gt => {
                                    continue;
                                },
                                .eq => {
                                    return .{
                                        .exists = true,
                                        .parent_stack = parent_stack,
                                    };

                                },
                            }
                        }

                        try parent_stack.append(next_node_id);
                    },
                    .leaf => |leaf_node| {
                        for (leaf_node.keys[0..leaf_node.num_keys]) |k| {

                            const ord = std.math.order(val, k);
                            const exists = switch (ord) {
                                .gt => continue,
                                .lt => false,
                                .eq => true,
                            };

                            return .{
                                .exists = exists,
                                .parent_stack = parent_stack,
                            };
                        }

                        return .{
                            .exists = false,
                            .parent_stack = parent_stack,
                        };
                    },
                }

            }
        }

        fn getByNodeIdConst(self: *const Self, id: NodeId) ConstNode {
            if (id.node_type == .leaf) {
                return .{ .leaf = &self.leaf_nodes.items[id.index] };
            } else {
                return .{ .inner = &self.inner_nodes.items[id.index] };
            }
        }

        fn getByNodeId(self: *Self, id: NodeId) Node {
            if (id.node_type == .leaf) {
                return .{ .leaf = &self.leaf_nodes.items[id.index] };
            } else {
                return .{ .inner = &self.inner_nodes.items[id.index] };
            }
        }

        fn removeNode(self: *Self, id: NodeId) void {
            switch (id.node_type) {
                .leaf => self.free_leaves.append(self.alloc, id.index),
                .inner => self.free_inners.append(self.alloc, id.index),
            }
        }

        // FIXME: All uses of nextNodeId need to pull from the free list, then
        // they have to allocate from the free list
        fn nextNodeId(self: *Self, node_type: NodeType) NodeId {
            const next_index = switch (node_type) {
                .leaf => self.leaf_nodes.items.len,
                .inner => self.inner_nodes.items.len,
            };
            return .{
                .node_type = node_type,
                .index = @intCast(next_index),
            };
        }

        fn addToNode(self: *Self, node_id: NodeId, val: T, child: ?NodeId) !bool {
            const node = self.getByNodeId(node_id);
            switch (node) {
                .inner => |inner_node| {
                    if (inner_node.num_children == children_capacity) {
                        return false;
                    }

                    // FIXME: Split inner and leaf node split
                    std.debug.assert(child != null);

                    var key_idx: usize = 0;
                    const num_keys = inner_node.numKeys();
                    while (key_idx < num_keys) {
                        if (inner_node.keys[key_idx] > val) {
                            break;
                        }
                        key_idx += 1;
                    }
                    inner_node.insert(@intCast(key_idx), val, child.?);
                },
                .leaf => |leaf_node| {
                    if (leaf_node.num_keys == node_capacity) {
                        return false;
                    }

                    // FIXME: Looks very similar to inner node above
                    var key_idx: usize = 0;
                    while (key_idx < leaf_node.num_keys) {
                        if (leaf_node.keys[key_idx] > val) {
                            break;
                        }
                        key_idx += 1;
                    }
                    leaf_node.insert(@intCast(key_idx), val);
                },
            }

            return true;
        }
    };
}
