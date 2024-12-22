# Copyright (c) 2020-2024, NVIDIA CORPORATION.


import pandas as pd
import pytest

import cudf
from cudf.core.column import as_column
from cudf.core.column_accessor import ColumnAccessor
from cudf.testing import assert_eq

simple_test_data = [
    {},
    {"a": as_column([])},
    {"a": as_column([1])},
    {"a": as_column(["a"])},
    {"a": as_column([1, 2, 3]), "b": as_column(["a", "b", "c"])},
]

mi_test_data = [
    {("a", "b"): as_column([1, 2, 4]), ("a", "c"): as_column([2, 3, 4])},
    {("a", "b"): as_column([1, 2, 3]), ("a", ""): as_column([2, 3, 4])},
    {("a", "b"): as_column([1, 2, 4]), ("c", "d"): as_column([2, 3, 4])},
    {
        ("a", "b"): as_column([1, 2, 3]),
        ("a", "c"): as_column([2, 3, 4]),
        ("b", ""): as_column([4, 5, 6]),
    },
]


def check_ca_equal(lhs, rhs):
    assert lhs.level_names == rhs.level_names
    assert lhs.multiindex == rhs.multiindex
    assert lhs.rangeindex == rhs.rangeindex
    assert lhs.label_dtype == rhs.label_dtype
    for l_key, r_key in zip(lhs, rhs):
        assert l_key == r_key
        assert_eq(lhs[l_key], rhs[r_key])


@pytest.fixture(params=simple_test_data)
def simple_data(request):
    return request.param


@pytest.fixture(params=mi_test_data)
def mi_data(request):
    return request.param


@pytest.fixture(params=simple_test_data + mi_test_data)
def all_data(request):
    return request.param


def test_to_pandas_simple(simple_data):
    """
    Test that a ColumnAccessor converts to a correct pd.Index
    """
    ca = ColumnAccessor(simple_data)
    # We cannot return RangeIndex, while pandas returns RangeIndex.
    # Pandas compares `inferred_type` which is `empty` for
    # Index([], dtype='object'), and `integer` for RangeIndex()
    # to ignore this `inferred_type` comparison, we pass exact=False.
    assert_eq(
        ca.to_pandas_index,
        pd.DataFrame(
            {key: value.values_host for key, value in simple_data.items()}
        ).columns,
        exact=False,
    )


def test_to_pandas_multiindex(mi_data):
    ca = ColumnAccessor(mi_data, multiindex=True)
    assert_eq(
        ca.to_pandas_index,
        pd.DataFrame(
            {key: value.values_host for key, value in mi_data.items()}
        ).columns,
    )


def test_to_pandas_multiindex_names():
    ca = ColumnAccessor(
        {("a", "b"): as_column([1, 2, 3]), ("c", "d"): as_column([3, 4, 5])},
        multiindex=True,
        level_names=("foo", "bar"),
    )
    assert_eq(
        ca.to_pandas_index,
        pd.MultiIndex.from_tuples(
            (("a", "b"), ("c", "d")), names=("foo", "bar")
        ),
    )


def test_iter(simple_data):
    """
    Test that iterating over the CA
    yields column names.
    """
    ca = ColumnAccessor(simple_data)
    for expect_key, got_key in zip(simple_data, ca):
        assert expect_key == got_key


def test_all_columns(simple_data):
    """
    Test that all values of the CA are
    columns.
    """
    ca = ColumnAccessor(simple_data)
    for col in ca.values():
        assert isinstance(col, cudf.core.column.ColumnBase)


def test_column_size_mismatch():
    """
    Test that constructing a CA from columns of
    differing sizes throws an error.
    """
    with pytest.raises(ValueError):
        ColumnAccessor({"a": as_column([1]), "b": as_column([1, 2])})


