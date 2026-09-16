set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(OPENTEXTURE_BUILD_ROOT "${CMAKE_SOURCE_DIR}/build/windows" CACHE PATH "Windows build intermediates")
set(OPENTEXTURE_DIST_PLATFORM_DIR "${CMAKE_SOURCE_DIR}/release/${OPENTEXTURE_RELEASE_FOLDER_WINDOWS}")
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

enable_language(CUDA)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES 75 86 89)
endif()
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -allow-unsupported-compiler")
find_package(CUDAToolkit REQUIRED)

set(OPENTEXTURE_PLATFORM_SRCS
  "${CMAKE_SOURCE_DIR}/plugin/windows/LSPOpenTexturePresetDialogs.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureCuda.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureFreqEQCuda.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureGlareCuda.cpp"
)
set(OPENTEXTURE_PLATFORM_EXTRA_SRCS
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureVanVliet.cu"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureKernels.cu"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureFreqEQKernels.cu"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureCudaBlur.cu"
  "${CMAKE_SOURCE_DIR}/plugin/cuda/LSPOpenTextureGlareKernels.cu"
)
set(OPENTEXTURE_PLATFORM_INCLUDE_DIRS
  "${CMAKE_SOURCE_DIR}/plugin/windows"
  "${CMAKE_SOURCE_DIR}/plugin/cuda"
)

set(OPENTEXTURE_COMPILE_OPTIONS $<$<COMPILE_LANGUAGE:CXX>:/W3 /bigobj /MP /EHsc>)
set(OPENTEXTURE_COMPILE_DEFINITIONS
  OFX_SUPPORTS_CUDARENDER
  WINDOWS
  _WINDOWS
  WIN32_LEAN_AND_MEAN
  NOMINMAX
  _CRT_SECURE_NO_WARNINGS
)
set(OPENTEXTURE_LINK_LIBS CUDA::cudart_static shell32 ole32 uuid comdlg32)
set(OPENTEXTURE_LINK_OPTIONS "")
set(OPENTEXTURE_EXTRA_TARGET_DEPS opentexture_gen_plist)

include("${CMAKE_CURRENT_LIST_DIR}/OpenTextureCommon.cmake")

target_include_directories(opentexture_ofx PRIVATE ${CUDAToolkit_INCLUDE_DIRS})
set_target_properties(opentexture_ofx PROPERTIES CUDA_SEPARABLE_COMPILATION ON)

opentexture_assemble_bundle_postbuild("Win64")

message(STATUS "[OpenTexture] Windows bundle: ${OPENTEXTURE_OFX_BUNDLE}")
