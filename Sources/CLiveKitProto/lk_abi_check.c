/* Guards the lk_pb_config.h include in pb.h: if a nanopb upgrade drops it,
 * fail loudly instead of silently changing struct layout under Swift. */
#include <pb.h>

#ifndef PB_ENABLE_MALLOC
#error "pb.h lost the LiveKit include of lk_pb_config.h (PB_ENABLE_MALLOC)"
#endif
#ifndef PB_BUFFER_ONLY
#error "pb.h lost the LiveKit include of lk_pb_config.h (PB_BUFFER_ONLY)"
#endif
_Static_assert(sizeof(pb_size_t) == 4, "PB_FIELD_32BIT must reach pb.h via lk_pb_config.h");
