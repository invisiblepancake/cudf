/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

#include <cudf/wrappers/bool.hpp>

#include <tests/utilities/cudf_gtest.hpp>

#include <random>

struct Bool8Test : public ::testing::Test {

  Bool8Test()
      : dist{std::numeric_limits<uint8_t>::lowest(),
             std::numeric_limits<uint8_t>::max()} {

    // Use constant seed for deterministic results
    rng.seed(0);
  }

  std::mt19937 rng;
  std::uniform_int_distribution<uint8_t> dist;

  uint8_t rand(){
      return dist(rng);
  }
};

template <typename SourceType>
struct Bool8CtorTest : public ::testing::Test {
  Bool8CtorTest() {
    // Use constant seed for deterministic results
    rng.seed(0);
  }

  std::mt19937 rng;

  using uniform_distribution = typename std::conditional_t<
      std::is_same<SourceType, bool>::value, std::bernoulli_distribution,
      std::conditional_t<std::is_floating_point<SourceType>::value,
                         std::uniform_real_distribution<SourceType>,
                         std::uniform_int_distribution<SourceType>>>;

  uniform_distribution dist{};

  SourceType rand(){
      return dist(rng);
  }
};

/**
 * @brief The number of test trials
 */
static constexpr int NUM_TRIALS{10000};

using Bool8CastSourceTypes = ::testing::Types<char, bool, float, double, int32_t, int64_t>;

TYPED_TEST_CASE(Bool8CtorTest, Bool8CastSourceTypes);

TEST_F(Bool8Test, TestBool8Constructor) {
  for (int i = 0; i < NUM_TRIALS; ++i) {
    uint8_t t{this->rand()};
    cudf::experimental::bool8 const w{t};
    EXPECT_EQ(w.operator uint8_t(), static_cast<uint8_t>(static_cast<bool>(t)));
  }
}

// Ensure bool8 constructor is correctly casting the input type to a bool
TYPED_TEST(Bool8CtorTest, TestBool8ConstructorCast) {
  using SourceType = TypeParam;
  for (int i = 0; i < NUM_TRIALS; ++i) {
    SourceType t{this->rand()};
    cudf::experimental::bool8 const w{t};
    EXPECT_EQ(w.operator uint8_t(), static_cast<uint8_t>(static_cast<bool>(t)));
  }
}

TEST_F(Bool8Test, TestBool8Assignment) {
    for (int i = 0; i < NUM_TRIALS; ++i) {
      uint8_t const t0{this->rand()};
      uint8_t const t1{this->rand()};
      cudf::experimental::bool8 w0{t0};
      cudf::experimental::bool8 w1{t1};

      w0 = w1;

      EXPECT_EQ(w0.operator bool(), static_cast<bool>(t1));
    }
}

TEST_F(Bool8Test, TestBool8ArithmeticOperators) {
    for(int i = 0; i < NUM_TRIALS; ++i) {
        uint8_t const t0{static_cast<bool>(this->rand())};
        uint8_t const t1{static_cast<bool>(this->rand())};

        cudf::experimental::bool8 const w0{t0};
        cudf::experimental::bool8 const w1{t1};

        // Types smaller than int are implicitly promoted to `int` for
        // arithmetic operations. Therefore, need to convert it back to the
        // original type
        EXPECT_EQ(static_cast<bool>(cudf::experimental::bool8{w0 + w1}.operator uint8_t()),
                  static_cast<bool>(t0 + t1));
        EXPECT_EQ(static_cast<bool>(cudf::experimental::bool8{w0 - w1}.operator uint8_t()),
                  static_cast<bool>(t0 - t1));
        EXPECT_EQ(static_cast<bool>(cudf::experimental::bool8{w0 * w1}.operator uint8_t()),
                  static_cast<bool>(t0 * t1));
        if (0 != t1) {
            EXPECT_EQ(static_cast<bool>(cudf::experimental::bool8{w0 / w1}.operator uint8_t()),
                      static_cast<bool>(t0 / t1));
        }
    }
}

