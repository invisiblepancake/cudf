# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
# SPDX-License-Identifier: Apache-2.0
"""Parallel Join Logic."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from cudf_polars.dsl.ir import Join
from cudf_polars.experimental.parallel import (
    _concat,
    _ir_parts_info,
    generate_ir_tasks,
    get_key_name,
    ir_parts_info,
)

if TYPE_CHECKING:
    from collections.abc import MutableMapping

    from polars import GPUEngine

    from cudf_polars.dsl.ir import IR
    from cudf_polars.experimental.parallel import PartitionInfo


class BroadcastJoin(Join):
    """Broadcast Join operation."""


class LeftBroadcastJoin(BroadcastJoin):
    """Left Broadcast Join operation."""


class RightBroadcastJoin(BroadcastJoin):
    """Right Broadcast Join operation."""


def lower_join_node(ir: Join, rec) -> IR:
    """Rewrite a Join node with proper partitioning."""
    # TODO: Add shuffle-based join.
    # (Currently using broadcast join in all cases)

    how = ir.options[0]
    if how not in ("inner", "left", "right"):
        # Not supported (yet)
        return ir
    children = [rec(child) for child in ir.children]
    left, right = children
    left_parts = ir_parts_info(left)
    right_parts = ir_parts_info(right)
    if left_parts.count == right_parts.count == 1:
        # Single-partition case
        return ir
    elif left_parts.count >= right_parts.count and how in ("inner", "left"):
        # Broadcast right to every partition of left
        return RightBroadcastJoin(
            ir.schema,
            ir.left_on,
            ir.right_on,
            ir.options,
            *children,
        )
    else:
        # Broadcast left to every partition of right
        return LeftBroadcastJoin(
            ir.schema,
            ir.left_on,
            ir.right_on,
            ir.options,
            *children,
        )


@_ir_parts_info.register(LeftBroadcastJoin)
def _(ir: LeftBroadcastJoin) -> PartitionInfo:
    return ir_parts_info(ir.children[1])


@_ir_parts_info.register(RightBroadcastJoin)
def _(ir: RightBroadcastJoin) -> PartitionInfo:
    return ir_parts_info(ir.children[0])


@generate_ir_tasks.register(BroadcastJoin)
def _(ir: BroadcastJoin, config: GPUEngine) -> MutableMapping[Any, Any]:
    left, right = ir.children
    bcast_side = "right" if isinstance(ir, RightBroadcastJoin) else "left"
    left_name = get_key_name(left)
    right_name = get_key_name(right)
    key_name = get_key_name(ir)
    parts = ir_parts_info(ir)
    bcast_parts = ir_parts_info(right) if bcast_side == "right" else ir_parts_info(left)

    graph: MutableMapping[Any, Any] = {}
    for i in range(parts.count):
        sub_names = []
        for j in range(bcast_parts.count):
            if bcast_side == "right":
                l_index = i
                r_index = j
            else:
                l_index = j
                r_index = i

            key: tuple[str, int, int] | tuple[str, int] = (key_name, i)
            if bcast_parts.count > 1:
                sub_names.append((key_name, i, j))
                key = sub_names[-1]
            graph[key] = (
                ir.do_evaluate,
                config,
                ir.left_on,
                ir.right_on,
                ir.options,
                (left_name, l_index),
                (right_name, r_index),
            )
        if len(sub_names) > 1:
            graph[(key_name, i)] = (_concat, sub_names)

    return graph
