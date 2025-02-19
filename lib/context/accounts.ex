defmodule Nimble.Accounts do
  @moduledoc """
  Defines a context for managing user accounts.
  """
  use Nimble.Web, :context

  alias Nimble.Accounts.Query
  alias Nimble.Auth.OAuth
  alias Nimble.Repo
  alias Nimble.User
  alias Nimble.UserNotifier
  alias Nimble.UserToken

  def authenticate(identifier, password) when is_binary(identifier) and is_binary(password) do
    case get_by_identifier_and_password(identifier, password) do
      %User{} = user -> {:ok, user}
      _ -> {:unauthorized, "Email or Password is incorrect."}
    end
  end

  def authenticate(provider, params) when is_binary(provider) and is_map(params) do
    session_params = %{state: Map.get(params, "state")}

    with {:ok, %{user: open_user, token: _token}} <- OAuth.callback(provider, params, session_params) do
      case get_by_email(open_user["email"]) do
        nil -> register(open_user, :oauth)
        %User{confirmed_at: nil} -> {:unauthorized, "Please confirm your email with #{provider}."}
        %User{} = user -> {:ok, user}
      end
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
  Gets the user by reset password token.

  ## Examples

    iex> get_user_by_reset_password_token("validtoken")
    %User{}

    iex> get_user_by_reset_password_token("invalidtoken")
    nil
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      {:ok, user}
    else
      _ -> {:error, "Reset password link is invalid or it has expired."}
    end
  end

  @doc """
  Delivers the confirmation email instructions to the given user.

  ## Examples
      iex> deliver_user_confirmation_instructions(user)
      {:ok, encoded_token}
      iex> deliver_user_confirmation_instructions(confirmed_user)
      {:not_found, "Your email has already been confirmed."}
  """
  def deliver_email_confirmation_instructions(%User{} = user) do
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
      {:ok, encoded_token}

  """
  def deliver_email_update_instructions(%User{} = user, current_email) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_user_update_email_instructions(user, encoded_token)
    {:ok, encoded_token}
  end

  @doc """
  Emulates that the e-mail will change without actually changing
  it in the database.

  ## Examples

      iex> prepare_email_update(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> prepare_email_update(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}
  """
  def prepare_email_update(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  - Updates the user e-mail in token.
  - If the token matches, the user email is updated and the token is deleted.
  - The `confirmed_at` date is also updated to the current time.
  """
  def update_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(email_multi(user, email, context)) do
      :ok
    else
      _ -> {:not_found, "Invalid link. Please generate a new one."}
    end
  end

  defp email_multi(user, email, context) do
    changeset = user |> User.email_changeset(%{email: email}) |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, Query.user_and_contexts_query(user, [context]))
  end

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_password_reset_instructions(user)
      {:ok, encoded_token}

  """
  def deliver_password_reset_instructions(%User{} = user) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_password_reset_instructions(user, encoded_token)
    {:ok, encoded_token}
  end

  @doc """
  Resets the user password.

  ## Examples

    iex> reset_password(user, %{password: "new long password", password_confirmation: "new long password"})
    {:ok, %User{}}

    iex> reset_password(user, %{password: "valid", password_confirmation: "not the same"})
    {:error, %Ecto.Changeset{}}

  """
  def reset_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, Query.user_and_contexts_query(user, ["all"]))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_by_identifier_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_by_identifier_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_by_identifier_and_password(identifier, password) when is_binary(identifier) and is_binary(password) do
    user = get_by_identifier(identifier)
    if User.valid_password?(user, password), do: user
  end

  def get_by_identifier(identifier) do
    Repo.one(Query.user_from_identifier_query(identifier))
  end

  @doc """
  Gets a user by email.

  ## Examples

    iex> get_user_by_email("foo@example.com")
    %User{}

    iex> get_user_by_email("unknown@example.com")
    nil

  """
  def get_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}
  """
  def update_password(user, password, attrs) do
    user
    |> update_password_multi(password, attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  defp update_password_multi(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, Query.user_and_contexts_query(user, ["all"]))
  end

  ## Confirmation

  @doc """
  Confirms a user by the given token.
  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  def confirm_email(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_email_multi(user)) do
      {:ok, user}
    else
      _ ->
        {:not_found, "Your link is either invalid, or your email has already been confirmed."}
    end
  end

  defp confirm_email_multi(%User{} = user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, Query.user_and_contexts_query(user, ["confirm"]))
  end
end
