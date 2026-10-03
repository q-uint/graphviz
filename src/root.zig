//! A thin, allocator-aware Zig layer over graphviz.
//!
//! The raw translated declarations stay available as `graphviz.c`, so anything
//! this wrapper does not cover is still one field access away.

const std = @import("std");

pub const c = @import("c");

pub const Error = error{
    ContextInitFailed,
    GraphCreateFailed,
    SubgraphCreateFailed,
    ParseFailed,
    NodeCreateFailed,
    EdgeCreateFailed,
    AttributeSetFailed,
    NameTooLong,
    ValueTooLong,
    LayoutFailed,
    RenderFailed,
};

/// Longest name or value this wrapper formats into its own stack buffer.
///
/// Strings that arrive already NUL terminated are handed to cgraph as-is and
/// are not bounded by this; only formatted values and plain `[]const u8` are.
/// For anything longer, build a `[:0]u8` yourself and pass that.
pub const max_inline_bytes = 1024;

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

    /// Find or create a subgraph. A subgraph is owned by its parent: closing
    /// the root closes it too, so do not `deinit` one.
    ///
    /// `rank` is a subgraph attribute, so pinning a row of nodes to the same
    /// rank is `try sub.set(.{ .rank = .same })`.
    pub fn subgraph(self: Graph, name: [:0]const u8) Error!Graph {
        const ptr = c.agsubg(self.ptr, @constCast(name.ptr), 1) orelse
            return Error.SubgraphCreateFailed;
        return .{ .ptr = ptr };
    }

    /// `subgraph`, with the name formatted at call time. cgraph interns the
    /// name, so the formatting buffer does not outlive the call.
    pub fn subgraphFmt(self: Graph, comptime fmt: []const u8, args: anytype) Error!Graph {
        var buf: [max_inline_bytes]u8 = undefined;
        return self.subgraph(try printName(&buf, fmt, args));
    }

    /// A subgraph named `cluster_<name>`, which is what makes dot draw a box
    /// around its members.
    pub fn cluster(self: Graph, name: [:0]const u8) Error!Graph {
        return self.subgraphFmt("cluster_{s}", .{name});
    }

    pub fn node(self: Graph, name: [:0]const u8) Error!Node {
        const ptr = c.agnode(self.ptr, @constCast(name.ptr), 1) orelse
            return Error.NodeCreateFailed;
        return .{ .ptr = ptr };
    }

    /// `node`, with the name formatted at call time. cgraph interns the name,
    /// so the formatting buffer does not outlive the call.
    pub fn nodeFmt(self: Graph, comptime fmt: []const u8, args: anytype) Error!Node {
        var buf: [max_inline_bytes]u8 = undefined;
        return self.node(try printName(&buf, fmt, args));
    }

    /// `node`, then `set`.
    pub fn nodeWith(self: Graph, name: [:0]const u8, attrs: anytype) Error!Node {
        const n = try self.node(name);
        try n.set(attrs);
        return n;
    }

    pub fn edge(self: Graph, tail: Node, head: Node) Error!Edge {
        const ptr = c.agedge(self.ptr, tail.ptr, head.ptr, null, 1) orelse
            return Error.EdgeCreateFailed;
        return .{ .ptr = ptr };
    }

    /// `edge`, then `set`.
    pub fn edgeWith(self: Graph, tail: Node, head: Node, attrs: anytype) Error!Edge {
        const e = try self.edge(tail, head);
        try e.set(attrs);
        return e;
    }

    /// Set graph-level attributes from a struct literal, e.g.
    /// `try graph.set(.{ .rankdir = .LR, .nodesep = 0.3 })`.
    pub fn set(self: Graph, attrs: anytype) Error!void {
        return setAttrs(self.ptr, attrs);
    }

    /// Set one attribute whose value is formatted at call time.
    pub fn setFmt(
        self: Graph,
        name: [:0]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        return setAttrFmt(self.ptr, name, fmt, args);
    }

    /// Set defaults inherited by every node, mirroring `node [shape=circle]`.
    pub fn nodeDefault(self: Graph, attrs: anytype) Error!void {
        return setAttrDefaults(self.ptr, c.AGNODE, attrs);
    }

    /// Set defaults inherited by every edge.
    pub fn edgeDefault(self: Graph, attrs: anytype) Error!void {
        return setAttrDefaults(self.ptr, c.AGEDGE, attrs);
    }
};

