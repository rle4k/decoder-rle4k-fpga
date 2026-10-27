cmake_minimum_required(VERSION 3.15)
project(rle4k_cli_v8 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Npcap SDK (bundled with V08LAN)
set(NPCAP_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../npcap-sdk")

# RLE4K C++ reference codec (encoder + decoder).
#
# Canonical source is the in-repo copy under rle4k_cli/src/ so the CLI builds
# standalone with no external checkout. It is byte-identical (modulo CRLF/LF) to
# <path-redacted>/encoder-rle4k/librle4k/src as of 2026-08-08.
# See docs/V1.0/04-cli-cpp.md for the pinning decision.
#
# RLE4K_CPP_DIR is an *explicit override* only. When set, it must supply both
# rle4k_encoder.cpp and rle4k_decoder.cpp (plus rle4k.h).
set(RLE4K_CPP_DIR "" CACHE PATH
    "Override directory containing rle4k.h + rle4k_encoder.cpp + rle4k_decoder.cpp (empty = use in-repo src/)")

if(RLE4K_CPP_DIR)
    foreach(_req rle4k.h rle4k_encoder.cpp rle4k_decoder.cpp)
        if(NOT EXISTS "${RLE4K_CPP_DIR}/${_req}")
            message(FATAL_ERROR
                "RLE4K_CPP_DIR override '${RLE4K_CPP_DIR}' is missing ${_req}. "
                "Clear the cache variable to fall back to the in-repo copy.")
        endif()
    endforeach()
    set(RLE4K_CODEC_DIR "${RLE4K_CPP_DIR}")
    message(STATUS "RLE4K codec: OVERRIDE ${RLE4K_CODEC_DIR}")
else()
    set(RLE4K_CODEC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")
    message(STATUS "RLE4K codec: in-repo (canonical) ${RLE4K_CODEC_DIR}")
endif()

set(RLE4K_CODEC_SOURCES
    "${RLE4K_CODEC_DIR}/rle4k_encoder.cpp"
    "${RLE4K_CODEC_DIR}/rle4k_decoder.cpp"
)

add_executable(rle4k_v8
    src/main_cli_v8.cpp
    src/block_reader.cpp
    src/config_io.cpp
    src/verify_verdict.cpp
    ${RLE4K_CODEC_SOURCES}
)

target_include_directories(rle4k_v8 PRIVATE
    src
    "${NPCAP_SDK_DIR}/Include"
    "${RLE4K_CODEC_DIR}"
)

target_compile_definitions(rle4k_v8 PRIVATE NOMINMAX DISALBE_RLE4K_LIB)

if(WIN32)
    target_link_libraries(rle4k_v8 PRIVATE
        ws2_32
        iphlpapi
        "${NPCAP_SDK_DIR}/Lib/x64/wpcap.lib"
        "${NPCAP_SDK_DIR}/Lib/x64/Packet.lib"
    )
endif()

# --- diag_decode: standalone decode + CRC32 tool (no FPGA / no Npcap) ---
add_executable(diag_decode
    src/diag_decode.cpp
    src/block_reader.cpp
    ${RLE4K_CODEC_SOURCES}
)

target_include_directories(diag_decode PRIVATE
    src
    "${RLE4K_CODEC_DIR}"
)

target_compile_definitions(diag_decode PRIVATE NOMINMAX DISALBE_RLE4K_LIB)

# --- gen_sim_data: generate simulation stimulus + reference CRC ---
add_executable(gen_sim_data
    src/gen_sim_data.cpp
    src/block_reader.cpp
    ${RLE4K_CODEC_SOURCES}
)
target_include_directories(gen_sim_data PRIVATE src "${RLE4K_CODEC_DIR}")
target_compile_definitions(gen_sim_data PRIVATE NOMINMAX DISALBE_RLE4K_LIB)

# --- dump_decoded: dump decoded output for debug ---
add_executable(dump_decoded
    src/dump_decoded.cpp
    src/block_reader.cpp
    ${RLE4K_CODEC_SOURCES}
)
target_include_directories(dump_decoded PRIVATE src "${RLE4K_CODEC_DIR}")
target_compile_definitions(dump_decoded PRIVATE NOMINMAX DISALBE_RLE4K_LIB)

# --- pc_reference: offline PC reference decode + CRC32 (post-XOR caliber) ---
# Encoder round-trip self-check included; no Npcap, no board.
add_executable(pc_reference
    src/pc_reference.cpp
    src/block_reader.cpp
    ${RLE4K_CODEC_SOURCES}
)
target_include_directories(pc_reference PRIVATE src "${RLE4K_CODEC_DIR}")
target_compile_definitions(pc_reference PRIVATE NOMINMAX DISALBE_RLE4K_LIB)

# --- selftest_verdict: offline verdict-logic self-test (no Npcap, no board) ---
enable_testing()
add_executable(selftest_verdict
    src/selftest_verdict.cpp
    src/verify_verdict.cpp
)
target_include_directories(selftest_verdict PRIVATE src)
target_compile_definitions(selftest_verdict PRIVATE NOMINMAX DISALBE_RLE4K_LIB)
add_test(NAME selftest_verdict COMMAND selftest_verdict)
