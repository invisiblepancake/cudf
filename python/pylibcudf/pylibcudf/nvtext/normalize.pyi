# Copyright (c) 2024, NVIDIA CORPORATION.

from pylibcudf.column import Column

def normalize_spaces(input: Column) -> Column: ...
def normalize_characters(input: Column, do_lower_case: bool) -> Column: ...
