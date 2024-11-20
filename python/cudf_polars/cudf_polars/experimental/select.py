# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
"""Parallel Select Logic."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from cudf_polars.dsl.ir import Select
from cudf_polars.experimental.parallel import (
    _ir_parts_info,
    _partitionwise_ir_parts_info,
    _partitionwise_ir_tasks,
    generate_ir_tasks,
)

if TYPE_CHECKING:
    from collections.abc import MutableMapping

    from cudf_polars.dsl.ir import IR
    from cudf_polars.experimental.parallel import PartitionInfo


_PARTWISE = (
    "Literal",
    "LiteralColumn",
    "Col",
    "ColRef",
    "BooleanFunction",
    "StringFunction",
    "TemporalFunction",
    "Filter",
    "Cast",
    "Ternary",
    "BinOp",
    "UnaryFunction",
)


class PartwiseSelect(Select):
    """Partitionwise Select operation."""


def lower_select_node(ir: Select, rec) -> IR:
    """Rewrite a GroupBy node with proper partitioning."""
    from cudf_polars.dsl.traversal import traversal

    # Lower children first
    children = [rec(child) for child in ir.children]

    # Search the expressions for "complex" operations
    for ne in ir.exprs:
        for expr in traversal(ne.value):
            if type(expr).__name__ not in _PARTWISE:
                return ir.reconstruct(children)

    # Remailing Select ops are partition-wise
    return PartwiseSelect(
        ir.schema,
        ir.exprs,
        ir.should_broadcast,
        *children,
    )


@_ir_parts_info.register(PartwiseSelect)
def _(ir: PartwiseSelect) -> PartitionInfo:
    return _partitionwise_ir_parts_info(ir)


@generate_ir_tasks.register(PartwiseSelect)
def _(ir: PartwiseSelect) -> MutableMapping[Any, Any]:
    return _partitionwise_ir_tasks(ir)
