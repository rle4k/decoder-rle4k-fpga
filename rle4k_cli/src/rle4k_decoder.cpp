#include <algorithm>
#include <cstring>

#include "rle4k.h"

// RLE4K protocol constants
constexpr int SEG_BYTE_MAX_LEN = 64;  // Bit segment length
constexpr uint8_t RLE4K_BLOCK_END = 0xC0;  // Block end control code

// Short ones table: for bit-level filling - LSB-first bit order
static const uint8_t SHORT_ONES_TABLE[8] = {
	0x00, // Placeholder, 0 ones
	0x01, // 1 one: 0000 0001 (LSB-first)
	0x03, // 2 ones: 0000 0011 (LSB-first)
	0x07, // 3 ones: 0000 0111 (LSB-first)
	0x0F, // 4 ones: 0000 1111 (LSB-first)
	0x1F, // 5 ones: 0001 1111 (LSB-first)
	0x3F, // 6 ones: 0011 1111 (LSB-first)
	0x7F  // 7 ones: 0111 1111 (LSB-first)
};

// Precomputed 0xFF byte array for fast filling
static const uint8_t FILL_FF_BYTES[16] = {
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
};

// RLE4K decoder state structure
struct RLE4KSmartDecoderContext {
	bool ModeFlag;          // Current run bit value (0 or 1)
	bool IsBlockMode;       // Whether in block mode
	uint8_t* Target;
	const uint8_t* Source;
	uint32_t ImageWidth;
	uint32_t ImageHeight;
	uint32_t SourceLength;
	uint32_t TargetLength;

	uint32_t CountedBitsInRow;        // Total bit length counted in row
	uint32_t CurrentByteIndexInTarget; // Current byte position in row being decoded
	int32_t RowNo;                    // Current row number being decoded
	uint32_t RowHeaderByteIndexInSource; // Source byte index of row header being decoded
	uint32_t CurrentByteIndexInSource;   // Current byte position being decoded
	uint32_t SegmentBitsLength;          // Current length of segment being decoded
	uint32_t DecodedBitsIndexInRow;      // Bit index already decoded in current row
	uint32_t ExpectedRowBits;            // Expected bit length in row
	uint32_t DecodedBytesPerRow;         // Decoded bytes per row
	uint32_t RowHeaderByteIndexInTarget; // Target byte index of row header being decoded
	bool BlockEndReached;                // 0xC0 block end marker encountered

	RLE4KSmartDecoderContext(const uint8_t* source, uint8_t* target, uint32_t width, uint32_t height, uint32_t bytesPerRow) {
		Target = target;
		Source = source;
		CurrentByteIndexInSource = 0;
		RowNo = -1; // wait new row
		RowHeaderByteIndexInSource = 0;
		ModeFlag = false;
		IsBlockMode = false;
		CountedBitsInRow = 0;
		SegmentBitsLength = 0;
		CurrentByteIndexInTarget = 0;
		DecodedBitsIndexInRow = 0;
		ImageWidth = width;
		ImageHeight = height;
		SourceLength = 0; // Will be set externally
		TargetLength = 0; // Will be set externally
		DecodedBytesPerRow = bytesPerRow;
		RowHeaderByteIndexInTarget = 0;
		ExpectedRowBits = width;
		BlockEndReached = false;
	}

	// Initialize row state
	void StartNewRow() {
		RowNo++; // NEW ROW
		RowHeaderByteIndexInSource = CurrentByteIndexInSource;

		// Calculate starting position of current row in target buffer
		CurrentByteIndexInTarget = RowNo * DecodedBytesPerRow;
		uint8_t firstByte = ReadNext();

		if (firstByte == RLE4K_BLOCK_END) {
			BlockEndReached = true;
			SegmentBitsLength = 0;
			CountedBitsInRow = 0;
			DecodedBitsIndexInRow = 0;
			return;
		}

		IsBlockMode = (firstByte & 0x80) != 0; // Mode bit
		ModeFlag = (firstByte & 0x40) != 0; // Image bit
		uint32_t length = firstByte & 0x3F; // Length bits

		if (IsBlockMode) {
			// Block compression mode: length bits × BLEN
			SegmentBitsLength = length * SEG_BYTE_MAX_LEN;
		}
		else {
			SegmentBitsLength = length;
		}

		SegmentBitsLength = std::min(SegmentBitsLength, ExpectedRowBits);

		CountedBitsInRow = SegmentBitsLength;
		DecodedBitsIndexInRow = 0;
	}

	// Check if reached end of row
	bool IsRowEnd() const {
		return CountedBitsInRow >= ExpectedRowBits;
	}

