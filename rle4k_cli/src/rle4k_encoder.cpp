#include <cstdint>
#include <cstring>

#include "rle4k.h"

// Constants for bit manipulation and encoding
constexpr uint64_t U64DARK = UINT64_MAX;      // Value representing all bits set to 1
constexpr uint8_t UEMPTY = 0;               // Value representing all bits set to 0

// Maximum values for run-length encoding segments
static constexpr uint16_t SEG_BYTE_MAX_LEN = 64;      // Max length per segment byte
static constexpr uint16_t SEG_BYTE_MAX_CNT = 63;      // Max count for segment runs
static constexpr uint16_t SEG_RUN_BYTE_MAX_LEN = SEG_BYTE_MAX_CNT * SEG_BYTE_MAX_LEN; // Max run length

// Short run maximum codes for 0 and 1 sequences
constexpr char LONG0_RUN_CODE = static_cast<char>(0x80 | 0x00 | 0x3F); // the shortest long run for 0s
constexpr char LONG1_RUN_CODE = static_cast<char>(0x80 | 0x40 | 0x3F); // the shortest long run for 1s

namespace RLE4K {

/**
 * Union for packing different data types into a single memory space
 * Allows access to the same memory as different data types (64-bit, 32-bit, etc.)
 */
union PackNode
{
	uint64_t uint64v;            // Access as 64-bit unsigned integer
	uint8_t  uint8v;             // Access as 8-bit unsigned integer
	uint32_t uint32v;            // Access as 32-bit unsigned integer
	uint16_t uint16v;            // Access as 16-bit unsigned integer
	uint8_t  uint8Arr[8];        // Access as array of 8-bit integers
	uint16_t uint16Array[4];     // Access as array of 4 16-bit integers
	uint32_t uint32Array[2];     // Access as array of 2 32-bit integers
};

/**
 * Structure representing a run-length encoding node
 * Contains information about how to encode a sequence of bits
 */
struct RLE4KRunNode
{
	int Index;                      // Index of the run
	char Run0Code;                  // Code for 0-bit runs
	char Run1Code;                  // Code for 1-bit runs
	uint8_t RemainLength;           // Remaining bits after main run

	RLE4KRunNode() = default;
	RLE4KRunNode(uint16_t index, uint8_t code0, uint8_t code1, uint8_t remains):
		Index(index),
		Run0Code(static_cast<char>(code0)),
		Run1Code(static_cast<char>(code1)),
		RemainLength(remains) {}
};

/**
 * Node representing a segment in RLE encoding
 * Contains flags and lengths for encoding segments
 */
class RLE4KSegmentNode
{
public:
	RLE4KSegmentNode()
	{
		RunFlag = false;
		length = 0;
		mark = 0;
	}

	RLE4KSegmentNode(uint8_t _mf, uint8_t _length) 
		: RunFlag(_mf & 0x40), length(_length), mark((_mf & 0x40) | _length) {}

	bool RunFlag;               // Flag indicating the bit mode (0 or 1)
	uint8_t length;              // Length of the segment
	uint8_t mark;                // Combined flag and length value
};

/**
 * Segment containing multiple nodes for RLE encoding
 * Represents a complete encoding unit with up to 8 nodes
 */
class RLE4KSegment
{
public:
	RLE4KSegmentNode Runs[8];   // Array of segment nodes
	int size;                    // Number of valid nodes in this segment
};

// Static lookup tables and arrays for encoding operations
static RLE4KRunNode MIDDLE_RUN_LUT[SEG_RUN_BYTE_MAX_LEN];

static uint8_t SHORT_RUN_LUT0[64];

static uint8_t SHORT_RUN_LUT1[64];

/**
 * Byte table class for RLE4K encoding
 * Contains precomputed segment information for all possible byte values (0-255)
 */
class RLE4000ByteTable
{
public:
	RLE4KSegment ByteRunsLUT[256];  // Precomputed segments for each possible byte value

	RLE4000ByteTable()
	{
		InitializeTables();
		InitializeLookupTables();
	}

	~RLE4000ByteTable() = default;