def test_select_by_label_simple():
    """
    Test getting a column by label
    """
    ca = ColumnAccessor({"a": as_column([1, 2, 3]), "b": as_column([2, 3, 4])})
    check_ca_equal(
        ca.select_by_label("a"), ColumnAccessor({"a": as_column([1, 2, 3])})
    )
    check_ca_equal(
        ca.select_by_label("b"), ColumnAccessor({"b": as_column([2, 3, 4])})
    )


def test_select_by_label_multiindex():
    """
    Test getting column(s) by label with MultiIndex
    """
    ca = ColumnAccessor(
        {
            ("a", "b", "c"): as_column([1, 2, 3]),
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("b", "x", ""): as_column([4, 5, 6]),
            ("a", "d", "e"): as_column([3, 4, 5]),
        },
        multiindex=True,
    )

    expect = ColumnAccessor(
        {
            ("b", "c"): as_column([1, 2, 3]),
            ("b", "e"): as_column([2, 3, 4]),
            ("d", "e"): as_column([3, 4, 5]),
        },
        multiindex=True,
    )
    got = ca.select_by_label("a")
    check_ca_equal(expect, got)

    expect = ColumnAccessor(
        {"c": as_column([1, 2, 3]), "e": as_column([2, 3, 4])},
        multiindex=False,
    )
    got = ca.select_by_label(("a", "b"))
    check_ca_equal(expect, got)

    expect = ColumnAccessor(
        {
            ("b", "c"): as_column([1, 2, 3]),
            ("b", "e"): as_column([2, 3, 4]),
            ("d", "e"): as_column([3, 4, 5]),
        },
        multiindex=True,
    )
    got = ca.select_by_label("a")
    check_ca_equal(expect, got)

    expect = ColumnAccessor(
        {"c": as_column([1, 2, 3]), "e": as_column([2, 3, 4])},
        multiindex=False,
    )
    got = ca.select_by_label(("a", "b"))
    check_ca_equal(expect, got)


def test_select_by_label_simple_slice():
    ca = ColumnAccessor(
        {
            "a": as_column([1, 2, 3]),
            "b": as_column([2, 3, 4]),
            "c": as_column([3, 4, 5]),
        }
    )
    expect = ColumnAccessor(
        {"b": as_column([2, 3, 4]), "c": as_column([3, 4, 5])}
    )
    got = ca.select_by_label(slice("b", "c"))
    check_ca_equal(expect, got)


def test_select_by_label_multiindex_slice():
    ca = ColumnAccessor(
        {
            ("a", "b", "c"): as_column([1, 2, 3]),
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("a", "d", "e"): as_column([3, 4, 5]),
            ("b", "x", ""): as_column([4, 5, 6]),
        },
        multiindex=True,
    )  # pandas needs columns to be sorted to do slicing with multiindex
    expect = ca
    got = ca.select_by_label(slice(None, None))
    check_ca_equal(expect, got)

    expect = ColumnAccessor(
        {
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("a", "d", "e"): as_column([3, 4, 5]),
            ("b", "x", ""): as_column([4, 5, 6]),
        },
        multiindex=True,
    )
    got = ca.select_by_label(slice(("a", "b", "e"), ("b", "x", "")))
    check_ca_equal(expect, got)


def test_by_label_list():
    ca = ColumnAccessor(
        {
            "a": as_column([1, 2, 3]),
            "b": as_column([2, 3, 4]),
            "c": as_column([3, 4, 5]),
        }
    )
    expect = ColumnAccessor(
        {"b": as_column([2, 3, 4]), "c": as_column([3, 4, 5])}
    )
    got = ca.select_by_label(["b", "c"])
    check_ca_equal(expect, got)


def test_select_by_index_simple():
    """
    Test getting a column by label
    """
    ca = ColumnAccessor({"a": as_column([1, 2, 3]), "b": as_column([2, 3, 4])})
    check_ca_equal(
        ca.select_by_index(0), ColumnAccessor({"a": as_column([1, 2, 3])})
    )
    check_ca_equal(
        ca.select_by_index(1), ColumnAccessor({"b": as_column([2, 3, 4])})
    )
    check_ca_equal(ca.select_by_index([0, 1]), ca)
    check_ca_equal(ca.select_by_index(slice(0, None)), ca)


