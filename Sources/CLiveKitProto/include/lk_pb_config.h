/*
 * LiveKit configuration for the vendored nanopb runtime. Included from pb.h's
 * marked LiveKit block — the only modification to that upstream file — so
 * every translation unit (runtime .c, generated .c, and the Swift importer)
 * sees the same configuration.
 *
 * The ABI defines MUST live in a header, not in build settings: SwiftPM has
 * no propagated-defines mechanism, and cSettings are invisible to the Swift
 * Clang importer — a mismatch silently changes struct layout across the
 * language boundary. Compile-time guards live in lk_abi_check.c.
 */

#ifndef LK_PB_CONFIG_H_INCLUDED
#define LK_PB_CONFIG_H_INCLUDED

#define PB_ENABLE_MALLOC 1     /* decode allocates; pb_release frees */
#define PB_NO_PACKED_STRUCTS 1 /* packed structs break the Swift importer */
#define PB_FIELD_32BIT 1       /* bytes/repeated >65535 (audio buffers) */
#define PB_BUFFER_ONLY 1       /* we never use stream callbacks */

/* lk_ prefix on all runtime symbols: a second embedded nanopb (e.g. from
 * Firebase pods) would otherwise resolve against ours under static linking —
 * silently, across incompatible versions. See lk_pb_rename.h. */
#include "lk_pb_rename.h"

#endif
