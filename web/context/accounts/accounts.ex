defmodule Nimble.Accounts do
  @moduledoc """
  Defines a context for managing user accounts.
  """
  alias Nimble.Accounts
  alias Nimble.Auth.OAuth
  alias Nimble.Repo
  alias Nimble.User
  alias Nimble.UserNotifier
  alias Nimble.Users
  alias Nimble.UserToken

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    with %User{} = user <- Users.get_by_email_and_password(email, password) do
      {:ok, user}
    else
      _ ->
        {:unauthorized, "Email or Password is incorrect."}
    end
  end

  def authenticate(provider, %{} = params) when is_binary(provider) and is_map(params) do
    case OAuth.callback(provider, params) do
      {:ok, %{user: open_user, token: _token}} ->
        with user = %User{} <- Users.get_by_email(open_user["email"]),
             false <- is_nil(user.confirmed_at) do
          {:ok, user}
        else
          true ->
            {:not_found, "Confirm your email before signing in with #{provider}."}

          nil ->
            register(open_user, :oauth)
        end

      error ->
        error
    end
  end

  @doc """
  Retrieve a User by a given signed session token.
  """
  def find_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Registers a user.

  ## Examples

      iex> register(%{field: value})
      {:ok, %User{}}

      iex> register(%{field: bad_value})
      {:error, %Ecto.Changeset{}}
  """
  def register(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert()
  end

  def register(attrs, :oauth) do
    oauth_user = user_from_oauth(attrs)
    %User{} |> User.oauth_registration_changeset(oauth_user) |> Repo.insert()
  end

  defp user_from_oauth(attrs) do
    %{
      email: attrs["email"],
      email_verified: attrs["email_verified"],
      first_name: attrs["given_name"],
      last_name: attrs["family_name"],
      avatar: attrs["picture"]
    }
  end

  @doc """
  Delivers the confirmation email instructions to the given user.

  ## Examples
      iex> deliver_user_confirmation_instructions(user)
      {:ok, encoded_token}
      iex> deliver_user_confirmation_instructions(confirmed_user)
      {:not_found, "Your email has already been confirmed."}
  """
  def deliver_user_confirmation_instructions(%User{} = user) do
    if user.confirmed_at do
      {:error, "Your email has already been confirmed."}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, encoded_token)
      {:ok, encoded_token}
    end
  end

  @doc """
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email)
      :ok

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_user_update_email_instructions(user, encoded_token)
    {:ok, encoded_token}
  end

  @doc """
  Generates a session token.

  ## Examples
      iex> create_session_token(user)
      %UserToken{ ... }
  """
  def create_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Deletes the current session token.

  ## Examples
      iex> delete_session_token(token)
      :ok
  """
  def delete_session_token(token) do
    Repo.delete_all(Accounts.Query.token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes the current session token IF the given token is not the current session token.

  ## Examples
      iex> delete_session_token(user, tracking_id, current_token)
      :ok

      iex> delete_session_token(user, tracking_id_of_current_token, current_token)
      {:not_found, "Cannot delete the current session."}
  """
  def delete_session_token(%User{} = user, tracking_id, current_token) do
    with %{token: token} <- find_session(user, tracking_id: tracking_id),
         true <- token != current_token,
         _ <- Repo.delete_all(Accounts.Query.user_and_tracking_id_query(user, tracking_id)) do
      :ok
    else
      false ->
        {:not_found, "Cannot delete the current session."}

      nil ->
        {:unauthorized, "Session does not exist."}
    end
  end

  @doc """
  Deletes all session tokens except current session.
  """
  def delete_session_tokens(%User{} = user, token) do
    Repo.delete_all(Accounts.Query.user_and_session_tokens(user, token))
    find_session(user, token: token)
  end

  @doc """
  Returns all tokens for the given user.
  """
  def find_all(user), do: Repo.all(Accounts.Query.user_and_contexts_query(user, ["all"]))
  def find_all_sessions(user), do: Repo.all(Accounts.Query.user_and_contexts_query(user, ["session"]))

  def find_session(user, tracking_id: id) do
    Repo.one(Accounts.Query.user_and_tracking_id_query(user, id))
  end

  def find_session(%User{} = user, token: token) do
    Repo.one(Accounts.Query.user_and_token_query(user, token))
  end
end
