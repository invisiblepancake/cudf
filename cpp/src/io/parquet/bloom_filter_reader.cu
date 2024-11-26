/*
 * Copyright (c) 2024, NVIDIA CORPORATION.
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

#include "arrow_filter_policy.cuh"
#include "compact_protocol_reader.hpp"
#include "io/parquet/parquet.hpp"
#include "reader_impl_helpers.hpp"

#include <cudf/ast/detail/expression_transformer.hpp>
#include <cudf/ast/detail/operators.hpp>
#include <cudf/ast/expressions.hpp>
#include <cudf/detail/cuco_helpers.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/transform.hpp>
#include <cudf/detail/utilities/logger.hpp>
#include <cudf/hashing/detail/xxhash_64.cuh>
#include <cudf/utilities/span.hpp>
#include <cudf/utilities/traits.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/device_vector.hpp>
#include <rmm/exec_policy.hpp>

#include <cuco/bloom_filter_ref.cuh>
#include <thrust/iterator/counting_iterator.h>

#include <future>
#include <numeric>
#include <optional>

namespace cudf::io::parquet::detail {
namespace {

/**
 * @brief Converts bloom filter membership results for column chunks to a device column.
 *
 */
struct bloom_filter_caster {
  cudf::device_span<void* const> buffer_ptrs;
  cudf::device_span<size_t const> buffer_sizes;
  size_t num_row_groups;
  size_t num_equality_columns;

  // Creates device columns from bloom filter membership
  template <typename T>
  std::unique_ptr<cudf::column> operator()(cudf::size_type equality_col_idx,
                                           cudf::data_type dtype,
                                           ast::literal* const& literal,
                                           rmm::cuda_stream_view stream,
                                           rmm::device_async_resource_ref mr) const
  {
    // List, Struct, Dictionary types are not supported
    if constexpr (cudf::is_compound<T>() and not std::is_same_v<T, string_view>) {
      CUDF_FAIL("Compound types don't support equality predicate");
    } else {
      using key_type    = T;
      using hasher_type = cudf::hashing::detail::XXHash_64<key_type>;
      using policy_type = cuco::arrow_filter_policy<key_type, hasher_type>;
      using word_type   = typename policy_type::word_type;

      // Check if the literal has the same type as the column
      CUDF_EXPECTS(dtype.id() == literal->get_data_type().id(), "Mismatched data_types");

      // Filter properties
      auto constexpr word_size       = sizeof(word_type);
      auto constexpr words_per_block = policy_type::words_per_block;

      rmm::device_buffer results{num_row_groups, stream, mr};

      // Query literal in bloom filters.
      thrust::for_each(
        rmm::exec_policy_nosync(stream),
        thrust::make_counting_iterator<size_t>(0),
        thrust::make_counting_iterator(num_row_groups),
        [buffer_ptrs          = buffer_ptrs.data(),
         buffer_sizes         = buffer_sizes.data(),
         d_scalar             = literal->get_value(),
         col_idx              = equality_col_idx,
         num_equality_columns = num_equality_columns,
         results = reinterpret_cast<bool*>(results.data())] __device__(auto row_group_idx) {
          // Filter bitset buffer index
          auto const filter_idx        = col_idx + (num_equality_columns * row_group_idx);
          auto const num_filter_blocks = buffer_sizes[filter_idx] / (word_size * words_per_block);

          // Create a bloom filter view.
          cuco::bloom_filter_ref<key_type,
                                 cuco::extent<std::size_t>,
                                 cuco::thread_scope_thread,
                                 policy_type>
            filter{reinterpret_cast<word_type*>(buffer_ptrs[filter_idx]),
                   num_filter_blocks,
                   {},   // thread scope since the same literal is being search across different
                         // bitsets per thread
                   {}};  // Arrow policy with default xxhash_64, seed = 0 for Arrow compatibility

          // Query the bloom filter and store results
          results[row_group_idx] = filter.contains(d_scalar.value<T>());
        });

      return std::make_unique<cudf::column>(cudf::data_type{cudf::type_id::BOOL8},
                                            static_cast<cudf::size_type>(num_row_groups),
                                            std::move(results),
                                            rmm::device_buffer{},
                                            0);
    }
  }
};

