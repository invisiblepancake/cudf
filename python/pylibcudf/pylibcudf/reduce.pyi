# Copyright (c) 2024, NVIDIA CORPORATION.

from enum import IntEnum

from pylibcudf.aggregation import Aggregation
from pylibcudf.column import Column
from pylibcudf.scalar import Scalar
from pylibcudf.types import DataType

class ScanType(IntEnum):
    INCLUSIVE = ...
    EXCLUSIVE = ...

def reduce(col: Column, agg: Aggregation, data_type: DataType) -> Scalar: ...
def scan(col: Column, agg: Aggregation, inclusive: ScanType) -> Column: ...
def minmax(col: Column) -> tuple[Scalar, Scalar]: ...
