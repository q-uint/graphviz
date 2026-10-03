const std = @import("std");
const Translator = @import("translate_c").Translator;

/// Must match whatever upstream tree this builds against.
/// flake.nix parses this line to pick the tarball it fetches.
const graphviz_version = "14.0.0";

/// Whether build.zig.zon declares an `upstream` dependency.
///
/// False today: see the `Upstream` doc comment. Flip to true in the same
/// commit that adds the dependency to build.zig.zon, and `-Dupstream-path`
/// stays available as an override for local work against a modified tree.
const has_pinned_upstream = false;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gv = buildGraphviz(b, target, optimize) orelse return;

    b.installArtifact(gv.lib);
    b.installArtifact(gv.dynlib);

    const tests = b.addTest(.{ .root_module = gv.mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Renders the finite-state-machine example from
    // https://graphviz.org/Gallery/directed/fsm.html
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/fsm.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("graphviz", gv.mod);
    const example = b.addExecutable(.{ .name = "fsm", .root_module = example_mod });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    b.step("run-example", "Render the FSM example to stdout").dependOn(&run_example.step);
}

pub const Graphviz = struct {
    /// Translated C declarations *and* the statically linked implementation.
    mod: *std.Build.Module,
    /// Translated C declarations only, for linking against a system graphviz.
    headers: *std.Build.Module,
    lib: *std.Build.Step.Compile,
    dynlib: *std.Build.Step.Compile,
};

/// Where the graphviz C sources come from.
///
/// The pinned tarball cannot currently be used: zig's package fetcher rejects
/// archives containing hard links, and graphviz's release tarball has one
/// (`redhat/graphviz.spec.rhel.in`). Until that is resolved, point
/// `-Dupstream-path` at an extracted graphviz source tree. It must be a
/// *release* tarball extraction, not a git checkout: only the release ships
/// the pre-generated grammar.c, scan.c, htmlparse.c, colortbl.h and
/// entities.h that this build consumes.
const Upstream = union(enum) {
    dep: *std.Build.Dependency,
    dir: []const u8,

    fn path(self: Upstream, b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        return switch (self) {
            .dep => |d| d.path(sub_path),
            .dir => |dir| .{ .cwd_relative = b.pathJoin(&.{ dir, sub_path }) },
        };
    }
};

pub fn buildGraphviz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?Graphviz {
    const upstream: Upstream = if (upstreamPath(b)) |dir| .{ .dir = dir } else blk: {
        if (!has_pinned_upstream) {
            std.log.err(
                \\no graphviz sources available.
                \\
                \\build.zig.zon cannot yet pin the upstream tarball: zig's package
                \\fetcher rejects archives containing hard links, and graphviz's
                \\release tarball contains one (redhat/graphviz.spec.rhel.in).
                \\
                \\`nix develop` sets GRAPHVIZ_SRC to an extracted release tree.
                \\Without nix, extract one and point at it:
                \\
                \\  curl -LO https://gitlab.com/api/v4/projects/graphviz%2Fgraphviz/packages/generic/graphviz-releases/{s}/graphviz-{s}.tar.xz
                \\  tar xf graphviz-{s}.tar.xz
                \\  zig build -Dupstream-path=graphviz-{s}
                \\
                \\A git checkout will NOT work: only the release tarball ships the
                \\pre-generated grammar.c, scan.c, htmlparse.c, colortbl.h and
                \\entities.h.
            , .{ graphviz_version, graphviz_version, graphviz_version, graphviz_version });
            return null;
        }
        break :blk .{ .dep = b.lazyDependency("upstream", .{}) orelse return null };
    };

    const t = target.result;
    const windows = t.os.tag == .windows;

    // Replaces autoconf/cmake. `null` leaves a macro undefined, `true` defines
    // it. Deliberately *not* defined: ENABLE_LTDL (plugins are compiled in, see
    // src/builtins.c), HAVE_EXPAT (no HTML-like labels), HAVE_LIBZ (no svgz),
    // GVDLL and DARWIN_DYLIB (static, no dllimport/dlopen).
    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .PACKAGE_VERSION = graphviz_version,
        .VERSION = graphviz_version,
        .BUILDDATE = "zig",
        // gvconfig.c only consults this to locate on-disk plugins, which a
        // builtins-only context never does.
        .GVLIBDIR = "",
        // configure.ac:154
        .DEFAULT_DPI = 96,

        .HAVE_INTTYPES_H = true,
        .HAVE_STDINT_H = true,
        .HAVE_STDLIB_H = true,
        .HAVE_STRING_H = true,
        .HAVE_STRINGS_H = true,
        .HAVE_SYS_STAT_H = true,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_UNISTD_H = if (windows) null else true,
        .HAVE_SYS_MMAN_H = if (windows) null else true,
        .HAVE_DL_ITERATE_PHDR = if (t.os.tag == .linux) true else null,

        .HAVE_DRAND48 = if (windows) null else true,
        .HAVE_SETENV = if (windows) null else true,
        .HAVE_SETMODE = if (windows) true else null,
        .HAVE_MEMRCHR = if (t.os.tag == .linux) true else null,
        .HAVE_STRCASECMP = if (windows) null else true,
        .HAVE_STRNCASECMP = if (windows) null else true,
    });

    // Every upstream lib lands in one compile unit rather than a Zig module
    // apiece: lib/common and lib/gvc reference each other, and upstream's own
    // CMake only escapes that cycle by linking common as an OBJECT library
    // *into* gvc. Module imports form a DAG, so the cycle has to live inside a
    // single unit.
    const headers: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "graphviz",
        .c_source_file = b.path("src/graphviz.h"),
        .target = target,
        .optimize = optimize,
    });
    addIncludePaths(headers, b, upstream);
    headers.addConfigHeader(config);

    const c_mod = headers.mod;
    b.modules.putNoClobber(b.graph.arena, "c", c_mod) catch @panic("OOM");

    const mod = b.addModule("graphviz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("c", c_mod);
    mod.addConfigHeader(config);
    addModuleIncludePaths(mod, b, upstream);
    mod.addIncludePath(b.path("src"));

    const cflags: []const []const u8 = &.{
        // Upstream is not warning-clean under clang; this is a vendored build,
        // not our code to fix.
        "-w",
        "-DGVLIBDIR=\"\"",
    };

    inline for (comptime sourceSets()) |set| {
        mod.addCSourceFiles(.{
            .root = upstream.path(b, set.dir),
            .files = set.files,
            .flags = cflags,
        });
    }

    // The lt_symlist_t table that replaces dlopen-based plugin discovery.
    mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"builtins.c"},
        .flags = cflags,
    });

    const lib = b.addLibrary(.{
        .name = "graphviz",
        .linkage = .static,
        .root_module = mod,
    });
    const dynlib = b.addLibrary(.{
        .name = "graphviz",
        .linkage = .dynamic,
        .root_module = mod,
    });

    inline for (.{ "cgraph", "gvc", "cdt", "common", "pathplan", "util", "xdot" }) |dir| {
        lib.installHeadersDirectory(
            upstream.path(b, "lib/" ++ dir),
            "graphviz",
            .{ .include_extensions = &.{".h"} },
        );
    }

    return .{ .mod = mod, .headers = c_mod, .lib = lib, .dynlib = dynlib };
}

