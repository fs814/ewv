# winine_native.dll: the C++ implementation of ewv's native module.
# Built by Settings/winbuild/editor/emacsplugin/ewv/build_ewv.ps1 (after
# ewv's cargo build), which passes:
#   WEBVIEW2_DIR        the Microsoft.Web.WebView2 NuGet package's build/native
#   EMACS_INCLUDE_DIR   the folder holding emacs-module.h
#   WININE_OUTPUT_DIR   where the DLL goes (default: this folder, which
#                       winine-core.el loads it from)
cmake_minimum_required(VERSION 3.20)
project(winine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Static CRT: the DLL loads into Emacs without a VC++ redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(WEBVIEW2_DIR "" CACHE PATH "Microsoft.Web.WebView2 package: its build/native folder")
set(EMACS_INCLUDE_DIR "C:/emacsrelease/include" CACHE PATH "Folder with emacs-module.h")
set(WININE_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}" CACHE PATH "Where winine_native.dll goes")

if(NOT EXISTS "${WEBVIEW2_DIR}/include/WebView2.h")
    message(FATAL_ERROR "WebView2.h not found under WEBVIEW2_DIR=${WEBVIEW2_DIR}/include")
endif()
if(NOT EXISTS "${EMACS_INCLUDE_DIR}/emacs-module.h")
    message(FATAL_ERROR "emacs-module.h not found under EMACS_INCLUDE_DIR=${EMACS_INCLUDE_DIR}")
endif()

# --- shaders: compiled now and embedded, as ewv's build.rs does -------------
# fxc for the triangle (shader model 5) and dxc for the DXR library (lib_6_3,
# which only dxc builds; next to dxil.dll in the Windows SDK it also signs the
# output, which D3D12 requires). vcvars puts the SDK's bin folder on PATH.
set(_sdk_bin "$ENV{WindowsSdkVerBinPath}x64")
find_program(FXC fxc HINTS "${_sdk_bin}" REQUIRED)
find_program(DXC dxc HINTS "${_sdk_bin}" REQUIRED)

set(_gen "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(_dx12 "${CMAKE_CURRENT_SOURCE_DIR}/src/dx12")
file(MAKE_DIRECTORY "${_gen}")
add_custom_command(
    OUTPUT "${_gen}/triangle_vs.h"
    COMMAND "${FXC}" /nologo /T vs_5_0 /E VSMain /Vn g_triangle_vs /Fh "${_gen}/triangle_vs.h" "${_dx12}/triangle.hlsl"
    DEPENDS "${_dx12}/triangle.hlsl" VERBATIM)
add_custom_command(
    OUTPUT "${_gen}/triangle_ps.h"
    COMMAND "${FXC}" /nologo /T ps_5_0 /E PSMain /Vn g_triangle_ps /Fh "${_gen}/triangle_ps.h" "${_dx12}/triangle.hlsl"
    DEPENDS "${_dx12}/triangle.hlsl" VERBATIM)
add_custom_command(
    OUTPUT "${_gen}/raytracing_shaders.h"
    COMMAND "${DXC}" -nologo -T lib_6_3 -Vn g_raytracing_shaders -Fh "${_gen}/raytracing_shaders.h" "${_dx12}/raytracing.hlsl"
    DEPENDS "${_dx12}/raytracing.hlsl" VERBATIM)

add_library(winine_native SHARED
    src/common.cpp
    src/lisp.cpp
    src/webview.cpp
    src/view.cpp
    src/dx12/dx12.cpp
    src/dx12/triangle.cpp
    src/dx12/raytracing.cpp
    src/vks.cpp
    src/dxs.cpp
    src/module.cpp
    "${_gen}/triangle_vs.h"
    "${_gen}/triangle_ps.h"
    "${_gen}/raytracing_shaders.h")

target_include_directories(winine_native PRIVATE
    "${WEBVIEW2_DIR}/include" "${EMACS_INCLUDE_DIR}" "${_gen}")
target_compile_definitions(winine_native PRIVATE
    UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00 WINVER=0x0A00)
target_compile_options(winine_native PRIVATE /W4 /permissive- /utf-8 /EHsc /wd4100)
target_link_libraries(winine_native PRIVATE
    "${WEBVIEW2_DIR}/x64/WebView2LoaderStatic.lib"
    d3d12 dxgi user32 ole32 oleaut32 advapi32 shlwapi version)
set_target_properties(winine_native PROPERTIES
    OUTPUT_NAME "winine_native"
    RUNTIME_OUTPUT_DIRECTORY "${WININE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${WININE_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${WININE_OUTPUT_DIR}"
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/lib")
