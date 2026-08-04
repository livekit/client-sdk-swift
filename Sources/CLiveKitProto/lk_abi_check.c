/* Guards the ABI block in pb.h: if a nanopb upgrade drops it, fail loudly
 * instead of silently changing struct layout under Swift. */
#include <pb.h>

#ifndef PB_ENABLE_MALLOC
#error "pb.h lost the LiveKit ABI block (PB_ENABLE_MALLOC)"
#endif
#ifndef PB_BUFFER_ONLY
#error "pb.h lost the LiveKit ABI block (PB_BUFFER_ONLY)"
#endif
_Static_assert(sizeof(pb_size_t) == 4, "PB_FIELD_32BIT must be set in pb.h");