def test_select_by_index_multiindex():
    """
    Test getting column(s) by label with MultiIndex
    """
    ca = ColumnAccessor(
        {
            ("a", "b", "c"): as_column([1, 2, 3]),
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("b", "x", ""): as_column([4, 5, 6]),
            ("a", "d", "e"): as_column([3, 4, 5]),
        },
        multiindex=True,
    )

    expect = ColumnAccessor(
        {
            ("a", "b", "c"): as_column([1, 2, 3]),
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("b", "x", ""): as_column([4, 5, 6]),
        },
        multiindex=True,
    )
    got = ca.select_by_index(slice(0, 3))
    check_ca_equal(expect, got)

    expect = ColumnAccessor(
        {
            ("a", "b", "c"): as_column([1, 2, 3]),
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("a", "d", "e"): as_column([3, 4, 5]),
        },
        multiindex=True,
    )
    got = ca.select_by_index([0, 1, 3])
    check_ca_equal(expect, got)


def test_select_by_index_empty():
    ca = ColumnAccessor(
        {
            ("a", "b", "c"): as_column([1, 2, 3]),
            ("a", "b", "e"): as_column([2, 3, 4]),
            ("b", "x", ""): as_column([4, 5, 6]),
            ("a", "d", "e"): as_column([3, 4, 5]),
        },
        multiindex=True,
    )
    expect = ColumnAccessor(
        {}, multiindex=True, level_names=((None, None, None))
    )
    got = ca.select_by_index(slice(None, 0))
    check_ca_equal(expect, got)

    got = ca.select_by_index([])
    check_ca_equal(expect, got)


def test_replace_level_values_RangeIndex():
    ca = ColumnAccessor(
        {
            ("a"): as_column([1, 2, 3]),
            ("b"): as_column([2, 3, 4]),
            ("c"): as_column([3, 4, 5]),
        },
        multiindex=False,
    )

    expect = ColumnAccessor(
        {
            ("f"): as_column([1, 2, 3]),
            ("b"): as_column([2, 3, 4]),
            ("c"): as_column([3, 4, 5]),
        },
        multiindex=False,
    )

    got = ca.rename_levels(mapper={"a": "f"}, level=0)
    check_ca_equal(expect, got)


def test_replace_level_values_MultiColumn():
    ca = ColumnAccessor(
        {
            ("a", 1): as_column([1, 2, 3]),
            ("a", 2): as_column([2, 3, 4]),
            ("b", 1): as_column([3, 4, 5]),
        },
        multiindex=True,
    )

    expect = ColumnAccessor(
        {
            ("f", 1): as_column([1, 2, 3]),
            ("f", 2): as_column([2, 3, 4]),
            ("b", 1): as_column([3, 4, 5]),
        },
        multiindex=True,
    )

    got = ca.rename_levels(mapper={"a": "f"}, level=0)
    check_ca_equal(expect, got)

    # passing without level kwarg assumes level=0
    got = ca.rename_levels(mapper={"a": "f"})
    check_ca_equal(expect, got)


def test_clear_nrows_empty_before():
    ca = ColumnAccessor({})
    assert ca.nrows == 0
    ca.insert("new", as_column([1]))
    assert ca.nrows == 1


def test_clear_nrows_empty_after():
    ca = ColumnAccessor({"new": as_column([1])})
    assert ca.nrows == 1
    del ca["new"]
    assert ca.nrows == 0


def test_not_rangeindex_and_multiindex():
    with pytest.raises(ValueError):
        ColumnAccessor({}, multiindex=True, rangeindex=True)


def test_data_values_not_column_raises():
    with pytest.raises(ValueError):
        ColumnAccessor({"a": [1]})
