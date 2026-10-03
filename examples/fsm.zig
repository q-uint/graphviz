//! The finite state machine from https://graphviz.org/Gallery/directed/fsm.html
//! built through the Zig API rather than parsed from DOT, then rendered.
//!
//!   zig build run-example              # SVG on stdout
//!   zig build run-example -- plain     # any Format tag name works

const std = @import("std");
const gv = @import("graphviz");

const font = "Helvetica,Arial,sans-serif";

/// `node [shape = doublecircle]; LR_0 LR_3 LR_4 LR_8;`
const accepting = [_][:0]const u8{ "LR_0", "LR_3", "LR_4", "LR_8" };

const Transition = struct { from: [:0]const u8, to: [:0]const u8, label: [:0]const u8 };

const transitions = [_]Transition{
    .{ .from = "LR_0", .to = "LR_2", .label = "SS(B)" },
    .{ .from = "LR_0", .to = "LR_1", .label = "SS(S)" },
    .{ .from = "LR_1", .to = "LR_3", .label = "S($end)" },
    .{ .from = "LR_2", .to = "LR_6", .label = "SS(b)" },
    .{ .from = "LR_2", .to = "LR_5", .label = "SS(a)" },
    .{ .from = "LR_2", .to = "LR_4", .label = "S(A)" },
    .{ .from = "LR_5", .to = "LR_7", .label = "S(b)" },
    .{ .from = "LR_5", .to = "LR_5", .label = "S(a)" },
    .{ .from = "LR_6", .to = "LR_6", .label = "S(b)" },
    .{ .from = "LR_6", .to = "LR_5", .label = "S(a)" },
    .{ .from = "LR_7", .to = "LR_8", .label = "S(b)" },
    .{ .from = "LR_7", .to = "LR_5", .label = "S(a)" },
    .{ .from = "LR_8", .to = "LR_6", .label = "S(b)" },
    .{ .from = "LR_8", .to = "LR_5", .label = "S(a)" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var arg_it = init.minimal.args.iterate();
    _ = arg_it.skip();
    const format: gv.Format = if (arg_it.next()) |arg|
        std.meta.stringToEnum(gv.Format, arg) orelse {
            std.debug.print("unknown format: {s}\n", .{arg});
            return error.UnknownFormat;
        }
    else
        .svg;

    const ctx = try gv.Context.init();
    defer ctx.deinit();

    const graph = try gv.Graph.init("finite_state_machine", .directed);
    defer graph.deinit();

    try graph.set(.{ .rankdir = .LR, .fontname = font });
    try graph.nodeDefault(.{ .fontname = font, .shape = .circle });
    try graph.edgeDefault(.{ .fontname = font });

    for (accepting) |name| {
        _ = try graph.nodeWith(name, .{ .shape = .doublecircle });
    }

    for (transitions) |t| {
        _ = try graph.edgeWith(
            try graph.node(t.from),
            try graph.node(t.to),
            .{ .label = t.label },
        );
    }

    const out = try ctx.renderGraphAlloc(gpa, graph, .dot, format);
    defer gpa.free(out);

    try std.Io.File.stdout().writeStreamingAll(init.io, out);
}
