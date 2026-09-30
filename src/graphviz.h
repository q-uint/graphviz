// Single translate-c root. graphviz's public surface is split across cgraph
// (the graph data structure) and gvc (layout + rendering), so both are pulled
// in here and exposed as one Zig module.
#pragma once

#include <cgraph/cgraph.h>
#include <gvc/gvc.h>
#include <gvc/gvplugin.h>

/// The statically compiled plugin table defined in builtins.c. Pass this to
/// gvContextPlugins() with demand_loading = 0 for a self-contained context.
extern const lt_symlist_t *gv_builtin_plugins(void);

/// agopen() takes an Agdesc_t by value, which translate-c cannot express
/// because it is a bitfield struct. See builtins.c.
extern Agraph_t *gv_open_graph(char *name, int directed, int strict);
