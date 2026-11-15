# Adds ewv's library to the Vulkan-Samples build without editing it.
# build.ps1 passes this file as CMAKE_PROJECT_INCLUDE, which CMake runs after
# every project() call; the target itself is defined once, deferred to the end
# of the top-level CMakeLists so the samples' targets already exist.
# (Same approach as appine's src/backends/vulkan/appine/appine.cmake.)
if(NOT EWV_VKS_HOOKED AND CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
    set(EWV_VKS_HOOKED ON)
    set(EWV_VKS_DIR "${CMAKE_CURRENT_LIST_DIR}")
    cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL ewv_vks_add_library)
endif()

function(ewv_vks_add_library)
    add_library(ewv_vulkan_samples SHARED "${EWV_VKS_DIR}/ewv_vulkan_samples.cpp")
    # app/ for "plugins/plugins.h": the plugins target keeps its own include
    # folder private, and the samples' app reaches it through app/.
    target_include_directories(ewv_vulkan_samples PRIVATE "${EWV_VKS_DIR}" "${CMAKE_SOURCE_DIR}/app")
    # Same libraries as the vulkan_samples executable (app/CMakeLists.txt).
    target_link_libraries(ewv_vulkan_samples PRIVATE vkb__core vkb__filesystem apps plugins framework)
    set_target_properties(ewv_vulkan_samples PROPERTIES
        PREFIX "" OUTPUT_NAME "ewv-vulkan-samples"
        # A DLL is a RUNTIME output on Windows; its .lib an ARCHIVE one.
        RUNTIME_OUTPUT_DIRECTORY "${EWV_VKS_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE "${EWV_VKS_OUTPUT_DIR}"
        ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/ewv-lib")
endfunction()
