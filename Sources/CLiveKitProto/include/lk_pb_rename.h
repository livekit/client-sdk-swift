/*
 * Renames every external symbol, type name and enum constant of the vendored
 * nanopb runtime to an lk_ / LK_ prefix. Included from lk_pb_config.h (reached via lk_pb.h's marked LiveKit
 * block), so every translation unit (runtime .c, generated .c, and the Swift
 * importer) sees the same renamed declarations.
 *
 * Why: apps commonly embed a second nanopb — Firebase pods ship one — and
 * under static linking the duplicate C symbols do NOT collide loudly: the
 * first archive in link order wins and serves BOTH SDKs, silently crossing
 * incompatible nanopb versions and ABI configurations (verified against
 * FirebaseMessaging: its 0.3.x generated code bound to this 0.4.x runtime).
 *
 * The header file names and include guards carry the prefix too (lk_pb.h,
 * LK_PB_H_INCLUDED), and generated code includes them by quoted name: a
 * second nanopb's pb.h on the consumer's header search path (Firebase's
 * SwiftPM target exposes one) would otherwise shadow ours -- or be shadowed
 * by it -- and a shared PB_H_INCLUDED guard no-ops whichever comes second.
 *
 * Types, struct tags and enum constants are renamed as well: `import LiveKit`
 * loads this module into every consumer translation unit (non-resilient Swift
 * modules load their whole dependency closure), and Clang refuses to merge two
 * modules that define the same C name differently -- so an app that also
 * imports another nanopb module would fail to compile.
 *
 * Regenerate the lists after a nanopb upgrade: they must cover every symbol in
 * `nm -gU pb_common.o pb_decode.o pb_encode.o` and every typedef, struct tag
 * and enum constant in `grep -E 'typedef|^struct pb_|PB_WT_' lk_pb*.h`.
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

/* Types and struct tags (pb.h) */
#define pb_byte_t lk_pb_byte_t
#define pb_type_t lk_pb_type_t
#define pb_size_t lk_pb_size_t
#define pb_ssize_t lk_pb_ssize_t
#define pb_istream_s lk_pb_istream_s
#define pb_istream_t lk_pb_istream_t
#define pb_ostream_s lk_pb_ostream_s
#define pb_ostream_t lk_pb_ostream_t
#define pb_field_iter_s lk_pb_field_iter_s
#define pb_field_iter_t lk_pb_field_iter_t
#define pb_field_t lk_pb_field_t
#define pb_msgdesc_s lk_pb_msgdesc_s
#define pb_msgdesc_t lk_pb_msgdesc_t
#define pb_bytes_array_s lk_pb_bytes_array_s
#define pb_bytes_array_t lk_pb_bytes_array_t
#define pb_callback_s lk_pb_callback_s
#define pb_callback_t lk_pb_callback_t
#define pb_wire_type_t lk_pb_wire_type_t
#define pb_extension_type_s lk_pb_extension_type_s
#define pb_extension_type_t lk_pb_extension_type_t
#define pb_extension_s lk_pb_extension_s
#define pb_extension_t lk_pb_extension_t

/* Enum constants (pb_wire_type_t) */
#define PB_WT_VARINT LK_PB_WT_VARINT
#define PB_WT_64BIT LK_PB_WT_64BIT
#define PB_WT_STRING LK_PB_WT_STRING
#define PB_WT_32BIT LK_PB_WT_32BIT
#define PB_WT_PACKED LK_PB_WT_PACKED

#endif /* LK_PB_RENAME_H_INCLUDED */