	/**
	 * Get the encoded value for a specific mode and length
	 */
	static inline uint8_t GetSingleByteValue(uint8_t modeFlag, uint8_t length);

private:
	/**
	 * Initialize segment tables based on bit patterns of each byte value
	 * This creates run-length encodings for each possible byte value (0-255)
	 */
	void InitializeTables();

	/**
	 * Initialize lookup tables for quick access to encoded values
	 * Creates codes for 0 and 1 bit runs of various lengths
	 */
	static void InitializeLookupTables();
};

} // namespace RLE4K

using namespace RLE4K;

// Global instance of the RLE4K table (precomputed at initialization)
static RLE4000ByteTable global_RLE4KLUT;

/**
 * Pack a single RLE node with specified length and starting value.
 * Handles both short and long runs of bits.
 * When dest_end is non-null, checks before each write and returns nullptr on overflow.
 *
 * @param dest     Output buffer for encoded data
 * @param dest_end One past last byte of output (nullptr = no bound check)
 * @param oneRun   Starting bit value (0 or 1) for the run
 * @param length   Length of the run to encode
 * @return Updated destination pointer, or nullptr if would exceed dest_end
 */
static uint8_t* PackSingleRun(uint8_t* dest, const uint8_t* dest_end, uint8_t oneRun, uint64_t length)
{
	if (length == 0) return dest;

	auto longRunModel = oneRun ? LONG1_RUN_CODE : LONG0_RUN_CODE;

	while (length >= SEG_RUN_BYTE_MAX_LEN)
	{
		if (dest_end && dest >= dest_end) return nullptr;
		*dest = longRunModel;
		dest++;
		length -= SEG_RUN_BYTE_MAX_LEN;
	}

	if (length >= SEG_BYTE_MAX_LEN)
	{
		if (dest_end && dest >= dest_end) return nullptr;
		auto& currentCode = MIDDLE_RUN_LUT[length];
		*dest = oneRun ? currentCode.Run1Code : currentCode.Run0Code;
		dest++;
		length = currentCode.RemainLength;
	}

	if (length > 0)
	{
		if (dest_end && dest >= dest_end) return nullptr;
		uint8_t code = (oneRun ? SHORT_RUN_LUT1 : SHORT_RUN_LUT0)[length];
		*dest = static_cast<char>(code);
		dest++;
	}

	return dest;
}

/**
 * Compare and pack a 64-bit chunk of data during RLE encoding.
 * When dest_end is non-null, checks before each write; returns false on overflow.
 *
 * @param dest_end One past last byte of output (nullptr = no bound check)
 * @return true on success, false if would exceed dest_end
 */
static bool RLE4KCmpAndPack(const uint64_t* data, PackNode& lastPN, uint64_t& lastRunAddr, int& lastBitPos, uint8_t*& dest, int byteSize, const uint8_t* dest_end)
{
	if (*data == lastPN.uint64v)
		return true;

	PackNode current;
	current.uint64v = *data;

	auto u64Index = (reinterpret_cast<uint64_t>(data) - lastRunAddr) << 3;

	for (int i = 0; i < byteSize; i++)
	{
		if ((current.uint8Arr[i]) != lastPN.uint8v)
		{
			const auto currByte = current.uint8Arr[i];
			int bitIndex = (i << 3);

			auto outBitLength = u64Index + bitIndex - lastBitPos;

			const auto& byteRuns = global_RLE4KLUT.ByteRunsLUT[currByte];
			auto runCount = byteRuns.size;
			int firstRun = 0;

			bool isSameRun = (lastPN.uint64v & 0x01) == byteRuns.Runs[0].RunFlag;
			if (isSameRun)
			{
				outBitLength += byteRuns.Runs[0].length;
				firstRun++;
			}

			dest = PackSingleRun(dest, dest_end, lastPN.uint8v & 0x40, outBitLength);
			if (!dest) return false;

			for (int j = firstRun; j < runCount - 1; j++)
			{
				if (dest_end && dest >= dest_end) return false;
				*dest = static_cast<char>(byteRuns.Runs[j].mark);
				dest++;
			}

			lastRunAddr = reinterpret_cast<uint64_t>(data);
			auto size = runCount - 1;
			auto& lastRun = byteRuns.Runs[size];
			lastBitPos = bitIndex + 8 - lastRun.length;
			lastPN.uint64v = lastRun.RunFlag ? U64DARK : UEMPTY;
			u64Index = 0;
		}
	}
	return true;
}