/**
 * @brief Collects lists of equality predicate literals in the AST expression, one list per input
 * table column. This is used in row group filtering based on bloom filters.
 */
class equality_literals_collector : public ast::detail::expression_transformer {
 public:
  equality_literals_collector() = default;

  equality_literals_collector(ast::expression const& expr, cudf::size_type num_input_columns)
    : _num_input_columns{num_input_columns}
  {
    _equality_literals.resize(_num_input_columns);
    expr.accept(*this);
  }

  /**
   * @copydoc ast::detail::expression_transformer::visit(ast::literal const& )
   */
  std::reference_wrapper<ast::expression const> visit(ast::literal const& expr) override
  {
    _bloom_filter_expr = std::reference_wrapper<ast::expression const>(expr);
    return expr;
  }

  /**
   * @copydoc ast::detail::expression_transformer::visit(ast::column_reference const& )
   */
  std::reference_wrapper<ast::expression const> visit(ast::column_reference const& expr) override
  {
    CUDF_EXPECTS(expr.get_table_source() == ast::table_reference::LEFT,
                 "BloomfilterAST supports only left table");
    CUDF_EXPECTS(expr.get_column_index() < _num_input_columns,
                 "Column index cannot be more than number of columns in the table");
    _bloom_filter_expr = std::reference_wrapper<ast::expression const>(expr);
    return expr;
  }

  /**
   * @copydoc ast::detail::expression_transformer::visit(ast::column_name_reference const& )
   */
  std::reference_wrapper<ast::expression const> visit(
    ast::column_name_reference const& expr) override
  {
    CUDF_FAIL("Column name reference is not supported in BloomfilterAST");
  }

  /**
   * @copydoc ast::detail::expression_transformer::visit(ast::operation const& )
   */
  std::reference_wrapper<ast::expression const> visit(ast::operation const& expr) override
  {
    using cudf::ast::ast_operator;
    auto const operands = expr.get_operands();
    auto const op       = expr.get_operator();

    if (auto* v = dynamic_cast<ast::column_reference const*>(&operands[0].get())) {
      // First operand should be column reference, second should be literal.
      CUDF_EXPECTS(cudf::ast::detail::ast_operator_arity(op) == 2,
                   "Only binary operations are supported on column reference");
      CUDF_EXPECTS(dynamic_cast<ast::literal const*>(&operands[1].get()) != nullptr,
                   "Second operand of binary operation with column reference must be a literal");
      v->accept(*this);

      // Push to the corresponding column's literals list iff equality predicate is seen
      if (op == ast_operator::EQUAL) {
        auto const col_idx = v->get_column_index();
        _equality_literals[col_idx].emplace_back(
          const_cast<ast::literal*>(dynamic_cast<ast::literal const*>(&operands[1].get())));
      }
    } else {
      auto new_operands = visit_operands(operands);
      if (cudf::ast::detail::ast_operator_arity(op) == 2) {
        _operators.emplace_back(op, new_operands.front(), new_operands.back());
      } else if (cudf::ast::detail::ast_operator_arity(op) == 1) {
        _operators.emplace_back(op, new_operands.front());
      }
    }
    _bloom_filter_expr = std::reference_wrapper<ast::expression const>(_operators.back());
    return std::reference_wrapper<ast::expression const>(_operators.back());
  }

  /**
   * @brief Vectors of equality literals in the AST expression, one per input table column
   *
   * @return Vectors of equality literals, one per input table column
   */
  [[nodiscard]] std::vector<std::vector<ast::literal*>> const get_equality_literals() const
  {
    return _equality_literals;
  }

