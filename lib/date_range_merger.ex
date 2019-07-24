defmodule DateRangeMerger do
  @moduledoc """
  Documentation for DateRangeMerger.
  """

  @doc """
  Takes a list of date ranges and returns a list of date ranges sorted by start
  date that does not contain any overlapping date ranges.
  """
  @spec merge([{Date.t(), Date.t()}]) :: [{Date.t(), Date.t()}]
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
    if Date.diff(next_start_date, previous_end_date) < 2 do
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
end