pub const Node = struct {
    ptr: *c.Agnode_t,

    /// Set attributes from a struct literal, e.g.
    /// `try node.set(.{ .shape = .doublecircle, .peripheries = 2 })`.
    pub fn set(self: Node, attrs: anytype) Error!void {
        return setAttrs(self.ptr, attrs);
    }

    /// Set one attribute whose value is formatted at call time.
    pub fn setFmt(
        self: Node,
        name: [:0]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        return setAttrFmt(self.ptr, name, fmt, args);
    }
};

pub const Edge = struct {
    ptr: *c.Agedge_t,

    /// Set attributes from a struct literal, e.g.
    /// `try edge.set(.{ .label = "a", .constraint = false })`.
    pub fn set(self: Edge, attrs: anytype) Error!void {
        return setAttrs(self.ptr, attrs);
    }

    /// Set one attribute whose value is formatted at call time, e.g.
    /// `try edge.setFmt("label", "{d}/{d}", .{ a, b })`.
    pub fn setFmt(
        self: Edge,
        name: [:0]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        return setAttrFmt(self.ptr, name, fmt, args);
    }
};

/// Text with graphviz's label metacharacters escaped. Built by `escape` or
/// `escapeRecord` and rendered by `{f}`, so it works both as an attribute
/// value and inside a `setFmt` format string.
pub const Escape = struct {
    text: []const u8,
    shape: Shape,

    pub const Shape = enum { plain, record };

    pub fn format(self: Escape, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.text) |byte| {
            const special = switch (byte) {
                '\\' => true,
                '{', '}', '|', '<', '>' => self.shape == .record,
                else => false,
            };
            if (special) try w.writeByte('\\');
            try w.writeByte(byte);
        }
    }
};

/// Escape `text` for an ordinary label:
///
///     try node.set(.{ .label = gv.escape(raw) });
///     try edge.setFmt("label", "{f}/{f}", .{ gv.escape(a), gv.escape(b) });
///
/// Only backslash is special there, since it introduces the `\n`, `\l`, `\N`
/// family. Unprintable bytes are passed through untouched; how they should
/// look is the caller's decision, not graphviz's.
pub fn escape(text: []const u8) Escape {
    return .{ .text = text, .shape = .plain };
}

/// `escape`, plus the metacharacters `{}|<>` that split fields and name ports
/// inside a `record` or `Mrecord` label.
pub fn escapeRecord(text: []const u8) Escape {
    return .{ .text = text, .shape = .record };
}

/// agsafeset_text declares the default for the attribute if it does not exist
/// yet, which is what callers almost always want.
fn setAttr(obj: anytype, name: [:0]const u8, value: [:0]const u8) Error!void {
    if (c.agsafeset_text(obj, @constCast(name.ptr), value.ptr, "") != 0)
        return Error.AttributeSetFailed;
}

fn setAttrs(obj: anytype, attrs: anytype) Error!void {
    var buf: [max_inline_bytes]u8 = undefined;
    inline for (comptime attrNames(@TypeOf(attrs))) |name| {
        try setAttr(obj, name, try attrValue(&buf, @field(attrs, name)));
    }
}

fn setAttrFmt(
    obj: anytype,
    name: [:0]const u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    var buf: [max_inline_bytes]u8 = undefined;
    return setAttr(obj, name, try printValue(&buf, fmt, args));
}

fn setAttrDefaults(graph: *c.Agraph_t, kind: c_int, attrs: anytype) Error!void {
    var buf: [max_inline_bytes]u8 = undefined;
    inline for (comptime attrNames(@TypeOf(attrs))) |name| {
        const value = try attrValue(&buf, @field(attrs, name));
        if (c.agattr_text(graph, kind, @constCast(name.ptr), value.ptr) == null)
            return Error.AttributeSetFailed;
    }
}

