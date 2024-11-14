# Copyright (c) 2024, NVIDIA CORPORATION.
from enum import IntEnum
from typing import Final

class Interpolation(IntEnum):
    LINEAR = ...
    LOWER = ...
    HIGHER = ...
    MIDPOINT = ...
    NEAREST = ...

class MaskState(IntEnum):
    UNALLOCATED = ...
    UNINITIALIZED = ...
    ALL_VALID = ...
    ALL_NULL = ...

class NanEquality(IntEnum):
    ALL_EQUAL = ...
    UNEQUAL = ...

class NanPolicy(IntEnum):
    NAN_IS_NULL = ...
    NAN_IS_VALID = ...

class NullEquality(IntEnum):
    EQUAL = ...
    UNEQUAL = ...

class NullOrder(IntEnum):
    AFTER = ...
    BEFORE = ...

class NullPolicy(IntEnum):
    EXCLUDE = ...
    INCLUDE = ...

class Order(IntEnum):
    ASCENDING = ...
    DESCENDING = ...

class Sorted(IntEnum):
    NO = ...
    YES = ...

class TypeId(IntEnum):
    EMPTY = ...
    INT8 = ...
    INT16 = ...
    INT32 = ...
    INT64 = ...
    UINT8 = ...
    UINT16 = ...
    UINT32 = ...
    UINT64 = ...
    FLOAT32 = ...
    FLOAT64 = ...
    BOOL8 = ...
    TIMESTAMP_DAYS = ...
    TIMESTAMP_SECONDS = ...
    TIMESTAMP_MILLISECONDS = ...
    TIMESTAMP_MICROSECONDS = ...
    TIMESTAMP_NANOSECONDS = ...
    DURATION_DAYS = ...
    DURATION_SECONDS = ...
    DURATION_MILLISECONDS = ...
    DURATION_MICROSECONDS = ...
    DURATION_NANOSECONDS = ...
    DICTIONARY32 = ...
    STRING = ...
    LIST = ...
    DECIMAL32 = ...
    DECIMAL64 = ...
    DECIMAL128 = ...
    STRUCT = ...
    NUM_TYPE_IDS = ...

class DataType:
    def __init__(self, type_id: TypeId, scale: int = 0): ...
    def id(self) -> TypeId: ...
    def scale(self) -> int: ...

def size_of(t: DataType) -> int: ...

SIZE_TYPE: Final[DataType]
SIZE_TYPE_ID: Final[TypeId]