	// Check if reached end of data stream
	bool IsStreamEnd() const {
		return CurrentByteIndexInSource >= SourceLength;
	}

	uint8_t ReadNext() {
		if (CurrentByteIndexInSource >= SourceLength)
			throw std::exception("overflow the source length when ReadNext().");

		uint8_t value = Source[CurrentByteIndexInSource];
		CurrentByteIndexInSource++;
		return value;
	}

	bool IsRowOverflow() const {
		return CountedBitsInRow > ExpectedRowBits;
	}
};

// Fast fill byte array
inline void FillBytes(uint8_t* array, uint32_t startIndex, uint32_t count, uint8_t value) {
	// Use precomputed fill array for fast copy
	if (value == 0xFF && count <= 16) {
		memcpy(array + startIndex, FILL_FF_BYTES, count);
	}
	else {
		// Fallback to byte-by-byte filling
		memset(array + startIndex, value, count);
	}
}

// Decode segment: fill accumulated bit run into target buffer
inline void DecodeSegment(RLE4KSmartDecoderContext& context) {
	if (context.SegmentBitsLength <= 0) {
		return;
	}

	uint8_t* target = context.Target;
	bool isOne = context.ModeFlag;

	uint32_t bitsInByte = context.DecodedBitsIndexInRow & 0x07;
	// First fill remaining part of current byte: if non-zero, current byte is not fully filled
	if (bitsInByte > 0) {
		uint32_t segmentBits = context.SegmentBitsLength;
		uint32_t leftBitsInCurrentByte = 8u - bitsInByte;

		// Calculate available bit length in current byte, take segment length if it's less than remaining bits
		uint32_t bitsToFill = segmentBits > leftBitsInCurrentByte ? leftBitsInCurrentByte : segmentBits;

		if (isOne) {
			uint8_t pattern = SHORT_ONES_TABLE[bitsToFill];
			// Move current value to corresponding position in byte bit order - using LSB-first bit order
			target[context.CurrentByteIndexInTarget] |= (pattern << bitsInByte);
		}
		// Zero runs don't need filling since bytes are initialized to 0

		context.SegmentBitsLength -= bitsToFill;
		context.DecodedBitsIndexInRow += bitsToFill;

		// Check if current byte is completed
		if ((context.DecodedBitsIndexInRow & 0x07) == 0) {
			context.CurrentByteIndexInTarget++;
		}
	}

	if (context.SegmentBitsLength <= 0) {
		return;
	}

	// Then fill complete bytes
	if (context.SegmentBitsLength >= 8) {
		uint32_t byteCount = context.SegmentBitsLength >> 3;
		if (isOne) {
			FillBytes(target, context.CurrentByteIndexInTarget, byteCount, 0xFF);
		}
		context.CurrentByteIndexInTarget += byteCount;
		uint32_t bitsLength = byteCount << 3;
		context.DecodedBitsIndexInRow += bitsLength;
		context.SegmentBitsLength -= bitsLength;
	}

	uint32_t remainBits = context.SegmentBitsLength & 0x07;

	// Finally fill remaining incomplete byte
	if (remainBits > 0) {
		if (isOne) {
			uint8_t fillPattern = SHORT_ONES_TABLE[remainBits];
			target[context.CurrentByteIndexInTarget] |= fillPattern;  // LSB-first bit order
		}

		context.DecodedBitsIndexInRow += remainBits;
		if ((context.DecodedBitsIndexInRow & 0x07) == 0) {
			context.CurrentByteIndexInTarget++;
		}
	}

	// Reset bit length
	context.SegmentBitsLength = 0;
}

