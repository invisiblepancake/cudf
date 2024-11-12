# Copyright (c) 2024, NVIDIA CORPORATION.

from pylibcudf.column import Column
from pylibcudf.scalar import Scalar

def minhash(
    input: Column, seeds: Column | Scalar, width: int = 4
) -> Column: ...
def minhash64(
    input: Column, seeds: Column | Scalar, width: int = 4
) -> Column: ...
def word_minhash(input: Column, seeds: Column) -> Column: ...
def word_minhash64(input: Column, seeds: Column) -> Column: ...