TEST_F(Bool8Test, TestBool8BinaryOperators) {
    for(int i = 0; i < NUM_TRIALS; ++i) {
        bool const t0{this->rand() != 0};
        bool const t1{this->rand() != 0};

        cudf::experimental::bool8 const w0{t0};
        cudf::experimental::bool8 const w1{t1};

        EXPECT_EQ(w0 > w1, t0 > t1);
        EXPECT_EQ(w0 < w1, t0 < t1);
        EXPECT_EQ(w0 <= w1, t0 <= t1);
        EXPECT_EQ(w0 >= w1, t0 >= t1);
        EXPECT_EQ(w0 == w1, t0 == t1);
        EXPECT_EQ(w0 != w1, t0 != t1);
    }

    cudf::experimental::bool8 w2{42};
    cudf::experimental::bool8 w3{43};

    EXPECT_TRUE(w2 == w2);
    EXPECT_TRUE(w2 == w3);
    EXPECT_FALSE(w2 < w3);
    EXPECT_FALSE(w2 > w3);
    EXPECT_FALSE(w2 != w3);
    EXPECT_TRUE(w2 >= w2);
    EXPECT_TRUE(w2 <= w2);
    EXPECT_TRUE(w2 >= w3);
    EXPECT_TRUE(w2 <= w3);

    cudf::experimental::bool8 w4{static_cast<char>(-42)};
    cudf::experimental::bool8 w5{43};

    EXPECT_TRUE(w4 == w4);
    EXPECT_TRUE(w5 == w5);
    EXPECT_FALSE(w4 < w5);
    EXPECT_FALSE(w4 > w5);
    EXPECT_FALSE(w4 != w5);
    EXPECT_TRUE(w4 >= w4);
    EXPECT_TRUE(w4 <= w4);
    EXPECT_TRUE(w4 >= w5);
    EXPECT_TRUE(w4 <= w5);

    cudf::experimental::bool8 w6{0};
    cudf::experimental::bool8 w7{43};

    EXPECT_FALSE(w6 == w7);
    EXPECT_TRUE(w6 < w7);
    EXPECT_TRUE(w7 > w6);
    EXPECT_FALSE(w6 > w7);
    EXPECT_TRUE(w6 != w7);
    EXPECT_TRUE(w6 >= w6);
    EXPECT_TRUE(w6 <= w6);
    EXPECT_FALSE(w6 >= w7);
    EXPECT_TRUE(w6 <= w7);
}

// This ensures that casting cudf::experimental::bool8 to int, doing arithmetic, and casting
// the result to bool results in the right answer. If the arithmetic is done
// on random underlying values you can get the wrong answer.
TEST_F(Bool8Test, TestBool8ArithmeticCast) {
    cudf::experimental::bool8 w1{42};
    cudf::experimental::bool8 w2{static_cast<char>(-42)};

    bool t1{42 != 0};
    bool t2{-42 != 0};

    EXPECT_EQ(static_cast<bool>(static_cast<uint8_t>(w1) + static_cast<uint8_t>(w2)),
              static_cast<bool>(static_cast<uint8_t>(t1) + static_cast<uint8_t>(t2)));
}

TEST_F(Bool8Test, TestBool8CompoundAssignmentOperators) {
    for(int i = 0; i < NUM_TRIALS; ++i) {
        bool t0{static_cast<bool>(this->rand())};
        bool const t1{static_cast<bool>(this->rand())};

        cudf::experimental::bool8 w0{t0};
        cudf::experimental::bool8 const w1{t1};

        t0 += t1;
        w0 += w1;
        EXPECT_EQ(static_cast<bool>(w0), t0);

        t0 -= t1;
        w0 -= w1;
        EXPECT_EQ(static_cast<bool>(w0), t0);


        t0 *= t1;
        w0 *= w1;
        EXPECT_EQ(static_cast<bool>(w0), t0);

        if (t1) {
            t0 /= t1;
            w0 /= w1;
            EXPECT_EQ(static_cast<bool>(w0), t0);
        }
    }
}

TEST_F(Bool8Test, TestBool8NumericLimitsTest) {
    EXPECT_EQ(static_cast<uint8_t>(std::numeric_limits<cudf::experimental::bool8>::max()),
              static_cast<uint8_t>(static_cast<bool>(std::numeric_limits<uint8_t>::max())));
    EXPECT_EQ(static_cast<uint8_t>(std::numeric_limits<cudf::experimental::bool8>::min()),
              static_cast<uint8_t>(static_cast<bool>(std::numeric_limits<uint8_t>::min())));
    EXPECT_EQ(static_cast<uint8_t>(std::numeric_limits<cudf::experimental::bool8>::lowest()),
              static_cast<uint8_t>(static_cast<bool>(std::numeric_limits<uint8_t>::lowest())));
}
