//! A thin, allocator-aware Zig layer over graphviz.
//!
//! The raw translated declarations stay available as `graphviz.c`, so anything
//! this wrapper does not cover is still one field access away.

const std = @import("std");

pub const c = @import("c");

pub const Error = error{
    ContextInitFailed,
    GraphCreateFailed,
    ParseFailed,
    NodeCreateFailed,
    EdgeCreateFailed,
    AttributeSetFailed,
    LayoutFailed,
    RenderFailed,
};

/// Layout engines compiled into this build. Only `dot` is linked in; adding
/// more means compiling the matching lib/*gen and plugin/*_layout sources.
pub const Engine = enum {
    dot,

    fn name(self: Engine) [:0]const u8 {
        return @tagName(self);
    }
};

/// Output formats provided by plugin/core. All are dependency-free; bitmap
/// formats would need cairo/pango and are not available here.
pub const Format = enum {
    svg,
    dot,
    xdot,
    plain,
    plain_ext,
    json,
    json0,
    dot_json,
    xdot_json,
    ps,
    eps,
    fig,
    pic,
    pov,
    imap,
    cmap,
    cmapx,
    tk,

    fn name(self: Format) [:0]const u8 {
        return switch (self) {
            .plain_ext => "plain-ext",
            .dot_json => "dot_json",
            .xdot_json => "xdot_json",
            else => @tagName(self),
        };
    }
};

/// Text metrics note: no textlayout plugin is registered, so graphviz falls
/// back to `estimate_textspan_size` (lib/common/textspan.c) and its built-in
/// font width tables. Geometry is close to, but not identical with, a
/// pango/cairo-enabled `dot`.
pub const Context = struct {
    ptr: *c.GVC_t,

    pub fn init() Error!Context {
        // demand_loading = 0: never try to dlopen anything.
        const ptr = c.gvContextPlugins(c.gv_builtin_plugins(), 0) orelse
            return Error.ContextInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Context) void {
        _ = c.gvFreeContext(self.ptr);
    }

    /// Lay out `graph` in place. Pair every successful call with `freeLayout`.
    pub fn layout(self: Context, graph: Graph, engine: Engine) Error!void {
        if (c.gvLayout(self.ptr, graph.ptr, engine.name().ptr) != 0)
            return Error.LayoutFailed;
    }

    pub fn freeLayout(self: Context, graph: Graph) void {
        _ = c.gvFreeLayout(self.ptr, graph.ptr);
    }

    /// Render an already laid-out graph. The returned slice is owned by
    /// `allocator`; graphviz's own buffer is released before returning.
    pub fn renderAlloc(
        self: Context,
        allocator: std.mem.Allocator,
        graph: Graph,
        format: Format,
    ) ![]u8 {
        var data: [*c]u8 = null;
        var len: usize = 0;
        if (c.gvRenderData(self.ptr, graph.ptr, format.name().ptr, &data, &len) != 0)
            return Error.RenderFailed;
        defer c.gvFreeRenderData(data);
        if (data == null) return Error.RenderFailed;
        return allocator.dupe(u8, data[0..len]);
    }

    /// Lay out, render and free the layout in one step.
    pub fn renderGraphAlloc(
        self: Context,
        allocator: std.mem.Allocator,
        graph: Graph,
        engine: Engine,
        format: Format,
    ) ![]u8 {
        try self.layout(graph, engine);
        defer self.freeLayout(graph);
        return self.renderAlloc(allocator, graph, format);
    }
};

pub const Kind = enum {
    directed,
    strict_directed,
    undirected,
    strict_undirected,

    fn directedFlag(self: Kind) c_int {
        return switch (self) {
            .directed, .strict_directed => 1,
            .undirected, .strict_undirected => 0,
        };
    }

    fn strictFlag(self: Kind) c_int {
        return switch (self) {
            .strict_directed, .strict_undirected => 1,
            .directed, .undirected => 0,
        };
    }
};