fn attrNames(comptime Attrs: type) []const [:0]const u8 {
    const info = switch (@typeInfo(Attrs)) {
        .@"struct" => |s| s,
        else => @compileError("attributes must be a struct literal, got " ++ @typeName(Attrs)),
    };
    if (info.is_tuple)
        @compileError("attributes must be named, e.g. .{ .shape = .circle }");
    return info.field_names;
}

/// Field value to attribute string. Enums and enum literals become their tag
/// name, numbers and anything with a `format` method are printed into `buf`,
/// and NUL terminated strings are passed straight through.
fn attrValue(buf: []u8, value: anytype) Error![:0]const u8 {
    const V = @TypeOf(value);
    return switch (@typeInfo(V)) {
        .enum_literal, .@"enum" => @tagName(value),
        .bool => @as([:0]const u8, if (value) "true" else "false"),
        .int, .comptime_int, .float, .comptime_float => printValue(buf, "{d}", .{value}),
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8 and a.sentinel() != null)
                    @as([:0]const u8, value)
                else
                    unsupportedValue(V),
                else => unsupportedValue(V),
            },
            .many => if (p.child == u8 and p.sentinel() != null)
                std.mem.span(value)
            else
                unsupportedValue(V),
            .slice => if (p.child != u8)
                unsupportedValue(V)
            else if (p.sentinel() != null)
                @as([:0]const u8, value)
            else
                printValue(buf, "{s}", .{value}),
            else => unsupportedValue(V),
        },
        .@"struct", .@"union" => if (std.meta.hasMethod(V, "format"))
            printValue(buf, "{f}", .{value})
        else
            unsupportedValue(V),
        else => unsupportedValue(V),
    };
}

fn printName(buf: []u8, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    return std.mem.printSentinel(buf, fmt, args, 0) catch Error.NameTooLong;
}

fn printValue(buf: []u8, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    return std.mem.printSentinel(buf, fmt, args, 0) catch Error.ValueTooLong;
}

fn unsupportedValue(comptime V: type) noreturn {
    @compileError("cannot use " ++ @typeName(V) ++ " as a graphviz attribute value; " ++
        "expected an enum, number, bool, string, or a type with a format method");
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
    try graph.set(.{ .rankdir = .LR });

    const a = try graph.nodeWith("LR_0", .{ .shape = .doublecircle, .peripheries = 2 });
    const b = try graph.node("LR_2");
    _ = try graph.edgeWith(a, b, .{ .label = "SS(B)", .constraint = false });

    const svg = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .svg);
    defer std.testing.allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "SS(B)") != null);
}

test "attribute values render by type" {
    const graph = try Graph.init("types", .directed);
    defer graph.deinit();

    const n = try graph.node("n");
    try n.set(.{
        .shape = .circle,
        .peripheries = 2,
        .width = 0.08,
        .fixedsize = true,
        .label = @as([]const u8, "sliced"),
        .color = "blue",
    });

    try std.testing.expectEqualStrings("circle", std.mem.span(c.agget(n.ptr, @constCast("shape"))));
    try std.testing.expectEqualStrings("2", std.mem.span(c.agget(n.ptr, @constCast("peripheries"))));
    try std.testing.expectEqualStrings("0.08", std.mem.span(c.agget(n.ptr, @constCast("width"))));
    try std.testing.expectEqualStrings("true", std.mem.span(c.agget(n.ptr, @constCast("fixedsize"))));
    try std.testing.expectEqualStrings("sliced", std.mem.span(c.agget(n.ptr, @constCast("label"))));
    try std.testing.expectEqualStrings("blue", std.mem.span(c.agget(n.ptr, @constCast("color"))));
}

test "defaults are inherited" {
    const graph = try Graph.init("defaults", .directed);
    defer graph.deinit();

    try graph.nodeDefault(.{ .shape = .circle });
    try graph.edgeDefault(.{ .arrowhead = .vee });

    const n = try graph.node("n");
    const e = try graph.edge(n, try graph.node("m"));
    try std.testing.expectEqualStrings("circle", std.mem.span(c.agget(n.ptr, @constCast("shape"))));
    try std.testing.expectEqualStrings("vee", std.mem.span(c.agget(e.ptr, @constCast("arrowhead"))));
}