int rle4k_decode_block(const uint8_t* encoded, uint32_t dataLength, uint8_t* encoding, uint32_t width, uint32_t height, uint32_t stride) {
	if (!encoded || !encoding) {
		return -1;
	}

	if (dataLength == 0) {
		return -2;
	}
	
	if (dataLength >= 2)
	{
		uint16_t start_flag = 0x4040;
		int cmp = memcmp(&start_flag, encoded, 2);
		if (cmp == 0)
		{
			return -3; // error mode.
		}
	}

	uint32_t bytesPerRow;
	if (stride != 0)
	{
		bytesPerRow = stride;
		if (width != UINT32_MAX && width > (stride << 3))
			return -3;
	}
	else
	{
		if (width == UINT32_MAX)
		{
			// Mode 2: calculate from data length
			bytesPerRow = (dataLength + 7) / 8; // Approximate
		}
		else
		{
			bytesPerRow = (width + 7) / 8;
		}
	}
	uint32_t targetSize = bytesPerRow * height;

	// Initialize target buffer
	memset(encoding, 0, targetSize);

	RLE4KSmartDecoderContext context(
		encoded,
		encoding,
		width, height,
		bytesPerRow
	);

	context.SourceLength = dataLength;
	context.TargetLength = targetSize;

	// Process row by row
	while (!context.IsStreamEnd() && !context.BlockEndReached) {
		// Check if target buffer is full
		if (context.CurrentByteIndexInTarget >= context.TargetLength) {
			break;
		}

		// Initialize decoding state for current row
		context.StartNewRow();
		if (context.BlockEndReached) break;

		// Main decoding loop
		while (!context.IsStreamEnd() && !context.IsRowEnd() && !context.BlockEndReached) {
			// Check if target buffer is full
			if (context.CurrentByteIndexInTarget >= context.TargetLength) {
				break;
			}

			// Check for data type change
			uint8_t nextByte = context.ReadNext();

			if (nextByte == RLE4K_BLOCK_END) {
				DecodeSegment(context);
				context.BlockEndReached = true;
				break;
			}

			bool nextIsBlockMode = (nextByte & 0x80) != 0; // Mode bit
			bool nextIsOne = (nextByte & 0x40) != 0; // Image bit
			bool currentIsOne = context.ModeFlag;
			uint32_t countBits = nextByte & 0x3F; // Length bits

			// Calculate actual length based on mode
			if (nextIsBlockMode) {
				countBits <<= 6; // countBits *= 64; // BLEN = 64
			}

			context.CountedBitsInRow += countBits;
			if (context.IsRowOverflow()) {
				countBits = countBits - (context.CountedBitsInRow - context.ExpectedRowBits);
				context.CountedBitsInRow = context.ExpectedRowBits;
			}

			if (nextIsOne != currentIsOne) {
				// Data type changed: decode accumulated segment first
				DecodeSegment(context);

				// Check if target buffer is full
				if (context.CurrentByteIndexInTarget >= context.TargetLength) {
					break;
				}

				// Update current context
				context.ModeFlag = nextIsOne;
				context.IsBlockMode = nextIsBlockMode;
				context.SegmentBitsLength = countBits;
			}
			else {
				context.SegmentBitsLength += countBits;
			}
		}
		DecodeSegment(context);
	}

	DecodeSegment(context);
	return static_cast<int>(targetSize);
}

int rle4k_decode(const uint8_t* encoded, uint32_t length, uint8_t* encoding) {
	if (!encoded || !encoding) {
		return RLE4K_ERROR_NULL_POINTER;
	}

	if (length < 1) {
		return RLE4K_ERROR_INVALID_LENGTH;
	}
	
	uint32_t encodedDataLength = length;
	
	if (encodedDataLength == 0) {
		return RLE4K_ERROR_INVALID_LENGTH;
	}

	// Initialize context for single-row decoding
	RLE4KSmartDecoderContext context(
		encoded,
		encoding,
		UINT32_MAX, 
		1,  // Single row
		(length + 7) / 8
	);

	context.SourceLength = encodedDataLength;
	context.TargetLength = UINT32_MAX; // Calculate target size from width

	// Initialize the single row
	context.StartNewRow();

	// Decode single row (no outer loop needed since height=1)
	while (!context.IsStreamEnd()) {
		// Read next encoded byte
		uint8_t nextByte = context.ReadNext();

		bool nextIsBlockMode = (nextByte & 0x80) != 0; // Mode bit
		bool nextIsOne = (nextByte & 0x40) != 0;        // Image bit
		bool currentIsOne = context.ModeFlag;
		uint32_t countBits = nextByte & 0x3F;          // Length bits

		// Calculate actual length based on mode
		if (nextIsBlockMode) {
			countBits <<= 6; // countBits *= 64 (BLEN)
		}

		context.CountedBitsInRow += countBits;
		
		// Handle row overflow
		if (context.IsRowOverflow()) {
			countBits = countBits - (context.CountedBitsInRow - context.ExpectedRowBits);
			context.CountedBitsInRow = context.ExpectedRowBits;
		}

		// Handle bit value change
		if (nextIsOne != currentIsOne) {
			// Bit value changed: decode accumulated segment first
			DecodeSegment(context);

			// Update context for new bit value
			context.ModeFlag = nextIsOne;
			context.IsBlockMode = nextIsBlockMode;
			context.SegmentBitsLength = countBits;
		}
		else {
			// Same bit value: accumulate length
			context.SegmentBitsLength += countBits;
		}
	}

	// Decode remaining segment
	DecodeSegment(context);
	
	return static_cast<int>(context.CurrentByteIndexInTarget);
}

