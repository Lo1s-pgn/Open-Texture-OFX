# Shared opentexture_ofx target (included from OpenTextureApple.cmake / OpenTextureWindows.cmake).

set(OFX_SDK_PATH "${CMAKE_SOURCE_DIR}/openfx-sdk" CACHE PATH "Path to OFX SDK (include + Support)")

if(NOT EXISTS "${OFX_SDK_PATH}/include/ofxCore.h")
  message(FATAL_ERROR "OFX_SDK_PATH must contain include/ofxCore.h (got '${OFX_SDK_PATH}')")
endif()

set(OPENTEXTURE_PLUGIN_CORE_SRCS
  "${CMAKE_SOURCE_DIR}/plugin/core/LSPOpenTextureDescribe.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/core/LSPOpenTextureProcessor.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/core/LSPOpenTexturePlugin.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/core/LSPOpenTexturePresetMenus.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/core/LSPOpenTextureTfMapping.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/core/LSPOpenTextureGamut.cpp"
  "${CMAKE_SOURCE_DIR}/plugin/presets/LSPOpenTexturePresetHelpers.cpp"
)

set(OPENTEXTURE_OFX_SUPPORT_SRCS
  "${OFX_SDK_PATH}/Support/Library/ofxsCore.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsImageEffect.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsInteract.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsLog.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsMultiThread.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsParams.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsProperty.cpp"
  "${OFX_SDK_PATH}/Support/Library/ofxsPropertyValidation.cpp"
)

set(OPENTEXTURE_INCLUDE_DIRS
  "${CMAKE_SOURCE_DIR}/plugin"
  "${CMAKE_SOURCE_DIR}/plugin/core"
  "${CMAKE_SOURCE_DIR}/plugin/presets"
  "${OFX_SDK_PATH}/include"
  "${OFX_SDK_PATH}/Support/include"
  "${OFX_SDK_PATH}/Support/Library"
)

file(MAKE_DIRECTORY "${OPENTEXTURE_BIN_DIR}")

add_library(opentexture_ofx MODULE
  ${OPENTEXTURE_PLUGIN_CORE_SRCS}
  ${OPENTEXTURE_OFX_SUPPORT_SRCS}
  ${OPENTEXTURE_PLATFORM_SRCS}
  ${OPENTEXTURE_PLATFORM_EXTRA_SRCS}
)

target_include_directories(opentexture_ofx PRIVATE
  ${OPENTEXTURE_INCLUDE_DIRS}
  ${OPENTEXTURE_PLATFORM_INCLUDE_DIRS}
)
target_compile_features(opentexture_ofx PRIVATE cxx_std_20)
target_compile_options(opentexture_ofx PRIVATE ${OPENTEXTURE_COMPILE_OPTIONS})
target_compile_definitions(opentexture_ofx PRIVATE ${OPENTEXTURE_COMPILE_DEFINITIONS})
if(OPENTEXTURE_LINK_LIBS)
  target_link_libraries(opentexture_ofx PRIVATE ${OPENTEXTURE_LINK_LIBS})
endif()
target_link_options(opentexture_ofx PRIVATE ${OPENTEXTURE_LINK_OPTIONS})

set_target_properties(opentexture_ofx PROPERTIES
  PREFIX ""
  SUFFIX ".ofx"
  OUTPUT_NAME "${OPENTEXTURE_OFX_BUNDLE_STEM}"
  LIBRARY_OUTPUT_DIRECTORY "${OPENTEXTURE_BIN_DIR}"
)

if(OPENTEXTURE_EXTRA_TARGET_DEPS)
  add_dependencies(opentexture_ofx opentexture_gen_version ${OPENTEXTURE_EXTRA_TARGET_DEPS})
else()
  add_dependencies(opentexture_ofx opentexture_gen_version)
endif()

if(EXISTS "${CMAKE_SOURCE_DIR}/ICON.png")
  set(OPENTEXTURE_HAS_ICON TRUE)
else()
  set(OPENTEXTURE_HAS_ICON FALSE)
endif()

function(opentexture_assemble_bundle_postbuild p_PlatformSubdir)
  set(_bundle_ofx "${OPENTEXTURE_OFX_BUNDLE}/Contents/${p_PlatformSubdir}/${OPENTEXTURE_OFX_EXECUTABLE_NAME}")
  add_custom_command(TARGET opentexture_ofx POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${OPENTEXTURE_DIST_PLATFORM_DIR}"
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${OPENTEXTURE_OFX_BUNDLE}/Contents"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${OPENTEXTURE_OFX_BUNDLE}/Contents/${p_PlatformSubdir}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${OPENTEXTURE_INFO_PLIST}" "${OPENTEXTURE_OFX_BUNDLE}/Contents/Info.plist"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:opentexture_ofx>" "${_bundle_ofx}"
    COMMENT "Assemble ${OPENTEXTURE_OFX_BUNDLE_STEM}.ofx.bundle (${p_PlatformSubdir})"
  )
  if(OPENTEXTURE_HAS_ICON)
    add_custom_command(TARGET opentexture_ofx POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              "${CMAKE_SOURCE_DIR}/ICON.png"
              "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources/${OPENTEXTURE_PLUGIN_ICON_NAME}"
    )
  endif()
  if(EXISTS "${CMAKE_SOURCE_DIR}/Presets")
    add_custom_command(TARGET opentexture_ofx POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources/Presets"
      COMMAND ${CMAKE_COMMAND} -E copy_directory
              "${CMAKE_SOURCE_DIR}/Presets"
              "${OPENTEXTURE_OFX_BUNDLE}/Contents/Resources/Presets"
    )
  endif()
endfunction()

add_custom_target(opentexture_all DEPENDS opentexture_ofx)
