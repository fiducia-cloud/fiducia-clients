defmodule FiduciaClient do
  @enforce_keys [:base_url]
  defstruct [:base_url, :bearer_token]
  def new(base_url, bearer_token \ nil), do: %__MODULE__{base_url: base_url, bearer_token: bearer_token}
end