pub const Graph = struct {
    ptr: *c.Agraph_t,

    pub fn init(name: [:0]const u8, kind: Kind) Error!Graph {
        const ptr = c.gv_open_graph(
            @constCast(name.ptr),
            kind.directedFlag(),
            kind.strictFlag(),
        ) orelse return Error.GraphCreateFailed;
        return .{ .ptr = ptr };
    }

    /// Parse DOT source. Accepts exactly what `dot` accepts on stdin.
    pub fn parse(source: [:0]const u8) Error!Graph {
        const ptr = c.agmemread(source.ptr) orelse return Error.ParseFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Graph) void {
        _ = c.agclose(self.ptr);
    }

    pub fn node(self: Graph, name: [:0]const u8) Error!Node {
        const ptr = c.agnode(self.ptr, @constCast(name.ptr), 1) orelse
            return Error.NodeCreateFailed;
        return .{ .ptr = ptr };
    }

    pub fn edge(self: Graph, tail: Node, head: Node) Error!Edge {
        const ptr = c.agedge(self.ptr, tail.ptr, head.ptr, null, 1) orelse
            return Error.EdgeCreateFailed;
        return .{ .ptr = ptr };
    }

    /// Set a graph-level attribute, e.g. `rankdir` = `LR`.
    pub fn set(self: Graph, name: [:0]const u8, value: [:0]const u8) Error!void {
        return setAttr(self.ptr, name, value);
    }

    /// Set a default attribute inherited by every node, mirroring
    /// `node [shape=circle]` in DOT.
    pub fn setNodeDefault(self: Graph, name: [:0]const u8, value: [:0]const u8) Error!void {
        if (c.agattr_text(self.ptr, c.AGNODE, @constCast(name.ptr), value.ptr) == null)
            return Error.AttributeSetFailed;
    }

    /// Set a default attribute inherited by every edge.
    pub fn setEdgeDefault(self: Graph, name: [:0]const u8, value: [:0]const u8) Error!void {
        if (c.agattr_text(self.ptr, c.AGEDGE, @constCast(name.ptr), value.ptr) == null)
            return Error.AttributeSetFailed;
    }
};

pub const Node = struct {
    ptr: *c.Agnode_t,

    pub fn set(self: Node, name: [:0]const u8, value: [:0]const u8) Error!void {
        return setAttr(self.ptr, name, value);
    }
};

pub const Edge = struct {
    ptr: *c.Agedge_t,

    pub fn set(self: Edge, name: [:0]const u8, value: [:0]const u8) Error!void {
        return setAttr(self.ptr, name, value);
    }
};

/// agsafeset declares the default for the attribute if it does not exist yet,
/// which is what callers almost always want.
fn setAttr(obj: anytype, name: [:0]const u8, value: [:0]const u8) Error!void {
    if (c.agsafeset(obj, @constCast(name.ptr), value.ptr, "") != 0)
        return Error.AttributeSetFailed;
}

test "context initialises with builtin plugins" {
    const ctx = try Context.init();
    defer ctx.deinit();
}

test "parse and render DOT to SVG" {
    const ctx = try Context.init();
    defer ctx.deinit();

    const graph = try Graph.parse("digraph { a -> b; }");
    defer graph.deinit();

    const svg = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .svg);
    defer std.testing.allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
}

test "build a graph programmatically" {
    const ctx = try Context.init();
    defer ctx.deinit();

    const graph = try Graph.init("fsm", .directed);
    defer graph.deinit();
    try graph.set("rankdir", "LR");

    const a = try graph.node("LR_0");
    const b = try graph.node("LR_2");
    try a.set("shape", "doublecircle");
    const e = try graph.edge(a, b);
    try e.set("label", "SS(B)");

    const svg = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .svg);
    defer std.testing.allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "SS(B)") != null);
}

test "plain output exposes laid-out coordinates" {
    const ctx = try Context.init();
    defer ctx.deinit();

    const graph = try Graph.parse("digraph { a -> b; }");
    defer graph.deinit();

    const plain = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .plain);
    defer std.testing.allocator.free(plain);

    try std.testing.expect(std.mem.startsWith(u8, plain, "graph "));
    try std.testing.expect(std.mem.indexOf(u8, plain, "node a") != null);
}
