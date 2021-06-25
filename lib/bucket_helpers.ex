defmodule MavuBuckets.BkHelpers do
  @moduledoc """
    generic helpers by Manfred Wuits
  """

  defmacro pipe_when(left, condition, fun) do
    quote do
      left = unquote(left)

      if unquote(condition),
        do: left |> unquote(fun),
        else: left
    end
  end

  def if_empty(val, default_val) do
    if present?(val) do
      val
    else
      default_val
    end
  end

  def if_nil(val, default_val) do
    if is_nil(val) do
      default_val
    else
      val
    end
  end

  def present?(term) do
    !Blankable.blank?(term)
  end

  def empty?(term) do
    Blankable.blank?(term)
  end

  require Logger

  def log(data, msg \\ "", level \\ :debug) do
    Logger.log(
      level,
      msg <> " " <> inspect(data, printable_limit: :infinity, limit: 50, pretty: true)
    )

    data
  end
end
