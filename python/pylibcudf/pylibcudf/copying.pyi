# Copyright (c) 2024, NVIDIA CORPORATION.

from enum import IntEnum
from typing import TypeVar

from pylibcudf.column import Column
from pylibcudf.scalar import Scalar
from pylibcudf.table import Table

class MaskAllocationPolicy(IntEnum):
    NEVER = ...
    RETAIN = ...
    ALWAYS = ...

class OutOfBoundsPolicy(IntEnum):
    NULLIFY = ...
    DONT_CHECK = ...

ColumnOrTable = TypeVar("ColumnOrTable", Column, Table)

def gather(
    source_table: Table, gather_map: Column, bounds_policy: OutOfBoundsPolicy
) -> Table: ...
def scatter(
    source: Table | list[Scalar], scatter_map: Column, target_table: Table
) -> Table: ...
def empty_like(input: ColumnOrTable) -> ColumnOrTable: ...
def allocate_like(
    input_column: Column, policy: MaskAllocationPolicy, size: int | None = None
) -> Column: ...
def copy_range_in_place(
    input_column: Column,
    target_column: Column,
    input_begin: int,
    input_end: int,
    target_begin: int,
) -> Column: ...
def copy_range(
    input_column: Column,
    target_column: Column,
    input_begin: int,
    input_end: int,
    target_begin: int,
) -> Column: ...
def shift(input: Column, offset: int, fill_value: Scalar) -> Column: ...
def slice(input: ColumnOrTable, indices: list[int]) -> list[ColumnOrTable]: ...
def split(input: ColumnOrTable, splits: list[int]) -> list[ColumnOrTable]: ...
def copy_if_else(
    lhs: Column | Scalar, rhs: Column | Scalar, boolean_mask: Column
) -> Column: ...
def boolean_mask_scatter(
    input: Table | list[Scalar], target: Table, boolean_mask: Column
) -> Table: ...
def get_element(input_column: Column, index: int) -> Scalar: ...
