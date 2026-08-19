defmodule NoNoncense.Errors.DisabledError do
  @moduledoc """
  Exception raised when a NoNoncense instance is called while disabled,
  for example because its machine ID lease was lost.
  """
  defexception [:message]

  @impl true
  def exception(name), do: %__MODULE__{message: "instance #{name} is disabled"}
end