 protected:
  std::vector<std::reference_wrapper<ast::expression const>> visit_operands(
    cudf::host_span<std::reference_wrapper<ast::expression const> const> operands)
  {
    std::vector<std::reference_wrapper<ast::expression const>> transformed_operands;
    for (auto const& operand : operands) {
      auto const new_operand = operand.get().accept(*this);
      transformed_operands.push_back(new_operand);
    }
    return transformed_operands;
  }
  std::optional<std::reference_wrapper<ast::expression const>> _bloom_filter_expr;
  std::vector<std::vector<ast::literal*>> _equality_literals;
  std::list<ast::column_reference> _col_ref;
  std::list<ast::operation> _operators;
  size_type _num_input_columns;
};

/**
 * @brief Converts AST expression to bloom filter membership (BloomfilterAST) expression .
 * This is used in row group filtering based on equality predicate.
 */
class bloom_filter_expression_converter : public equality_literals_collector {
 public:
  bloom_filter_expression_converter(
    ast::expression const& expr,
    size_type num_input_columns,
    std::vector<std::vector<ast::literal*>> const& equality_literals)
  {
    // Set the num columns and equality literals
    _num_input_columns = num_input_columns;
    _equality_literals = std::move(equality_literals);

    // Compute and store columns literals offsets
    _col_literals_offsets.reserve(_num_input_columns + 1);
    _col_literals_offsets.emplace_back(0);

    std::transform(equality_literals.begin(),
                   equality_literals.end(),
                   std::back_inserter(_col_literals_offsets),
                   [&](auto const& col_literal_map) {
                     return _col_literals_offsets.back() +
                            static_cast<cudf::size_type>(col_literal_map.size());
                   });

    // Add this visitor
    expr.accept(*this);
  }

  /**
   * @brief Delete equality literals getter as no longer needed
   */
  [[nodiscard]] std::vector<std::vector<ast::literal*>> get_equality_literals() = delete;

  // Bring all overloads of `visit` from equality_predicate_collector into scope
  using equality_literals_collector::visit;

  /**
   * @copydoc ast::detail::expression_transformer::visit(ast::operation const& )
   */
  std::reference_wrapper<ast::expression const> visit(ast::operation const& expr) override
  {
    using cudf::ast::ast_operator;
    auto const operands = expr.get_operands();
    auto const op       = expr.get_operator();

    if (auto* v = dynamic_cast<ast::column_reference const*>(&operands[0].get())) {
      // First operand should be column reference, second should be literal.
      CUDF_EXPECTS(cudf::ast::detail::ast_operator_arity(op) == 2,
                   "Only binary operations are supported on column reference");
      CUDF_EXPECTS(dynamic_cast<ast::literal const*>(&operands[1].get()) != nullptr,
                   "Second operand of binary operation with column reference must be a literal");
      v->accept(*this);

      if (op == ast_operator::EQUAL) {
        // Search the literal in this input column's equality literals list and add to the offset.
        auto const col_idx            = v->get_column_index();
        auto const& equality_literals = _equality_literals[col_idx];
        auto col_literal_offset       = _col_literals_offsets[col_idx];
        auto const literal_iter       = std::find(equality_literals.cbegin(),
                                            equality_literals.cend(),
                                            dynamic_cast<ast::literal const*>(&operands[1].get()));
        CUDF_EXPECTS(literal_iter != equality_literals.end(), "Could not find the literal ptr");
        col_literal_offset += std::distance(equality_literals.cbegin(), literal_iter);

        // Evaluate boolean is_true(value) expression as NOT(NOT(value))
        auto const& value = _col_ref.emplace_back(col_literal_offset);
        auto const& op    = _operators.emplace_back(ast_operator::NOT, value);
        _operators.emplace_back(ast_operator::NOT, op);
      }
    } else {
      auto new_operands = visit_operands(operands);
      if (cudf::ast::detail::ast_operator_arity(op) == 2) {
        _operators.emplace_back(op, new_operands.front(), new_operands.back());
      } else if (cudf::ast::detail::ast_operator_arity(op) == 1) {
        _operators.emplace_back(op, new_operands.front());
      }
    }
    _bloom_filter_expr = std::reference_wrapper<ast::expression const>(_operators.back());
    return std::reference_wrapper<ast::expression const>(_operators.back());
  }

