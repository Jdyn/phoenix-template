defmodule Nimble.Auth.OAuth do
  @moduledoc false
  alias Nimble.User

  @spec request(String.t()) :: {:ok, %{url: String.t(), session_params: map()}} | {:not_found, String.t()}
  def request(provider) do
    config = config!(provider)
    config[:strategy].authorize_url(config)
  end

  @spec callback(String.t(), map(), map()) :: {:ok, %{user: %User{}, token: String.t()}} | {:not_found, String.t()}
  def callback(provider, params, session_params \\ %{}) do
    config = config!(provider)
    config |> Keyword.put(:session_params, session_params) |> config[:strategy].callback(params)
  end

  @spec config!(String.t()) :: list | nil
  defp config!(provider) do
    config =
      Application.get_env(:nimble, :strategies)[String.to_existing_atom(provider)] ||
        raise "No provider configuration for #{provider}"

    Keyword.put(config, :redirect_uri, build_uri(provider))
  end

  defp build_uri(provider) do
    base_uri = System.fetch_env!("OAUTH_REDIRECT_URI")
    "#{base_uri}/#{provider}"
  end
end
