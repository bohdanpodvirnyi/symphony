defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_github_endpoint "https://api.github.com/graphql"
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow, do: Workflow.current()

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    settings!().tracker.kind
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    tracker_endpoint(settings!(), "linear", @default_linear_endpoint)
  end

  @spec github_endpoint() :: String.t()
  def github_endpoint do
    tracker_endpoint(settings!(), "github", @default_github_endpoint)
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    tracker_api_key(settings!(), "linear", "LINEAR_API_KEY")
  end

  @spec github_api_token() :: String.t() | nil
  def github_api_token do
    tracker_api_key(settings!(), "github", "GITHUB_TOKEN")
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    settings!().tracker.project_slug
  end

  @spec github_repository() :: String.t() | nil
  def github_repository do
    settings!().tracker.repository
  end

  @spec github_project_owner() :: String.t() | nil
  def github_project_owner do
    settings!().tracker.project_owner
  end

  @spec github_project_number() :: pos_integer() | nil
  def github_project_number do
    settings!().tracker.project_number
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    settings!().tracker.assignee
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    settings!().tracker.active_states
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    settings!().tracker.terminal_states
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    settings!().polling.interval_ms
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    settings!().workspace.root
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = settings!().hooks

    %{
      after_create: hooks.after_create,
      before_run: hooks.before_run,
      after_run: hooks.after_run,
      before_remove: hooks.before_remove,
      timeout_ms: hooks.timeout_ms
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    settings!().hooks.timeout_ms
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    settings!().agent.max_concurrent_agents
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    settings!().agent.max_retry_backoff_ms
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    settings!().agent.max_turns
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_command() :: String.t()
  def codex_command do
    settings!().codex.command
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    settings!().codex.turn_timeout_ms
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms do
    settings!().codex.read_timeout_ms
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    settings!().codex.stall_timeout_ms
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    settings!().observability.dashboard_enabled
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    settings!().observability.refresh_ms
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    settings!().observability.render_interval_ms
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    settings!().server.host
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "github", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_github_api_token}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.repository) ->
        {:error, :missing_github_repository}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.project_owner) ->
        {:error, :missing_github_project_owner}

      settings.tracker.kind == "github" and not is_integer(settings.tracker.project_number) ->
        {:error, :missing_github_project_number}

      true ->
        :ok
    end
  end

  defp tracker_endpoint(settings, expected_kind, default_endpoint) do
    endpoint = settings.tracker.endpoint

    cond do
      settings.tracker.kind == expected_kind and is_binary(endpoint) and String.trim(endpoint) != "" ->
        normalize_tracker_endpoint(expected_kind, String.trim(endpoint), default_endpoint)

      true ->
        default_endpoint
    end
  end

  defp normalize_tracker_endpoint("github", @default_linear_endpoint, _default_endpoint),
    do: @default_github_endpoint

  defp normalize_tracker_endpoint(kind, @default_github_endpoint, _default_endpoint) when kind != "github",
    do: @default_linear_endpoint

  defp normalize_tracker_endpoint(_kind, endpoint, _default_endpoint), do: endpoint

  defp tracker_api_key(settings, expected_kind, env_var) do
    cond do
      settings.tracker.kind == expected_kind ->
        normalize_secret_value(settings.tracker.api_key)

      true ->
        normalize_secret_value(System.get_env(env_var))
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