test "formatted names and values" {
    const graph = try Graph.init("fmt", .directed);
    defer graph.deinit();

    var previous: ?Node = null;
    for (0..4) |i| {
        const n = try graph.nodeFmt("s{d}", .{i});
        if (previous) |p| try (try graph.edge(p, n)).setFmt("label", "{d}/{d}", .{ i - 1, i });
        previous = n;
    }

    const ctx = try Context.init();
    defer ctx.deinit();
    const svg = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .svg);
    defer std.testing.allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, ">s3<") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "2/3") != null);
}

test "oversized values are rejected rather than truncated" {
    const graph = try Graph.init("long", .directed);
    defer graph.deinit();

    const n = try graph.node("n");
    const long: [max_inline_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(Error.ValueTooLong, n.set(.{ .label = @as([]const u8, &long) }));
    try std.testing.expectError(Error.NameTooLong, graph.nodeFmt("{s}", .{@as([]const u8, &long)}));

    // A caller-owned NUL terminated string has no such limit.
    const unbounded: [max_inline_bytes + 1:0]u8 = @splat('y');
    try n.set(.{ .label = @as([:0]const u8, &unbounded) });
    try std.testing.expectEqual(
        @as(usize, max_inline_bytes + 1),
        std.mem.span(c.agget(n.ptr, @constCast("label"))).len,
    );
}

test "clusters and rank pinning" {
    const ctx = try Context.init();
    defer ctx.deinit();

    const graph = try Graph.init("clustered", .directed);
    defer graph.deinit();

    const n_a = try graph.node("a");
    const n_b = try graph.node("b");
    const n_c = try graph.node("c");
    const n_d = try graph.node("d");
    _ = try graph.edge(n_a, n_b);
    _ = try graph.edge(n_b, n_c);
    _ = try graph.edge(n_c, n_d);

    const box = try graph.cluster("chain");
    try box.set(.{ .label = "chain", .style = .filled, .color = "lightgrey" });
    _ = try box.node("a");
    _ = try box.node("b");

    // b -> c -> d would span three ranks; this pins c and d onto one.
    const row = try graph.subgraphFmt("rank_{d}", .{0});
    try row.set(.{ .rank = .same });
    _ = try row.node("c");
    _ = try row.node("d");

    const svg = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .svg);
    defer std.testing.allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "clust") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, ">chain<") != null);

    const plain = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .plain);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(yOf(plain, "c").?, yOf(plain, "d").?);
    try std.testing.expect(!std.mem.eql(u8, yOf(plain, "b").?, yOf(plain, "c").?));
}

fn yOf(plain: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, plain, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, ' ');
        if (!std.mem.eql(u8, it.next() orelse continue, "node")) continue;
        if (!std.mem.eql(u8, it.next() orelse continue, name)) continue;
        _ = it.next() orelse return null; // x
        return it.next();
    }
    return null;
}

test "escaping label metacharacters" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings(
        "a\\\\nb<c>",
        try std.mem.print(&buf, "{f}", .{escape("a\\nb<c>")}),
    );
    try std.testing.expectEqualStrings(
        "a\\\\nb\\<c\\>\\|d\\{e\\}",
        try std.mem.print(&buf, "{f}", .{escapeRecord("a\\nb<c>|d{e}")}),
    );
}

test "escaped labels survive a round trip" {
    const graph = try Graph.init("escaped", .directed);
    defer graph.deinit();

    const n = try graph.node("n");
    try n.set(.{ .label = escape("C:\\path") });
    try std.testing.expectEqualStrings(
        "C:\\\\path",
        std.mem.span(c.agget(n.ptr, @constCast("label"))),
    );

    const ctx = try Context.init();
    defer ctx.deinit();
    const svg = try ctx.renderGraphAlloc(std.testing.allocator, graph, .dot, .svg);
    defer std.testing.allocator.free(svg);

    // One backslash reaches the output; the escape consumed the other.
    try std.testing.expect(std.mem.indexOf(u8, svg, "C:\\path") != null);
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
