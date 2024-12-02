# =============================================================================
# Copyright (c) 2024, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.
# =============================================================================

# This function finds nanoarrow and sets any additional necessary environment variables.
function(find_and_configure_nanoarrow)
  include(${rapids-cmake-dir}/cpm/package_override.cmake)

  # set(cudf_patch_dir "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/patches")
  # rapids_cpm_package_override("${cudf_patch_dir}/nanoarrow_override.json")

  if(NOT BUILD_SHARED_LIBS)
    set(_exclude_from_all EXCLUDE_FROM_ALL FALSE)
  else()
    set(_exclude_from_all EXCLUDE_FROM_ALL TRUE)
  endif()

  if(NOT CUDF_NANOARROW_DEBUG)
    set(_nanoarrow_debug OFF)
  else()
    set(_nanoarrow_debug ON)
  endif()

  # Currently we need to always build nanoarrow so we don't pickup a previous installed version
  set(CPM_DOWNLOAD_nanoarrow ON)
  rapids_cpm_find(
    nanoarrow 0.7.0.dev
    GLOBAL_TARGETS nanoarrow
    GIT_REPOSITORY https://github.com/apache/arrow-nanoarrow.git
    GIT_TAG e54b7df525fa1d310a96687bd99902823402b26c
    GIT_SHALLOW FALSE
    CPM_ARGS
    OPTIONS "BUILD_SHARED_LIBS OFF" "NANOARROW_NAMESPACE cudf" "NANOARROW_DEBUG ${_nanarrow_debug}"
            ${_exclude_from_all}
  )
  set_target_properties(nanoarrow PROPERTIES POSITION_INDEPENDENT_CODE ON)
  rapids_export_find_package_root(BUILD nanoarrow "${nanoarrow_BINARY_DIR}" EXPORT_SET cudf-exports)
endfunction()

find_and_configure_nanoarrow()