  /**
   * @brief Returns the AST to apply on bloom filters mmebership.
   *
   * @return AST operation expression
   */
  [[nodiscard]] std::reference_wrapper<ast::expression const> get_bloom_filter_expr() const
  {
    return _bloom_filter_expr.value().get();
  }

 private:
  std::vector<cudf::size_type> _col_literals_offsets;
};

/**
 * @brief Asynchronously reads bloom filters data to device.
 *
 * @param sources Dataset sources
 * @param num_chunks Number of total column chunks to read
 * @param bloom_filter_data Devicebuffers to hold bloom filter bitsets for each chunk
 * @param bloom_filter_offsets Bloom filter offsets for all chunks
 * @param bloom_filter_sizes Bloom filter sizes for all chunks
 * @param chunk_source_map Association between each column chunk and its source
 * @param stream CUDA stream used for device memory operations and kernel launches
 *
 * @return A future object for reading synchronization
 */
std::future<void> read_bloom_filter_data_async(
  host_span<std::unique_ptr<datasource> const> sources,
  size_t num_chunks,
  cudf::host_span<rmm::device_buffer> bloom_filter_data,
  cudf::host_span<std::optional<int64_t>> bloom_filter_offsets,
  cudf::host_span<std::optional<int32_t>> bloom_filter_sizes,
  std::vector<size_type> const& chunk_source_map,
  rmm::cuda_stream_view stream)
{
  // Read tasks for bloom filter data
  std::vector<std::future<size_t>> read_tasks;

  // Read bloom filters for all column chunks
  std::for_each(
    thrust::make_counting_iterator<size_t>(0),
    thrust::make_counting_iterator<size_t>(num_chunks),
    [&](auto const chunk) {
      // Skip if bloom filter offset absent
      if (not bloom_filter_offsets[chunk].has_value()) { return; }

      // Read bloom filter iff present
      auto const bloom_filter_offset = bloom_filter_offsets[chunk].value();

      // If Bloom filter size (header + bitset) is available, just read the entire thing.
      // Else just read 256 bytes which will contain the entire header and may contain the
      // entire bitset as well.
      auto constexpr bloom_filter_size_guess = 256;
      auto const initial_read_size =
        static_cast<size_t>(bloom_filter_sizes[chunk].value_or(bloom_filter_size_guess));

      // Read an initial buffer from source
      auto& source = sources[chunk_source_map[chunk]];
      auto buffer  = source->host_read(bloom_filter_offset, initial_read_size);

      // Deserialize the Bloom filter header from the buffer.
      BloomFilterHeader header;
      CompactProtocolReader cp{buffer->data(), buffer->size()};
      cp.read(&header);

      // Check if the bloom filter header is valid.
      auto const is_header_valid =
        (header.num_bytes % 32) == 0 and
        header.compression.compression == BloomFilterCompression::Compression::UNCOMPRESSED and
        header.algorithm.algorithm == BloomFilterAlgorithm::Algorithm::SPLIT_BLOCK and
        header.hash.hash == BloomFilterHash::Hash::XXHASH;

      // Do not read if the bloom filter is invalid
      if (not is_header_valid) {
        CUDF_LOG_WARN("Encountered an invalid bloom filter header. Skipping");
        return;
      }

      // Bloom filter header size
      auto const bloom_filter_header_size = static_cast<int64_t>(cp.bytecount());
      size_t const bitset_size            = static_cast<size_t>(header.num_bytes);

      // Check if we already read in the filter bitset in the initial read.
      if (initial_read_size >= bloom_filter_header_size + bitset_size) {
        bloom_filter_data[chunk] =
          rmm::device_buffer{buffer->data() + bloom_filter_header_size, bitset_size, stream};
      }
      // Read the bitset from datasource.
      else {
        auto const bitset_offset = bloom_filter_offset + bloom_filter_header_size;
        // Directly read to device if preferred
        if (source->is_device_read_preferred(bitset_size)) {
          bloom_filter_data[chunk] = rmm::device_buffer{bitset_size, stream};
          auto future_read_size =
            source->device_read_async(bitset_offset,
                                      bitset_size,
                                      static_cast<uint8_t*>(bloom_filter_data[chunk].data()),
                                      stream);

          read_tasks.emplace_back(std::move(future_read_size));
        } else {
          buffer                   = source->host_read(bitset_offset, bitset_size);
          bloom_filter_data[chunk] = rmm::device_buffer{buffer->data(), buffer->size(), stream};
        }
      }
    });

  // Read task sync function
  auto sync_fn = [](decltype(read_tasks) read_tasks) {
    for (auto& task : read_tasks) {
      task.wait();
    }
  };

  return std::async(std::launch::deferred, sync_fn, std::move(read_tasks));
}

}  // namespace

