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

  defp date_range do
    gen all start_date <- date(),
            max_difference = Date.diff(~D[2050-12-31], start_date),
            days_between <- integer(0..max_difference) do
      {start_date, Date.add(start_date, days_between)}
    end
  end

  defp adjacent_date_ranges do
    gen all {start_date_a, end_date_a} <- date_range(),
            start_date_b = Date.add(end_date_a, 1),
            max_difference = Date.diff(~D[2050-12-31], start_date_b),
            days_between <- integer(0..max_difference),
            end_date_b = Date.add(start_date_a, days_between) do
      Enum.shuffle([{start_date_a, end_date_a}, {start_date_b, end_date_b}])
    end
  end

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

  property "always returns a list" do
    check all date_ranges <- list_of(date_range()) do
      assert is_list(merge(date_ranges))
    end
  end

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

  property "output date ranges do not overlap" do
    check all date_ranges <- list_of(date_range()) do
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
end
