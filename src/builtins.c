// Static plugin registration, modelled on upstream's cmd/dot/dot_builtins.cpp.
//
// With ENABLE_LTDL undefined, gvconfig.c takes the "builtins don't require
// LTDL" path (lib/gvc/gvconfig.c) and installs whatever table was handed to
// gvContextPlugins(). No dlopen, no plugin search path, no config6 file.

#include "config.h"

#include <cgraph/cgraph.h>
#include <gvc/gvplugin.h>

extern gvplugin_library_t gvplugin_dot_layout_LTX_library;
extern gvplugin_library_t gvplugin_core_LTX_library;

lt_symlist_t lt_preloaded_symbols[] = {
    {"gvplugin_dot_layout_LTX_library", &gvplugin_dot_layout_LTX_library},
    {"gvplugin_core_LTX_library", &gvplugin_core_LTX_library},
    {0, 0},
};

const lt_symlist_t *gv_builtin_plugins(void) { return lt_preloaded_symbols; }

// Agdesc_t is seven `unsigned:1` bitfields, and translate-c lowers any struct
// containing bitfields to an opaque type. That makes agopen() -- which takes
// one by value -- uncallable from Zig. Reduce it to plain ints here.
Agraph_t *gv_open_graph(char *name, int directed, int strict) {
  Agdesc_t desc = directed ? (strict ? Agstrictdirected : Agdirected)
                           : (strict ? Agstrictundirected : Agundirected);
  return agopen(name, desc, NULL);
}
