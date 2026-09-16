set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(OPENTEXTURE_BUILD_ROOT "${CMAKE_SOURCE_DIR}/build/macos" CACHE PATH "macOS build intermediates")
set(OPENTEXTURE_DIST_PLATFORM_DIR "${CMAKE_SOURCE_DIR}/release/${OPENTEXTURE_RELEASE_FOLDER_MACOS}")
set(OPENTEXTURE_BIN_DIR "${OPENTEXTURE_BUILD_ROOT}/bin")
set(OPENTEXTURE_INFO_PLIST "${OPENTEXTURE_BUILD_ROOT}/Info.plist")
set(OPENTEXTURE_OFX_BUNDLE "${OPENTEXTURE_DIST_PLATFORM_DIR}/${OPENTEXTURE_OFX_BUNDLE_STEM}.ofx.bundle")

file(MAKE_DIRECTORY "${OPENTEXTURE_BUILD_ROOT}")
configure_file(
  "${CMAKE_SOURCE_DIR}/Info.plist.in"
  "${OPENTEXTURE_INFO_PLIST}"
  @ONLY
)
add_custom_target(opentexture_gen_plist DEPENDS "${OPENTEXTURE_INFO_PLIST}")

set(OPENTEXTURE_PLATFORM_SRCS
  "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureMetal.mm"
  "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureFreqEQBridge.mm"
  "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureGlareBridge.mm"
  "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTexturePresetDialogs.mm"
)
set(OPENTEXTURE_PLATFORM_EXTRA_SRCS "")
set(OPENTEXTURE_PLATFORM_INCLUDE_DIRS "${CMAKE_SOURCE_DIR}/plugin/metal")

set(OPENTEXTURE_COMPILE_OPTIONS
  -O2
  -Wno-dynamic-exception-spec
  -fvisibility=hidden
)
set(OPENTEXTURE_COMPILE_DEFINITIONS "")

find_program(XCRUN_EXECUTABLE xcrun REQUIRED)
set(METAL_COMMON "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureMetalCommon.metal")
set(METAL_MAIN_SRC "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureMetal.metal")
set(METAL_FREQ_SRC "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureFreqEQ.metal")
set(METAL_GLARE_SRC "${CMAKE_SOURCE_DIR}/plugin/metal/LSPOpenTextureGlare.metal")
set(METAL_MAIN_AIR "${OPENTEXTURE_BUILD_ROOT}/LSPOpenTextureMetal.air")
set(METAL_FREQ_AIR "${OPENTEXTURE_BUILD_ROOT}/LSPOpenTextureFreqEQ.air")
set(METAL_GLARE_AIR "${OPENTEXTURE_BUILD_ROOT}/LSPOpenTextureGlare.air")
set(METAL_LIB "${OPENTEXTURE_BUILD_ROOT}/LSPOpenTextureMetal.metallib")

add_custom_command(
  OUTPUT "${METAL_MAIN_AIR}"
  COMMAND "${XCRUN_EXECUTABLE}" -sdk macosx metal -c "${METAL_MAIN_SRC}" -o "${METAL_MAIN_AIR}" -I"${CMAKE_SOURCE_DIR}/plugin/metal"
  DEPENDS "${METAL_MAIN_SRC}" "${METAL_COMMON}"
  VERBATIM
)
add_custom_command(
  OUTPUT "${METAL_FREQ_AIR}"
  COMMAND "${XCRUN_EXECUTABLE}" -sdk macosx metal -c "${METAL_FREQ_SRC}" -o "${METAL_FREQ_AIR}" -I"${CMAKE_SOURCE_DIR}/plugin/metal"
  DEPENDS "${METAL_FREQ_SRC}" "${METAL_COMMON}"
  VERBATIM
)
add_custom_command(
  OUTPUT "${METAL_GLARE_AIR}"
  COMMAND "${XCRUN_EXECUTABLE}" -sdk macosx metal -c "${METAL_GLARE_SRC}" -o "${METAL_GLARE_AIR}" -I"${CMAKE_SOURCE_DIR}/plugin/metal"
  DEPENDS "${METAL_GLARE_SRC}" "${METAL_COMMON}"
  VERBATIM
)
add_custom_command(
  OUTPUT "${METAL_LIB}"
  COMMAND "${XCRUN_EXECUTABLE}" -sdk macosx metallib "${METAL_MAIN_AIR}" "${METAL_FREQ_AIR}" "${METAL_GLARE_AIR}" -o "${METAL_LIB}"
  DEPENDS "${METAL_MAIN_AIR}" "${METAL_FREQ_AIR}" "${METAL_GLARE_AIR}"
  VERBATIM
)
add_custom_target(OpenTextureMetalLib ALL DEPENDS "${METAL_LIB}")
set(OPENTEXTURE_EXTRA_TARGET_DEPS OpenTextureMetalLib opentexture_gen_plist)

find_library(OPENTEXTURE_FRAMEWORK_FOUNDATION NAMES Foundation REQUIRED)
find_library(OPENTEXTURE_FRAMEWORK_APPKIT NAMES AppKit REQUIRED)
find_library(OPENTEXTURE_FRAMEWORK_METAL NAMES Metal REQUIRED)
find_library(OPENTEXTURE_FRAMEWORK_MPS NAMES MetalPerformanceShaders REQUIRED)
set(OPENTEXTURE_LINK_LIBS
  ${OPENTEXTURE_FRAMEWORK_FOUNDATION}
  ${OPENTEXTURE_FRAMEWORK_APPKIT}
  ${OPENTEXTURE_FRAMEWORK_METAL}
  ${OPENTEXTURE_FRAMEWORK_MPS}
)
set(OPENTEXTURE_LINK_OPTIONS
  "-bundle"
  "-fvisibility=hidden"
  "-Wl,-rpath,@loader_path"
)

include("${CMAKE_CURRENT_LIST_DIR}/OpenTextureCommon.cmake")

add_dependencies(opentexture_ofx opentexture_gen_plist)

target_compile_options(opentexture_ofx PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fblocks>"
)

add_custom_command(TARGET opentexture_ofx POST_BUILD
  COMMAND strip -x "$<TARGET_FILE:opentexture_ofx>"
  COMMENT "strip -x opentexture_ofx"
)

opentexture_assemble_bundle_postbuild("MacOS")

add_custom_command(TARGET opentexture_ofx POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${METAL_LIB}" "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources/LSPOpenTextureMetal.metallib"
)

# Metallib-only rebuilds do not relink the .ofx — copy into the bundle from MetalLib too.
add_custom_command(TARGET OpenTextureMetalLib POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${METAL_LIB}" "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources/LSPOpenTextureMetal.metallib"
  COMMENT "Install metallib into OFX bundle"
)

message(STATUS "[OpenTexture] macOS bundle: ${OPENTEXTURE_OFX_BUNDLE}")
if(OPENTEXTURE_OFX_FAT_ARCHS)
  message(STATUS "[OpenTexture] macOS architectures: ${CMAKE_OSX_ARCHITECTURES}")
else()
  message(STATUS "[OpenTexture] macOS architectures: host default")
endif()