/**
 * Pack a single line of data using RLE4K algorithm.
 * When dest_end is non-null, stops and returns RLE4K_ERROR_TARGET_TOO_SMALL if write would exceed buffer.
 *
 * @param  target   Start of output buffer for this line
 * @param  buffer   Input buffer data to encode
 * @param  width    Width of the buffer in bits
 * @param  dest_end One past last byte of total output buffer (nullptr = no bound check)
 * @return Bytes written (>=0) on success, or RLE4K_ERROR_TARGET_TOO_SMALL on overflow
 */
static int32_t rle4k_encode_internal(uint8_t* target, const uint8_t* buffer, uint32_t width, const uint8_t* dest_end)
{
	uint8_t* dest = target;
	uint64_t lastRunPos = reinterpret_cast<uint64_t>(buffer);

	auto P64Start = reinterpret_cast<const uint64_t*>(buffer);
	const uint32_t uint64count = width >> 6;
	const uint32_t remainsBits = width & 63;
	auto P64End = P64Start + uint64count;
	auto ui64linbuffend = reinterpret_cast<uint64_t>(P64End);

	PackNode lastPN;
	lastPN.uint64v = buffer[0] & 0x01 ? U64DARK : UEMPTY;
	auto lastBitPos = 0;

	for (; P64Start < P64End; P64Start++)
	{
		if (!RLE4KCmpAndPack(P64Start, lastPN, lastRunPos, lastBitPos, dest, sizeof(PackNode), dest_end))
			return RLE4K_ERROR_TARGET_TOO_SMALL;
	}

	if (remainsBits)
	{
		if (!RLE4KCmpAndPack(P64Start, lastPN, lastRunPos, lastBitPos, dest, (remainsBits >> 3), dest_end))
			return RLE4K_ERROR_TARGET_TOO_SMALL;
	}
	 
	const auto leftBitsCount = ((ui64linbuffend - lastRunPos) << 3) + remainsBits - lastBitPos;
	if (leftBitsCount != 0)
	{
		dest = PackSingleRun(dest, dest_end, lastPN.uint8v & 0x40, leftBitsCount);
		if (!dest)
			return RLE4K_ERROR_TARGET_TOO_SMALL;
	}

	return static_cast<int32_t>(dest - target);
}

/**
 * Encode image data in mode 1 format (internal implementation)
 * Processes data row by row with support for strides
 * 
 * @param block Input image data
 * @param height Height of the image in rows
 * @param width Width of the image in bits
 * @param encoded Output buffer for encoded data
 * @param stride Memory stride between rows in bytes. if 0, stride be given by width.
 * @param target_length Capacity of encoded buffer in bytes. If 0, no check is performed.
 * @return Size of encoded data in bytes, or error code
 */
int rle4k_encode_block(const uint8_t* block, uint32_t height, uint32_t width, uint8_t* encoded, uint32_t stride, uint32_t target_length)
{
	if (block == nullptr || encoded == nullptr)
	{
		return RLE4K_ERROR_NULL_POINTER;
	}

	if (height == 0 || width == 0)
	{
		return RLE4K_ERROR_INVALID_DIMENSION;
	}

	if (stride == 0)
	{
		stride = (width + 7) / 8;
	}
	else
	{
		if (width > (stride << 3))
		{
			return RLE4K_ERROR_WIDTH_EXCEEDS_STRIDE;
		}
	}

	int32_t data_length = 0;
	uint32_t processed_length = 0;
	const uint8_t* dest_end = (target_length > 0) ? (encoded + target_length) : nullptr;

	for (uint32_t i = 0; i < height; i++, processed_length += stride)
	{
		int32_t n = rle4k_encode_internal(encoded + data_length, block + processed_length, width, dest_end);
		if (n < 0)
			return n;
		data_length += n;
	}

	return data_length;
}

/**
 * Encode data in mode 2 format (internal implementation)
 * Processes raw binary data with header information
 * 
 * @param source Input data to encode
 * @param sourceLength Length of input data in bytes
 * @param encoded Output buffer for encoded data
 * @return Size of encoded data in bytes, or error code
 */