std::vector<rmm::device_buffer> aggregate_reader_metadata::read_bloom_filters(
  host_span<std::unique_ptr<datasource> const> sources,
  host_span<std::vector<size_type> const> row_group_indices,
  host_span<int const> column_schemas,
  size_type num_row_groups,
  rmm::cuda_stream_view stream) const
{
  // Descriptors for all the chunks that make up the selected columns
  auto const num_input_columns = column_schemas.size();
  auto const num_chunks        = num_row_groups * num_input_columns;

  // Association between each column chunk and its source
  std::vector<size_type> chunk_source_map(num_chunks);

  // Keep track of column chunk file offsets
  std::vector<std::optional<int64_t>> bloom_filter_offsets(num_chunks);
  std::vector<std::optional<int32_t>> bloom_filter_sizes(num_chunks);

  // Gather all bloom filter offsets and sizes.
  size_type chunk_count = 0;

  // For all data sources
  std::for_each(thrust::make_counting_iterator<size_t>(0),
                thrust::make_counting_iterator(row_group_indices.size()),
                [&](auto const src_index) {
                  // Get all row group indices in the data source
                  auto const& rg_indices = row_group_indices[src_index];
                  // For all row groups
                  std::for_each(rg_indices.cbegin(), rg_indices.cend(), [&](auto const rg_index) {
                    // For all column chunks
                    std::for_each(
                      column_schemas.begin(), column_schemas.end(), [&](auto const schema_idx) {
                        auto& col_meta = get_column_metadata(rg_index, src_index, schema_idx);

                        // Get bloom filter offsets and sizes
                        bloom_filter_offsets[chunk_count] = col_meta.bloom_filter_offset;
                        bloom_filter_sizes[chunk_count]   = col_meta.bloom_filter_length;

                        // Map each column chunk to its source index
                        chunk_source_map[chunk_count] = src_index;
                        chunk_count++;
                      });
                  });
                });

  // Do we have any bloom filters
  if (std::any_of(bloom_filter_offsets.cbegin(),
                  bloom_filter_offsets.cend(),
                  [](auto const offset) { return offset.has_value(); })) {
    // Vector to hold bloom filter data
    std::vector<rmm::device_buffer> bloom_filter_data(num_chunks);

    // Wait on bloom filter data read tasks
    read_bloom_filter_data_async(sources,
                                 num_chunks,
                                 bloom_filter_data,
                                 bloom_filter_offsets,
                                 bloom_filter_sizes,
                                 chunk_source_map,
                                 stream)
      .wait();

    // Return bloom filter data
    return bloom_filter_data;
  }

  // Return empty vector
  return {};
}

