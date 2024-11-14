# Copyright (c) 2024, NVIDIA CORPORATION.

from typing import Final

from pylibcudf.column import Column
from pylibcudf.table import Table

LIBCUDF_DEFAULT_HASH_SEED: Final[int]

def murmurhash3_x86_32(input: Table, seed: int = ...) -> Column: ...
def murmurhash3_x64_128(input: Table, seed: int = ...) -> Table: ...
def xxhash_64(input: Table, seed: int = ...) -> Column: ...
def md5(input: Table) -> Column: ...
def sha1(input: Table) -> Column: ...
def sha224(input: Table) -> Column: ...
def sha256(input: Table) -> Column: ...
def sha384(input: Table) -> Column: ...
def sha512(input: Table) -> Column: ...
