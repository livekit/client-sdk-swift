/*
 * Renames every external symbol of the vendored nanopb runtime to an lk_
 * prefix. Included from pb.h's marked LiveKit block, so every translation
 * unit (runtime .c, generated .c, and the Swift importer) sees the same
 * renamed declarations.
 *
 * Why: apps commonly embed a second nanopb — Firebase pods ship one — and
 * under static linking the duplicate C symbols do NOT collide loudly: the
 * first archive in link order wins and serves BOTH SDKs, silently crossing
 * incompatible nanopb versions and ABI configurations (verified against
 * FirebaseMessaging: its 0.3.x generated code bound to this 0.4.x runtime).
 *
 * Regenerate the list after a nanopb upgrade: it must cover every symbol in
 * `nm -gU pb_common.o pb_decode.o pb_encode.o`.
 */

#ifndef LK_PB_RENAME_H_INCLUDED
#define LK_PB_RENAME_H_INCLUDED

/* pb_common.c */
#define pb_field_iter_begin lk_pb_field_iter_begin
#define pb_field_iter_begin_const lk_pb_field_iter_begin_const
#define pb_field_iter_begin_extension lk_pb_field_iter_begin_extension
#define pb_field_iter_begin_extension_const lk_pb_field_iter_begin_extension_const
#define pb_field_iter_find lk_pb_field_iter_find
#define pb_field_iter_find_extension lk_pb_field_iter_find_extension
#define pb_field_iter_next lk_pb_field_iter_next

/* pb_decode.c */
#define pb_close_string_substream lk_pb_close_string_substream
#define pb_decode lk_pb_decode
#define pb_decode_bool lk_pb_decode_bool
#define pb_decode_ex lk_pb_decode_ex
#define pb_decode_fixed32 lk_pb_decode_fixed32
#define pb_decode_fixed64 lk_pb_decode_fixed64
#define pb_decode_svarint lk_pb_decode_svarint
#define pb_decode_tag lk_pb_decode_tag
#define pb_decode_varint lk_pb_decode_varint
#define pb_decode_varint32 lk_pb_decode_varint32
#define pb_default_field_callback lk_pb_default_field_callback
#define pb_istream_from_buffer lk_pb_istream_from_buffer
#define pb_make_string_substream lk_pb_make_string_substream
#define pb_read lk_pb_read
#define pb_release lk_pb_release
#define pb_skip_field lk_pb_skip_field

/* pb_encode.c */
#define pb_encode lk_pb_encode
#define pb_encode_ex lk_pb_encode_ex
#define pb_encode_fixed32 lk_pb_encode_fixed32
#define pb_encode_fixed64 lk_pb_encode_fixed64
#define pb_encode_string lk_pb_encode_string
#define pb_encode_submessage lk_pb_encode_submessage
#define pb_encode_svarint lk_pb_encode_svarint
#define pb_encode_tag lk_pb_encode_tag
#define pb_encode_tag_for_field lk_pb_encode_tag_for_field
#define pb_encode_varint lk_pb_encode_varint
#define pb_get_encoded_size lk_pb_get_encoded_size
#define pb_ostream_from_buffer lk_pb_ostream_from_buffer
#define pb_write lk_pb_write

#endif /* LK_PB_RENAME_H_INCLUDED */