std::optional<std::vector<std::vector<size_type>>> aggregate_reader_metadata::apply_bloom_filters(
  host_span<std::unique_ptr<datasource> const> sources,
  host_span<std::vector<size_type> const> row_group_indices,
  host_span<data_type const> output_dtypes,
  host_span<int const> output_column_schemas,
  std::reference_wrapper<ast::expression const> filter,
  rmm::cuda_stream_view stream) const
{
  // Number of input table columns
  auto const num_input_columns = static_cast<cudf::size_type>(output_dtypes.size());

  auto mr = cudf::get_current_device_resource_ref();

  // Total number of row groups to process.
  auto const num_row_groups = std::accumulate(
    row_group_indices.begin(),
    row_group_indices.end(),
    size_t{0},
    [](size_t sum, auto const& per_file_row_groups) { return sum + per_file_row_groups.size(); });

  // Collect equality literals for each input table column
  auto const equality_literals =
    equality_literals_collector{filter.get(), num_input_columns}.get_equality_literals();

  // Collect schema indices of columns with equality predicate(s)
  std::vector<cudf::size_type> equality_col_schemas;
  std::for_each(thrust::make_counting_iterator<size_t>(0),
                thrust::make_counting_iterator(output_column_schemas.size()),
                [&](auto col_idx) {
                  // Only for columns that have a non-empty list of literals associated with it
                  if (equality_literals[col_idx].size()) {
                    equality_col_schemas.emplace_back(output_column_schemas[col_idx]);
                  }
                });

  // Return early if no column with equality predicate(s)
  if (equality_col_schemas.empty()) { return std::nullopt; }

  // Read a vector of bloom filter bitset device buffers for all column with equality predicate(s)
  // across all row groups
  auto bloom_filter_data =
    read_bloom_filters(sources, row_group_indices, equality_col_schemas, num_row_groups, stream);

  // No bloom filter buffers, return the original row group indices
  if (bloom_filter_data.empty()) { return std::nullopt; }

  // Copy bloom filter bitset buffer pointers and sizes to device
  std::vector<void*> h_buffer_ptrs(bloom_filter_data.size());
  std::vector<size_t> h_buffer_sizes(bloom_filter_data.size());
  std::for_each(thrust::make_counting_iterator<size_t>(0),
                thrust::make_counting_iterator<size_t>(bloom_filter_data.size()),
                [&](auto i) {
                  auto const& buffer = bloom_filter_data[i];
                  // Bitset ptr must be non-const to be used in cuco::bloom_filter.
                  h_buffer_ptrs[i]  = const_cast<void*>(buffer.data());
                  h_buffer_sizes[i] = buffer.size();
                });
  auto buffer_ptrs  = cudf::detail::make_device_uvector_async(h_buffer_ptrs, stream, mr);
  auto buffer_sizes = cudf::detail::make_device_uvector_async(h_buffer_sizes, stream, mr);

  // Create a bloom filter query table caster.
  bloom_filter_caster bloom_filter_col{
    buffer_ptrs, buffer_sizes, num_row_groups, equality_col_schemas.size()};

  // Converts bloom filter membership for equality predicate columns to a table
  // containing a column for each `col[i] == literal` predicate to be evaluated.
  // The table contains #sources * #column_chunks_per_src rows.
  std::vector<std::unique_ptr<column>> columns;
  size_t equality_col_idx = 0;
  std::for_each(thrust::make_counting_iterator<size_t>(0),
                thrust::make_counting_iterator(output_dtypes.size()),
                [&](auto input_col_idx) {
                  auto const& dtype = output_dtypes[input_col_idx];

                  // Skip if no equality literals for this column
                  if (equality_literals[input_col_idx].empty()) { return; }

                  // Skip if non-comparable (compound) type except string
                  if (cudf::is_compound(dtype) and dtype.id() != cudf::type_id::STRING) { return; }

                  // Add a column for all literals associated with an equality column
                  for (ast::literal* const& literal : equality_literals[input_col_idx]) {
                    columns.emplace_back(cudf::type_dispatcher<dispatch_storage_type>(
                      dtype, bloom_filter_col, equality_col_idx, dtype, literal, stream, mr));
                  }
                  equality_col_idx++;
                });
  auto bloom_filter_membership_table = cudf::table(std::move(columns));

  // Convert AST to BloomfilterAST expression with reference to bloom filter membership
  // in above `bloom_filter_membership_table`
  bloom_filter_expression_converter bloom_filter_expr{
    filter.get(), num_input_columns, equality_literals};

  // Filter bloom filter membership table with the BloomfilterAST expression and collect filtered
  // row group indices
  return collect_filtered_row_group_indices(bloom_filter_membership_table,
                                            bloom_filter_expr.get_bloom_filter_expr(),
                                            row_group_indices,
                                            stream,
                                            mr);
}

}  // namespace cudf::io::parquet::detail