/// `-Dupstream-path`, else `GRAPHVIZ_SRC`, which the nix dev shell sets.
fn upstreamPath(b: *std.Build) ?[]const u8 {
    if (b.option(
        []const u8,
        "upstream-path",
        "Path to an extracted graphviz release source tree (default: $GRAPHVIZ_SRC)",
    )) |dir| return dir;

    const dir = b.graph.environ_map.get("GRAPHVIZ_SRC") orelse return null;
    // The cache system cannot track an environment variable.
    b.graph.poisonCache();
    return dir;
}

fn addIncludePaths(tc: Translator, b: *std.Build, upstream: Upstream) void {
    inline for (comptime includeDirs()) |dir| tc.addIncludePath(upstream.path(b, dir));
}

fn addModuleIncludePaths(mod: *std.Build.Module, b: *std.Build, upstream: Upstream) void {
    inline for (comptime includeDirs()) |dir| mod.addIncludePath(upstream.path(b, dir));
}

fn includeDirs() []const []const u8 {
    return &.{
        ".", // graphviz_version.h, builddate.h
        "lib", // <gvc/gvplugin.h>, <cgraph/cgraph.h> style includes
        "lib/cdt",
        "lib/cgraph",
        "lib/common",
        "lib/gvc",
        "lib/pathplan",
        "lib/label",
        "lib/pack",
        "lib/util",
        "lib/xdot",
        "plugin/core",
    };
}

