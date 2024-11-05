/*
 * Copyright (c) 2019-2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <tests/groupby/groupby_test_util.hpp>

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/debug_utilities.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/aggregation/aggregation.hpp>

#include <rmm/exec_policy.hpp>

#include <thrust/iterator/counting_iterator.h>
#include <thrust/transform.h>

using namespace cudf::test::iterators;

struct test : public cudf::test::BaseFixture {};

std::unique_ptr<cudf::column> double_sqr(cudf::column_view const& values,
                                         cudf::device_span<cudf::size_type const> group_offsets,
                                         cudf::device_span<cudf::size_type const> group_labels,
                                         cudf::size_type num_groups,
                                         rmm::cuda_stream_view stream,
                                         rmm::device_async_resource_ref mr)
{
  auto output = cudf::make_numeric_column(
    cudf::data_type{cudf::type_id::INT32}, values.size(), cudf::mask_state::UNALLOCATED, stream);
  thrust::transform(rmm::exec_policy(stream),
                    thrust::make_counting_iterator(0),
                    thrust::make_counting_iterator(values.size()),
                    output->mutable_view().begin<int>(),
                    [values = values.begin<int>()] __device__(int idx) -> int {
                      return 2 * values[idx] * values[idx];
                    });
  return output;
}

std::unique_ptr<cudf::column> triple_sqr(cudf::column_view const& values,
                                         cudf::device_span<cudf::size_type const> group_offsets,
                                         cudf::device_span<cudf::size_type const> group_labels,
                                         cudf::size_type num_groups,
                                         rmm::cuda_stream_view stream,
                                         rmm::device_async_resource_ref mr)
{
  auto output = cudf::make_numeric_column(
    cudf::data_type{cudf::type_id::INT32}, values.size(), cudf::mask_state::UNALLOCATED, stream);
  thrust::transform(rmm::exec_policy(stream),
                    thrust::make_counting_iterator(0),
                    thrust::make_counting_iterator(values.size()),
                    output->mutable_view().begin<int>(),
                    [values = values.begin<int>()] __device__(int idx) -> int {
                      return 3 * values[idx] * values[idx];
                    });
  return output;
}

TEST_F(test, double_sqr)
{
  cudf::test::fixed_width_column_wrapper<int> keys{1, 1, 1, 1, 1};
  cudf::test::fixed_width_column_wrapper<int> vals{0, 1, 2, 3, 4};

  auto agg = cudf::make_host_udf_aggregation<cudf::groupby_aggregation>(double_sqr);
  std::vector<cudf::groupby::aggregation_request> requests;
  requests.emplace_back();
  requests[0].values = vals;
  requests[0].aggregations.push_back(std::move(agg));
  cudf::groupby::groupby gb_obj(
    cudf::table_view({keys}), cudf::null_policy::INCLUDE, cudf::sorted::NO, {}, {});

  auto result = gb_obj.aggregate(requests, cudf::test::get_default_stream());

  // Got output: 0,2,8,18,32
  cudf::test::print(*result.second[0].results[0]);
}

TEST_F(test, triple_sqr)
{
  cudf::test::fixed_width_column_wrapper<int> keys{1, 1, 1, 1, 1};
  cudf::test::fixed_width_column_wrapper<int> vals{0, 1, 2, 3, 4};

  auto agg = cudf::make_host_udf_aggregation<cudf::groupby_aggregation>(triple_sqr);
  std::vector<cudf::groupby::aggregation_request> requests;
  requests.emplace_back();
  requests[0].values = vals;
  requests[0].aggregations.push_back(std::move(agg));
  cudf::groupby::groupby gb_obj(
    cudf::table_view({keys}), cudf::null_policy::INCLUDE, cudf::sorted::NO, {}, {});

  auto result = gb_obj.aggregate(requests, cudf::test::get_default_stream());

  // Got output: 0,3,12,27,48
  cudf::test::print(*result.second[0].results[0]);
}
