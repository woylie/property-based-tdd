# Property-Based Test-Driven Development in Elixir

Recently I came across a small function in our code base that was meant to transform a list of arbitrarily sorted and possibly overlapping time ranges into a sorted list of non-overlapping time ranges, or in other words, to merge the time ranges in a list. The function was covered by example-based unit tests, but unfortunately, once in a while the function would throw an error. This was a good opportunity to use property-based testing in order to find inputs that would cause the errors.

In this blog post, I would like to turn it around and build a function like that from scratch by using a property-based test-driven approach. The principles of property-based testing are easy to understand, but the challenge is to find good properties that fully describe a function.

We will use the [StreamData](https://github.com/whatyouhide/stream_data) library, but it should be easy to apply the steps to other libraries like [PropEr](https://hex.pm/packages/proper).

## The problem

We need to write a function that takes a list of date ranges and returns a list of date ranges sorted by start date that does not contain any overlapping date ranges.

Date ranges are represented by 2-tuples (we could also have used the `Date.Range` type instead). The end date in the tuple always has to be greater than or equal to the start date.

Example input:

```elixir
[
  {~D[1999-01-01], ~D[1999-06-01]},
  {~D[1998-11-01], ~D[1999-02-01]},
  {~D[1999-07-01], ~D[1999-08-01]},
  {~D[1999-10-01], ~D[1999-12-01]}
]
```

The function should turn this into:

```elixir
[
  {~D[1998-11-01], ~D[1999-08-01]},
  {~D[1999-10-01], ~D[1999-12-01]}
]
```

## Setup

Let's start by creating a new mix application.

```bash
mix new date_range_merger
cd date_range_merger
```

Add `{:stream_data, "~> 0.4.3"}` to `mix.exs` and run `mix deps.get`.

Change the content of `.formatter.exs` to the following in order to prevent `mix format` from adding brackets to StreamData macro calls:

```
# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 80,
  import_deps: [:stream_data]
]
```

## Generators

We need to create a generator that generates a valid date range tuple. Let's start by creating a generator for a date and build on that.

### Date generator

Replace the code in `test/date_range_merger_test.exs` with this:

```elixir
defmodule DateRangeMergerTest do
  use ExUnit.Case
  use ExUnitProperties

  import DateRangeMerger
  import StreamData

  defp date do
    gen all year <- integer(1970..2050),
            month <- integer(1..12),
            day <- integer(1..31),
            match?({:ok, _}, Date.from_erl({year, month, day})) do
      Date.from_erl!({year, month, day})
    end
  end

  property "generator test" do
    check all generated_date <- list_of(date()) do
      IO.inspect(generated_date)
    end
  end
end
```

What's happening here? We define a private function called `date` which uses the `ExUnitProperties.gen/1` macro to define a generator. In the first three lines of the function, we call `StreamData.integer/1` to generate values for the date parts.

The fourth line is a bit different: It doesn't generate new data, but acts as a filter. We try to build a date from the parts. When it succeeds, `match?/2` will return `true` and the generator returns whatever is returned in the `do` block. When it fails (e. g. when we generated a 31st of February), `match?/2` will return `false`, the generated year, month and day are discarded and the generator will try again with different values.

Why do we use `match?/1`? Why don't we just write `{:ok, date} <- Date.from_erl({year, month, day})`? While it is possible to filter generated values on the left side of the arrow through pattern matching, `gen/1` expects a generator on the right side of the arrow.

After the date generator, we define the first property test, although it is only a dummy test to verify our generator works as expected. Property tests are defined with the `ExUnitProperties.property/2` macro. The test uses the `ExUnitProperties.check/1` macro to generate test data and run assertions within its `do` block.

When you run `mix test`, you should see a list of 100 random dates between 1st January 1970 and 31st December 2050.

### Date range generator

Now that we have our date generator, we can build a date range generator on top of it. It is easy to compose generators. Our requirement is that the end date has to be greater than or equal to the start date.

Add this right below the `date/0` function:

```elixir
defp date_range do
  gen all start_date <- date(),
          days_between <- integer(0..18_250) do
    {start_date, Date.add(start_date, days_between)}
  end
end
```

We use our custom date generator to create the start date and generate a number of days to add between 0 and 365 \* 50. Of course this will cause our generator to return date ranges between 1970 and 2100. If we still want to keep our date range within 1970 and 2050, we can add a filter clause like this:

```elixir
defp date_range do
  gen all start_date <- date(),
          days_between <- integer(0..18_250),
          end_date = Date.add(start_date, days_between),
          Date.compare(end_date, ~D[2050-12-31]) != :gt do
    {start_date, end_date}
  end
end
```

Let's change the property test to:

```elixir
property "generator test" do
  check all date_range <- date_range() do
    IO.inspect(date_range)
  end
end
```

Now run `mix test`, and you should... whoa, what's this?

```
1) property generator test (DateRangeMergerTest)
     test/date_range_merger_test.exs:25
     ** (StreamData.FilterTooNarrowError) too many consecutive elements were filtered out.
      To avoid this:

       * make sure the generation space contains enough values that the chance of a generated
         value being filtered out is small. For example, don't generate all integers and filter
         out odd ones in order to have a generator of even integers (since you'd be taking out
         half the generation space).

       * keep an eye on how the generation size affects the generator being filtered. For
         example, you might be filtering out only a handful of values from the generation space,
         but small generation sizes might make the generation space much smaller hence increasing
         the probability of values that you'd filter out being generated.

       * try to restructure your generator so that instead of generating many values and taking
         out the ones you don't want, you instead generate values and turn all of them into
         values that are suitable. For example, multiply integers by two to have a generator of
         even values instead of filtering out all odd integers.
```

The filter is too narrow! Turns out that StreamData doesn't like it if you generate too many invalid values. Let's try to fix this.

One way to do this would be to reduce the maximum difference between the dates, thereby reducing the risk that the end date is after 2050:

```elixir
days_between <- integer(0..1000),
```

That seems to work, but it isn't particularly nice. We want a broad range of inputs in a property-based test, and now we reduced the maximum date range to a mere 1000 days. Let's try a different approach.

```elixir
defp date_range do
  gen all start_date <- date(),
          max_difference = Date.diff(~D[2050-12-31], start_date),
          days_between <- integer(0..max_difference) do
    {start_date, Date.add(start_date, days_between)}
  end
end
```

This is much better. Instead of generating a lot of values and filtering out the ones we don't want, we calculate the maximum allowed difference from the generated start date, so that we only generate valid end dates in the first place. No need for a filter.

Run `mix test` again and you should see a glorious list of date ranges between 1970 and 2050.

## First property: Always returns a list

Time for our first property. We're going to start simple: We know that the function should always return a list for valid input.

Replace the dummy property test with this:

```elixir
property "always returns a list" do
  check all date_ranges <- list_of(date_range()) do
    assert is_list(merge(date_ranges))
  end
end
```

This might not seem very exciting, but it ensures that whatever implementation we come up with will never throw an exception. This property was already enough to uncover the problem with the faulty implementation mentioned in the introduction.

Unsurprisingly, the compiler will complain about an undefined function. Since we want to follow a pure TDD approach, let's write the bare minimum to make this test pass. Replace the code in `lib/date_range_merger.ex` with:

```elixir
defmodule DateRangeMerger do
  @moduledoc """
  Documentation for DateRangeMerger.
  """

  @doc """
  Takes a list of date ranges and returns a list of date ranges sorted by first
  date that does not contain any overlapping date ranges.
  """
  @spec merge([{Date.t(), Date.t()}]) :: [{Date.t(), Date.t()}]
  def merge(date_ranges) when is_list(date_ranges) do
    []
  end
end
```

Brilliant. There's only one tiny problem: The input date ranges are not contained within the output. This seems like a good property to tackle next.

## Second property: Each input date range is covered

So let's implement that as a property test. We still want to generate a list of input date ranges. Then we want to make sure that each date range in the list is covered by one of the date ranges in the result list. Since we're supposed to merge overlapping date ranges, we don't look for an exact match. Our property could look something like this:

```elixir
property "input date ranges are contained within output date ranges" do
  check all date_ranges <- list_of(date_range()) do
    result = merge(date_ranges)

    for {start_date, end_date} <- date_ranges do
      assert {_, _} =
               Enum.find(result, fn {result_start_date, result_end_date} ->
                 Date.to_erl(start_date) >= Date.to_erl(result_start_date) &&
                   Date.to_erl(end_date) <= Date.to_erl(result_end_date)
               end)
    end
  end
end
```

Note that we have to convert the dates to tuples with `Date.to_erl/1` before we can compare them, because otherwise Dates would be ordered structurally according to Erlang's term ordering. Alternatively, we could use `Date.compare/2`, but I think the version above is more readable than this:

```elixir
Date.compare(start_date, result_start_date) != :lt &&
  Date.compare(end_date, result_end_date) != :gt
```

When we run `mix test`, we get this:

```
1) property input date ranges are contained within output date ranges (DateRangeMergerTest)
     test/date_range_merger_test.exs:31
     Failed with generated values (after 0 successful runs):

         * Clause:    date_ranges <- list_of(date_range())
           Generated: [{~D[1973-07-10], ~D[1973-07-10]}]

     match (=) failed
     code:  assert {_, _} = Enum.find(result, fn {result_start_date, result_end_date} -> Date.compare(start_date, result_start_date) != :lt && Date.compare(end_date, result_end_date) != :gt end)
```

StreamData has shrunk the input list to a single date range, which obviously cannot be found in the empty list returned by the function. We can make this test pass with a simple change:

```elixir
def merge(date_ranges) when is_list(date_ranges) do
  date_ranges
end
```

Instead of an empty list, we just return the untouched input list.

## Third property: Output is sorted

It's time that the function actually does something. Let's add another easy property: The output list is supposed to be sorted by start date. We can test this by chunking the result list in pairs of date ranges and asserting that in each pair, the start date of the first date range is lower than or equal to the start date of the second date range.

```elixir
property "output date ranges are sorted by start date" do
  check all date_ranges <- list_of(date_range()) do
    pairs =
      date_ranges
      |> merge()
      |> Enum.chunk_every(2, 1, :discard)

    for [{start_date_a, _}, {start_date_b, _}] <- pairs do
      assert Date.to_erl(start_date_a) <= Date.to_erl(start_date_b)
    end
  end
end
```

To make this pass, all we have to do is to sort the input list:

```elixir
def merge(date_ranges) when is_list(date_ranges) do
  Enum.sort_by(date_ranges, fn {start_date, _} -> Date.to_erl(start_date) end)
end
```

So far, so good. Now on to the actual merging part.

## Fourth property: No overlap

Let's recapitulate what we have done so far. We have made sure that all input date ranges are somehow contained within the output date ranges and that the output date ranges are sorted by start date. The other requirement is that the result does not contain any overlapping date ranges. What does this mean?

1. In a date range list sorted by start date, the start dates of two subsequent date ranges may not be the same.
2. In a date range list sorted by start date, for each pair of subsequent date ranges, the end date of the first range must be smaller than the start date of the second range.

We can implement this similarly to the third property (sorted list).

```elixir
property "output date ranges do not overlap" do
  check all date_ranges <- list_of(date_range()) do
    pairs =
      date_ranges
      |> merge()
      |> Enum.chunk_every(2, 1, :discard)

    for [{start_date_a, end_date_a}, {start_date_b, _}] <- pairs do
      assert Date.to_erl(start_date_a) != Date.to_erl(start_date_b)
      assert Date.to_erl(end_date_a) < Date.to_erl(start_date_b)
    end
  end
end
```

Of course we could merge the first point, or even both, into the previous property, but I prefer to keep these properties separate for reasons of clarity.

To make this test pass, we can build up the output list from the sorted listed in a reduce function.

```elixir
def merge(date_ranges) when is_list(date_ranges) do
  date_ranges
  |> Enum.sort_by(fn {start_date, _} -> Date.to_erl(start_date) end)
  |> Enum.reduce([], &merge_overlapping/2)
  |> Enum.reverse()
end

defp merge_overlapping(
       {next_start_date, next_end_date},
       [{previous_start_date, previous_end_date} | rest] = acc
     ) do
  if Date.to_erl(next_start_date) <= Date.to_erl(previous_end_date) do
    # date ranges overlap, merge them into one
    new_end_date =
      Enum.max_by([previous_end_date, next_end_date], &Date.to_erl/1)

    [{previous_start_date, new_end_date} | rest]
  else
    # date ranges don't overlap, prepend to list unchanged
    [{next_start_date, next_end_date} | acc]
  end
end

defp merge_overlapping({next_start_date, next_end_date}, []),
  do: [{next_start_date, next_end_date}]
```

So basically we walk through the list and figure out whether the current range overlaps with the previous range. If yes, we merge them and prepend the new date range tuple to the accumulated result list. If no, we prepend the current range to the result list as it is.

## Fifth property: Adjacent date ranges are merged

This makes our tests pass, but there is one small problem: We didn't consider that the date ranges are meant to be inclusive. That means that when the start date of a date range lies exactly one day after the end date of the previous date range, these ranges still have to be merged (e. g. `[{~D[1982-06-01], ~D[1982-07-01]}, {~D[1982-07-02], ~D[1982-07-04]}]` should be merged to `[{~D[1982-06-01], ~D[1982-07-04]}]`). Let's update our `"output date ranges do not overlap"` property test to reflect this.

Change this line:

```elixir
assert Date.to_erl(end_date_a) < Date.to_erl(start_date_b)
```

To this:

```
assert Date.diff(start_date_b, end_date_a) > 1
```

If you run the tests again, they will still pass most of the time. It seems like this particular case does not occur very frequently in the generated data. Let's add another more specific generator:

```elixir
defp adjacent_date_ranges do
  gen all {start_date_a, end_date_a} <- date_range(),
          start_date_b = Date.add(end_date_a, 1),
          max_difference = Date.diff(~D[2050-12-31], start_date_b),
          days_between <- integer(0..max_difference),
          end_date_b = Date.add(start_date_a, days_between) do
    Enum.shuffle([{start_date_a, end_date_a}, {start_date_b, end_date_b}])
  end
end
```

First we generate a single date range tuple with our existing generator, then we build a second range that starts exactly one day after the first one ends. As a last step, we build a list from both date ranges and shuffle it.

We could now use this new generator in the existing `"output date ranges do not overlap"` property, but I prefer to add a separate property, as it makes the intent clearer. Adjacent date ranges and overlapping date ranges are two different things, after all.

Add this at the end of the test module:

```elixir
property "adjacent date ranges are merged" do
  check all date_range_pairs <- list_of(adjacent_date_ranges()) do
    date_ranges = date_range_pairs |> Enum.concat() |> Enum.shuffle()

    pairs =
      date_ranges
      |> merge()
      |> Enum.chunk_every(2, 1, :discard)

    for [{start_date_a, end_date_a}, {start_date_b, _}] <- pairs do
      assert Date.to_erl(start_date_a) != Date.to_erl(start_date_b)
      assert Date.diff(start_date_b, end_date_a) > 1
    end
  end
end
```

The assertions are exactly the same as in `"output date ranges do not overlap"`. The only difference is the use of another generator.

If you run the tests now, they should fail reliably. The fix is easy. In `lib/date_range_merger.ex`, replace this line:

```elixir
if Date.to_erl(next_start_date) <= Date.to_erl(previous_end_date) do
```

With this:

```elixir
if Date.diff(next_start_date, previous_end_date) < 2 do
```

## Are we there yet?

So far, we made sure that:

1. the function always returns a list,
2. each input date range is contained within the output date ranges,
3. the output is sorted by start date,
4. the output date ranges do not overlap, and
5. adjacent date ranges are merged.

Is this enough to fully describe the function? Let's try to trick the tests with a faulty implementation. Replace `DateRangeMerger.merge/1` with this:

```elixir
def merge([]), do: []

def merge(date_ranges) when is_list(date_ranges) do
  start_date =
    date_ranges
    |> Enum.min_by(fn {a, _} -> Date.to_erl(a) end)
    |> elem(0)

  end_date =
    date_ranges
    |> Enum.max_by(fn {_, b} -> Date.to_erl(b) end)
    |> elem(1)

  [{start_date, end_date}]
end
```

Now run the tests again, and you should see:

```
5 properties, 0 failures
```

That was easy! Just by returning a list with a single date range that spans all the input date ranges, we made all tests pass.

We can make it even easier:

```elixir
def merge(date_ranges) when is_list(date_ranges) do
  [{~D[0000-01-01], ~D[9999-12-31]}]
end
```

This will also pass our tests.

Let's tackle the easier issue first.

## Sixth property: Min and max dates match in input and output

We were able to make our tests pass by returning a single date range that extends way beyond the test values we generate. We should make sure that:

1. the min start dates in the input and output are the same, and
2. that the max end dates in the input and output are the same.

That doesn't seem so difficult. Let's add this property test:

```elixir
property "min and max dates in input and output match" do
  check all date_ranges <- list_of(date_range()) do
    result = merge(date_ranges)

    assert min_start_date(date_ranges) == min_start_date(result)
    assert max_end_date(date_ranges) == max_end_date(result)
  end
end

defp min_start_date([]), do: nil

defp min_start_date(date_ranges) do
  date_ranges
  |> Enum.map(&elem(&1, 0))
  |> Enum.min_by(&Date.to_erl/1)
end

defp max_end_date([]), do: nil

defp max_end_date(date_ranges) do
  date_ranges
  |> Enum.map(&elem(&1, 1))
  |> Enum.max_by(&Date.to_erl/1)
end
```

This will make our tests fail with the second naive implementation, but our test suite is still being fooled by the first one.

## Seventh property: Gaps in input list are preserved

So what's the problem exactly? While we _do_ test whether all input date ranges are covered in the output list, we _do not_ ensure that the gaps between the input date ranges are preserved. Which strategies could we employ to test this property?

1. We could write a function that takes a list of date ranges and returns a list of date ranges that are not covered (the gaps). We could then assert that none of those gap date ranges are covered in the output list. However, the implementation of that function would probably be very similar to the function we want to test. Also, this gap-finder function would warrant its own unit tests.
2. We could pass the list of input date ranges to a second generator that also generates date ranges, but filters them so that it only returns date ranges not covered by the input date ranges. The generator would thus generate a list of random gap ranges that should not be covered. Unfortunately, this would cause a `FilterTooNarrowError` as we have seen earlier (I've tried).
3. We could build a generator similar to the `adjacent_date_ranges` generator, but have it generate a longer list of adjacent date ranges that will be marked as either `cover` or `gap`. The date ranges marked as `cover` would be used as input, while the date ranges marked as `gap` would be used in the assertion.

Since I cannot come up with a better solution, let's try to implement option 3.

The generator:

```elixir
defp date_ranges_with_gaps() do
  gen all initial_date <- date(),
          count <- integer(2..1000),
          date_ranges <- do_date_ranges_with_gaps(initial_date, count) do
    {cover, gap} =
      Enum.split_with(date_ranges, fn
        {:cover, _, _} -> true
        {:gap, _, _} -> false
      end)

    cover_ranges =
      cover
      |> Enum.map(fn {_, start_date, end_date} -> {start_date, end_date} end)
      |> Enum.shuffle()

    gap_ranges =
      gap
      |> Enum.map(fn {_, start_date, end_date} -> {start_date, end_date} end)
      |> Enum.shuffle()

    %{
      cover: cover_ranges,
      gap: gap_ranges
    }
  end
end

defp do_date_ranges_with_gaps(previous_end_date, count, acc \\ []) do
  if count <= 0 || Date.to_erl(previous_end_date) >= {2050, 12, 31} do
    constant(acc)
  else
    gen all type <- member_of([:cover, :gap]),
            start_date = Date.add(previous_end_date, 1),
            max_difference = Date.diff(~D[2050-12-31], start_date),
            days_between <- integer(0..max_difference),
            end_date = Date.add(start_date, days_between),
            result <-
              do_date_ranges_with_gaps(
                end_date,
                count - 1,
                [{type, start_date, end_date} | acc]
              ) do
      result
    end
  end
end
```

This generator is a bit trickier than the previous one, because it generates a list where each item depends on the previous item.

First we generate an initial date to start at and a count of list items to be generated. Then we call the sub-generator `do_date_ranges_with_gaps/3`. This is a recursive generator. Each call results in the generation of a single date range including the mark for `:cover` or `:gap`, which is prepended to the accumulator. As a last step, the generator uses itself to generate the subsequent date range, based on the generated end date of the current one. To eventually break out of the recursion, we decrement the `count` value on each iteration. Also, we still want to constrain the dates between 1970 and 2050, which is why we have the second break out condition.

Because the function needs to return a generator in any case, we wrap the accumulated list in the `constant/1` generator. We'll end up with a list of 3-tuples. Back in `date_ranges_with_gaps/0`, we turn this list into a map.

This is an example output of this generator:

```elixir
%{
  cover: [
    {~D[2050-12-15], ~D[2050-12-17]},
    {~D[2050-03-11], ~D[2050-04-20]},
    {~D[2050-12-20], ~D[2050-12-21]},
    {~D[2046-05-22], ~D[2048-01-13]},
    {~D[2048-01-14], ~D[2048-04-11]},
    {~D[2050-12-22], ~D[2050-12-22]},
    {~D[2048-08-18], ~D[2050-03-10]},
    {~D[2050-12-14], ~D[2050-12-14]}
  ],
  gap: [
    {~D[2025-05-15], ~D[2046-05-21]},
    {~D[2050-12-18], ~D[2050-12-19]},
    {~D[2050-12-29], ~D[2050-12-29]},
    {~D[2048-04-12], ~D[2048-08-17]},
    {~D[2050-04-21], ~D[2050-12-13]},
    {~D[2050-12-23], ~D[2050-12-28]},
    {~D[2050-12-30], ~D[2050-12-31]},
    {~D[2005-10-12], ~D[2025-05-14]}
  ]
}
```

One shortcoming of this generator is that it does not generate any overlapping date ranges in `:cover`. We could actually modify it to do that by calling `do_date_ranges_with_gaps/3` with both the previous start and end date and allowing the start date to be anywhere between the previous start date and one day after the previous end date, but only if the type is `:cover`. I'll leave this as an exercise to the reader.

With the generator in place, we can now write the property test.

```elixir
property "gaps are preserved" do
  check all date_ranges <- date_ranges_with_gaps() do
    result = merge(date_ranges[:cover])

    for {start_date, end_date} <- date_ranges[:gap] do
      assert is_nil(
               Enum.find(result, fn {result_start_date, result_end_date} ->
                 Date.to_erl(start_date) >= Date.to_erl(result_start_date) &&
                   Date.to_erl(end_date) <= Date.to_erl(result_end_date)
               end)
             )
    end
  end
end
```

This works exactly as the `output date ranges do not overlap` test, except that we assert that the gap date ranges are actually _not_ covered by the output ranges.

The faulty implementation of `merge/1` we added earlier will finally fail this test. We can now revert the function to the correct implementation to make the test suite pass again.

## Conclusion

We started with a simple task and a basic property test and gradually built on that to create a test suite that should hopefully thoroughly cover the requirements.

We came up with these properties:

1. always returns a list
2. input date ranges are contained within output date ranges
3. output date ranges are sorted by start date
4. output date ranges do not overlap
5. adjacent date ranges are merged
6. min and max dates in input and output match
7. gaps are preserved

We saw how to write and combine custom generators, how to write recursive generators and how to write generators that are more specific to certain edge cases. We also saw how we can come up with better properties by thinking about how to trick a test suite with faulty implementations.

If you find better, cleaner, more readable or more concise solutions or if you find another faulty implementation that does not fail the tests, let me know.
