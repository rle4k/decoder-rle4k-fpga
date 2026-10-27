#pragma once

#include <cstdint>

// RLE4K public API
//
// Data model
// - Input/Output "image blocks" are 1-bit-per-pixel, bit-packed buffers.
// - Bit order inside each byte is LSB-first (bit0 is the first pixel, bit7 is the 8th pixel).
// - `width` is measured in *bits* (pixels), not bytes.
// - `stride` is measured in *bytes per row*. If `stride == 0`, it defaults to ceil(width / 8).
//
// Return value
// - On success, functions return the number of bytes written to the output buffer.
// - On failure, functions return a negative error code defined below.
//
// IMPORTANT
// - These APIs do NOT take an output-buffer capacity parameter; the caller must ensure the
//   destination buffer is large enough.
// - Prefer the *_block() APIs when decoding, because they have explicit width/height and can
//   compute the expected output buffer size.

#define RLE4K_ERROR_NULL_POINTER         (-1)
#define RLE4K_ERROR_INVALID_DIMENSION    (-2)
#define RLE4K_ERROR_INVALID_STRIDE       (-3)
#define RLE4K_ERROR_INVALID_LENGTH       (-4)
#define RLE4K_ERROR_WIDTH_EXCEEDS_STRIDE (-5)
#define RLE4K_ERROR_TARGET_TOO_SMALL     (-100)

#ifndef DISALBE_RLE4K_LIB
	#ifdef _DEBUG
	#pragma comment(lib,"librle4kd.lib")
	#else
	#pragma comment(lib,"librle4k.lib")
	#endif
#endif

/**
 * Encode a bit-packed image block (row-by-row).
 *
 * @param block   Pointer to the source image bytes. Each row starts at `block + row * stride`.
 * @param height  Number of rows.
 * @param width   Row width in bits (pixels).
 * @param encoded       Output buffer for the encoded stream.
 * @param stride        Source stride in bytes per row. If 0, uses ceil(width / 8).
 * @param target_length Capacity of encoded buffer in bytes. If exceeded during encoding, returns RLE4K_ERROR_TARGET_TOO_SMALL.
 * @return Encoded byte count on success; negative error code on failure.
 */
int rle4k_encode_block(const uint8_t* block, uint32_t height, uint32_t width, uint8_t* encoded, uint32_t stride, uint32_t target_length = 0);

/**
 * Decode an encoded stream into a bit-packed image block (row-by-row).
 *
 * @param encoded Input encoded stream.
 * @param inlen   Length of encoded stream in bytes.
 * @param block   Output buffer for the decoded image bytes.
 * @param width   Row width in bits (pixels). Use `UINT32_MAX` only for the legacy "mode 2"
 *                heuristic path (not recommended for untrusted input).
 * @param height  Number of rows to decode.
 * @param stride  Destination stride in bytes per row. If 0, uses ceil(width / 8) when width is
 *                known; otherwise uses a heuristic when width==UINT32_MAX.
 * @return Decoded buffer size in bytes on success; negative error code on failure.
 */
int rle4k_decode_block(const uint8_t* encoded, uint32_t inlen, uint8_t * block, uint32_t width, uint32_t height, uint32_t stride = 0);

/**
 * Encode a raw byte stream (legacy "mode 2").
 *
 * This is equivalent to encoding a single-row bit stream with width = length * 8.
 *
 * @param stream  Source bytes.
 * @param length  Source length in bytes.
 * @param encoded Output buffer for the encoded stream.
 * @return Encoded byte count on success; negative error code on failure.
 */
int rle4k_encode(const uint8_t * stream, uint32_t length, uint8_t * encoded);

/**
 * Decode a raw encoded stream (legacy "mode 2").
 *
 * WARNING: This API does not know the decoded size and does not accept a destination capacity.
 * Prefer `rle4k_decode_block()` when possible.
 *
 * @param encoded Input encoded stream.
 * @param length  Length of encoded stream in bytes.
 * @param stream  Output buffer for decoded bytes (caller-managed).
 * @return Decoded byte count on success; negative error code on failure.
 */
int rle4k_decode(const uint8_t* encoded, uint32_t length, uint8_t * stream);