int rle4k_encode(const uint8_t* source, uint32_t sourceLength, uint8_t* encoded)
{
	if (source == nullptr || encoded == nullptr)
	{
		return RLE4K_ERROR_NULL_POINTER;
	}

	if (sourceLength == 0)
	{
		return RLE4K_ERROR_INVALID_LENGTH;
	}

	uint32_t widthInBits = sourceLength << 3;
	int32_t encodedLength = rle4k_encode_internal(encoded, source, widthInBits, nullptr);
	return static_cast<int>(encodedLength);
}

/**
 * Initialize lookup tables for single-byte encoding
 * Creates encoding codes for runs of 0s and 1s of various lengths
 */
void RLE4000ByteTable::InitializeLookupTables()
{
	// Create codes for short runs (1-63 bits)
	for (uint8_t length = 1; length <= 63; ++length)
	{
		uint8_t code0 = static_cast<uint8_t>(0x00u | 0x00 | length); // Code for 0-bit runs
		SHORT_RUN_LUT0[length] = code0;
		uint8_t code1 = 0x00 | 0x40 | length; // Code for 1-bit runs
		SHORT_RUN_LUT1[length] = code1;
	}
	
	// Initialize run nodes for short lengths (0-63)
	for (uint16_t len = 0; len < SEG_BYTE_MAX_LEN; ++len)
	{		
		uint8_t code0 = static_cast<uint8_t>(0x80 | 0x00 | len);
		uint8_t code1 = static_cast<uint8_t>(0x80 | 0x40 | len);
		MIDDLE_RUN_LUT[len] = RLE4KRunNode(len, code0, code1, 0);
	}
	
	// Initialize run nodes for longer lengths (64 to max)
	for (uint16_t len = SEG_BYTE_MAX_LEN; len < SEG_RUN_BYTE_MAX_LEN; ++len)
	{
		uint16_t segments = static_cast<uint16_t>(len / SEG_BYTE_MAX_LEN);
		if (segments > SEG_BYTE_MAX_CNT) segments = SEG_BYTE_MAX_CNT;
		uint8_t code0 = static_cast<uint8_t>(0x80 | 0x00 | segments);
		uint8_t code1 = static_cast<uint8_t>(0x80 | 0x40 | segments);
		uint8_t left = static_cast<uint8_t>(len - segments * SEG_BYTE_MAX_LEN);
		MIDDLE_RUN_LUT[len] = RLE4KRunNode(static_cast<uint16_t>(segments), code0, code1, left);
	}
}

/**
 * Get encoded value from lookup table based on mode and length
 */
inline uint8_t RLE4000ByteTable::GetSingleByteValue(uint8_t modeFlag, uint8_t length)
{
	return (modeFlag ? SHORT_RUN_LUT1 : SHORT_RUN_LUT0)[length];
}

/**
 * Initialize segment tables for all possible byte values (0-255)
 * Each byte is analyzed for runs of consecutive bits (0s and 1s)
 */
void RLE4000ByteTable::InitializeTables()
{
	for (size_t j = 0; j < 256; j++)
	{
		auto currentValue = static_cast<uint8_t>(j);
		uint8_t currentModeFlag = currentValue & 0x01;
		uint8_t lastBitIndex = 0u;
		int idx = 0;

		// Analyze each bit in the byte, looking for changes in value
		for (uint8_t i = 0; i < 8; i++)
		{
			if ((currentValue & 0x01) != currentModeFlag)
			{
				uint8_t modeFlag = currentModeFlag ? 0x40 : 0x00;
				uint8_t length = i - lastBitIndex;
				if (length > 0)
				{
					ByteRunsLUT[j].Runs[idx++] = RLE4KSegmentNode(modeFlag, length);
				}
				currentModeFlag = currentValue & 0x01;
				lastBitIndex = i;
			}
			currentValue >>= 1; // Shift to next bit
		}

		// Handle the final run of bits
		uint8_t length = static_cast<uint8_t>(8u - lastBitIndex);
		if (length > 0)
		{
			uint8_t modeFlag = currentModeFlag ? 0x40 : 0x00;
			ByteRunsLUT[j].Runs[idx++] = RLE4KSegmentNode(modeFlag, length);
		}

		ByteRunsLUT[j].size = idx;
	}
}
