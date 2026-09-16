# LSP - Open Texture OFX — unified CMake (macOS Metal + Windows CUDA)
cmake_minimum_required(VERSION 3.22)

option(OPENTEXTURE_OFX_FAT_ARCHS "Link universal Mach-O (arm64 + x86_64)" ON)

if(CMAKE_HOST_APPLE)
  set(OPENTEXTURE_MACOSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS deployment target")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "${OPENTEXTURE_MACOSX_DEPLOYMENT_TARGET}" CACHE STRING "" FORCE)
  if(OPENTEXTURE_OFX_FAT_ARCHS)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "macOS build architectures" FORCE)
  endif()
elseif(NOT CMAKE_HOST_WIN32)
  message(FATAL_ERROR "LSP Open Texture CMake supports macOS and Windows only.")
endif()

if(CMAKE_HOST_APPLE)
  project(LSP_Open_Texture
    VERSION 0.0.0
    DESCRIPTION "LSP - Open Texture OFX"
    LANGUAGES C CXX OBJCXX
  )
elseif(CMAKE_HOST_WIN32)
  project(LSP_Open_Texture
    VERSION 0.0.0
    DESCRIPTION "LSP - Open Texture OFX"
    LANGUAGES C CXX CUDA
  )
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/OpenTextureVersion.cmake")

if(APPLE)
  include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/OpenTextureApple.cmake")
elseif(WIN32)
  include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/OpenTextureWindows.cmake")
endif()

if(EXISTS "${CMAKE_SOURCE_DIR}/scripts/archive_version.sh")
  add_custom_target(opentexture_archive
    COMMAND bash "${CMAKE_SOURCE_DIR}/scripts/archive_version.sh"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    USES_TERMINAL
    COMMENT "Archive current version, rebuild"
  )
endif()