const SourceSet = struct { dir: []const u8, files: []const []const u8 };

fn sourceSets() []const SourceSet {
    return &.{
        .{ .dir = "lib/cdt", .files = &.{
            "dtclose.c",   "dtdisc.c",   "dtextract.c", "dtflatten.c",
            "dthash.c",    "dtmethod.c", "dtopen.c",    "dtrenew.c",
            "dtrestore.c", "dtsize.c",   "dtstat.c",    "dtstrhash.c",
            "dttree.c",    "dtview.c",   "dtwalk.c",
        } },
        .{
            .dir = "lib/cgraph",
            .files = &.{
                "acyclic.c",  "agerror.c",   "apply.c",  "attr.c",
                "edge.c",     "graph.c",     "id.c",     "imap.c",
                "ingraphs.c", "io.c",        "node.c",   "node_induce.c",
                "obj.c",      "rec.c",       "refstr.c", "subg.c",
                "tred.c",     "unflatten.c", "utils.c",  "write.c",
                // Shipped pre-generated in the release tarball.
                "grammar.c",  "scan.c",
            },
        },
        .{ .dir = "lib/util", .files = &.{
            "arena.c", "base64.c", "gv_find_me.c", "gv_fopen.c",
            "list.c",  "random.c", "xml.c",
        } },
        .{ .dir = "lib/pathplan", .files = &.{
            "cvt.c",         "inpoly.c",  "route.c",  "shortest.c",
            "shortestpth.c", "solvers.c", "triang.c", "util.c",
            "visibility.c",
        } },
        .{ .dir = "lib/xdot", .files = &.{"xdot.c"} },
        .{ .dir = "lib/label", .files = &.{
            "index.c", "node.c", "rectangle.c", "split.q.c", "xlabels.c",
        } },
        .{
            .dir = "lib/common",
            .files = &.{
                "args.c",      "arrows.c",       "colxlate.c", "ellipse.c",
                "emit.c",      "geom.c",         "globals.c",  "htmllex.c",
                "htmltable.c", "input.c",        "labels.c",   "ns.c",
                "output.c",    "pointset.c",     "postproc.c", "psusershape.c",
                "routespl.c",  "shapes.c",       "splines.c",  "taper.c",
                "textspan.c",  "textspan_lut.c", "timing.c",   "utils.c",
                // Shipped pre-generated in the release tarball.
                "htmlparse.c",
            },
        },
        .{ .dir = "lib/pack", .files = &.{ "ccomps.c", "pack.c" } },
        .{ .dir = "lib/gvc", .files = &.{
            "gvc.c",         "gvconfig.c", "gvcontext.c",    "gvdevice.c",
            "gvevent.c",     "gvjobs.c",   "gvlayout.c",     "gvloadimage.c",
            "gvplugin.c",    "gvrender.c", "gvtextlayout.c", "gvtool_tred.c",
            "gvusershape.c",
        } },
        .{ .dir = "lib/dotgen", .files = &.{
            "acyclic.c",  "aspect.c",     "class1.c", "class2.c",
            "cluster.c",  "compound.c",   "conc.c",   "decomp.c",
            "dotinit.c",  "dotsplines.c", "fastgr.c", "flat.c",
            "mincross.c", "position.c",   "rank.c",   "sameport.c",
        } },
        .{ .dir = "plugin/dot_layout", .files = &.{
            "gvplugin_dot_layout.c", "gvlayout_dot_layout.c",
        } },
        // plugin/core is compiled whole: gvplugin_core.c's symbol table
        // references every gvrender_*_types, so dropping a renderer would
        // break the link. They are all dependency-free, so the extras
        // (ps/fig/pic/pov/map/tk) come along at no cost beyond compile time.
        .{ .dir = "plugin/core", .files = &.{
            "gvloadimage_core.c",  "gvplugin_core.c",      "gvrender_core_dot.c",
            "gvrender_core_fig.c", "gvrender_core_json.c", "gvrender_core_map.c",
            "gvrender_core_pic.c", "gvrender_core_pov.c",  "gvrender_core_ps.c",
            "gvrender_core_svg.c", "gvrender_core_tk.c",
        } },
    };
}
