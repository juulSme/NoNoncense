defmodule NoNoncense.Errors.UninitializedError do
  @moduledoc """
  Exception raised when a NoNoncense instance is not initialized.
  """
  defexception [:message]

  @impl true
  def exception(name), do: %__MODULE__{message: "instance #{name} is not initialized"}
end
