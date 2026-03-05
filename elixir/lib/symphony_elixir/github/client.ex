defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  GitHub Projects v2 GraphQL + Issues API client.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 50

  @project_items_query """
  query SymphonyGithubProjectItems($owner: String!, $projectNumber: Int!, $first: Int!, $after: String) {
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        url
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options {
              id
              name
            }
          }
        }
        items(first: $first, after: $after) {
          nodes {
            id
            content {
              __typename
              ... on Issue {
                number
                title
                body
                url
                state
                createdAt
                updatedAt
                repository {
                  nameWithOwner
                }
                labels(first: 50) {
                  nodes {
                    name
                  }
                }
              }
            }
            fieldValueByName(name: "Status") {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        url
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options {
              id
              name
            }
          }
        }
        items(first: $first, after: $after) {
          nodes {
            id
            content {
              __typename
              ... on Issue {
                number
                title
                body
                url
                state
                createdAt
                updatedAt
                repository {
                  nameWithOwner
                }
                labels(first: 50) {
                  nodes {
                    name
                  }
                }
              }
            }
            fieldValueByName(name: "Status") {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @issue_for_project_query """
  query SymphonyGithubIssueProjectItem($repoOwner: String!, $repoName: String!, $issueNumber: Int!) {
    repository(owner: $repoOwner, name: $repoName) {
      issue(number: $issueNumber) {
        number
        title
        body
        url
        state
        createdAt
        updatedAt
        repository {
          nameWithOwner
        }
        labels(first: 50) {
          nodes {
            name
          }
        }
        projectItems(first: 50) {
          nodes {
            id
            project {
              id
            }
            fieldValueByName(name: "Status") {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
              }
            }
          }
        }
      }
    }
  }
  """

  @update_project_item_status_mutation """
  mutation SymphonyGithubUpdateProjectItemStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    active_state_set = state_set(Config.linear_active_states())

    with {:ok, %{items: items}} <- fetch_all_project_items(),
         {:ok, %{owner: repo_owner, name: repo_name}} <- repository_parts() do
      issues =
        items
        |> Enum.filter(&issue_for_repository?(&1, repo_owner, repo_name))
        |> Enum.map(&normalize_project_item/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn %Issue{state: state} -> MapSet.member?(active_state_set, normalize_state(state)) end)

      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    wanted_states = state_set(state_names)

    with {:ok, %{items: items}} <- fetch_all_project_items(),
         {:ok, %{owner: repo_owner, name: repo_name}} <- repository_parts() do
      issues =
        items
        |> Enum.filter(&issue_for_repository?(&1, repo_owner, repo_name))
        |> Enum.map(&normalize_project_item/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn %Issue{state: state} -> MapSet.member?(wanted_states, normalize_state(state)) end)

      {:ok, issues}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, metadata} <- fetch_project_metadata(),
         {:ok, %{owner: repo_owner, name: repo_name}} <- repository_parts() do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case fetch_issue_by_id(issue_id, repo_owner, repo_name, metadata.project_id) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> then(fn
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end)
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, %{owner: repo_owner, name: repo_name}} <- repository_parts(),
         {:ok, response} <- post_issue_comment(repo_owner, repo_name, issue_number, body),
         true <- response.status in [200, 201] do
      :ok
    else
      false -> {:error, :github_comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, metadata} <- fetch_project_metadata(),
         {:ok, %{owner: repo_owner, name: repo_name}} <- repository_parts(),
         {:ok, project_item} <- fetch_issue_project_item(repo_owner, repo_name, issue_number, metadata.project_id),
         {:ok, status_option_id} <- status_option_id_for_state(metadata.status_options, state_name),
         {:ok, update_body} <-
           graphql(@update_project_item_status_mutation, %{
             projectId: metadata.project_id,
             itemId: project_item.item_id,
             fieldId: metadata.status_field_id,
             optionId: status_option_id
           }),
         :ok <- ensure_project_item_update_success(update_body),
         {:ok, _response} <-
           maybe_update_issue_open_state(repo_owner, repo_name, issue_number, state_name) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_update_failed}
    end
  end

  defp fetch_issue_by_id(issue_id, repo_owner, repo_name, project_id) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, body} <-
           graphql(@issue_for_project_query, %{
             repoOwner: repo_owner,
             repoName: repo_name,
             issueNumber: issue_number
           }) do
      decode_issue_query_result(body, project_id)
    end
  end

  defp fetch_issue_project_item(repo_owner, repo_name, issue_number, project_id) do
    with {:ok, body} <-
           graphql(@issue_for_project_query, %{
             repoOwner: repo_owner,
             repoName: repo_name,
             issueNumber: issue_number
           }),
         {:ok, issue} <- decode_issue_graphql_issue(body),
         item when is_map(item) <- find_issue_project_item(issue, project_id),
         item_id when is_binary(item_id) <- item["id"] do
      {:ok, %{item_id: item_id, status_name: project_item_status_name(item)}}
    else
      nil -> {:error, :github_project_item_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_project_item_not_found}
    end
  end

  defp fetch_all_project_items do
    fetch_project_items_page(nil, [])
  end

  defp fetch_project_items_page(after_cursor, acc_items) do
    with {:ok, owner} <- project_owner(),
         {:ok, project_number} <- project_number(),
         {:ok, body} <-
           graphql(@project_items_query, %{
             owner: owner,
             projectNumber: project_number,
             first: @page_size,
             after: after_cursor
           }),
         {:ok, project} <- decode_project(body),
         {:ok, status_field_id, status_options} <- decode_status_field(project),
         {:ok, items, page_info} <- decode_project_items(project) do
      metadata = %{
        project_id: project["id"],
        project_url: project["url"],
        status_field_id: status_field_id,
        status_options: status_options
      }

      updated_acc = acc_items ++ items

      case page_info do
        %{has_next_page: true, end_cursor: end_cursor} when is_binary(end_cursor) and end_cursor != "" ->
          fetch_project_items_page(end_cursor, updated_acc)

        %{has_next_page: true} ->
          {:error, :github_missing_end_cursor}

        _ ->
          {:ok, Map.put(metadata, :items, updated_acc)}
      end
    end
  end

  defp fetch_project_metadata do
    with {:ok, owner} <- project_owner(),
         {:ok, project_number} <- project_number(),
         {:ok, body} <-
           graphql(@project_items_query, %{
             owner: owner,
             projectNumber: project_number,
             first: 1,
             after: nil
           }),
         {:ok, project} <- decode_project(body),
         {:ok, status_field_id, status_options} <- decode_status_field(project),
         project_id when is_binary(project_id) <- project["id"] do
      {:ok,
       %{
         project_id: project_id,
         project_url: project["url"],
         status_field_id: status_field_id,
         status_options: status_options
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_project_not_found}
    end
  end

  defp decode_project(body) when is_map(body) do
    cond do
      is_map(get_in(body, ["data", "user", "projectV2"])) ->
        {:ok, get_in(body, ["data", "user", "projectV2"])}

      is_map(get_in(body, ["data", "organization", "projectV2"])) ->
        {:ok, get_in(body, ["data", "organization", "projectV2"])}

      is_list(body["errors"]) ->
        {:error, {:github_graphql_errors, body["errors"]}}

      true ->
        {:error, :github_project_not_found}
    end
  end

  defp decode_status_field(project) when is_map(project) do
    field = project["field"]

    with true <- is_map(field),
         field_id when is_binary(field_id) <- field["id"] do
      status_options =
        field
        |> Map.get("options", [])
        |> Enum.flat_map(fn
          %{"id" => option_id, "name" => option_name}
          when is_binary(option_id) and is_binary(option_name) ->
            [{normalize_state(option_name), option_id}]

          _ ->
            []
        end)
        |> Map.new()

      {:ok, field_id, status_options}
    else
      _ -> {:error, :github_missing_status_field}
    end
  end

  defp decode_project_items(project) when is_map(project) do
    items = get_in(project, ["items", "nodes"])
    page_info = get_in(project, ["items", "pageInfo"])

    cond do
      is_list(items) and is_map(page_info) ->
        {:ok, items,
         %{
           has_next_page: page_info["hasNextPage"] == true,
           end_cursor: page_info["endCursor"]
         }}

      true ->
        {:error, :github_unknown_payload}
    end
  end

  defp ensure_project_item_update_success(%{"errors" => errors}) when is_list(errors) do
    {:error, {:github_graphql_errors, errors}}
  end

  defp ensure_project_item_update_success(body) when is_map(body) do
    case get_in(body, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      value when is_binary(value) -> :ok
      _ -> {:error, :github_issue_update_failed}
    end
  end

  defp ensure_project_item_update_success(_), do: {:error, :github_issue_update_failed}

  defp decode_issue_query_result(body, project_id) do
    with {:ok, issue} <- decode_issue_graphql_issue(body) do
      case normalize_issue_for_project(issue, project_id) do
        nil -> {:ok, nil}
        normalized -> {:ok, normalized}
      end
    end
  end

  defp decode_issue_graphql_issue(%{"data" => %{"repository" => %{"issue" => issue}}}) when is_map(issue) do
    {:ok, issue}
  end

  defp decode_issue_graphql_issue(%{"data" => %{"repository" => %{"issue" => nil}}}), do: {:ok, nil}

  defp decode_issue_graphql_issue(%{"errors" => errors}) when is_list(errors) do
    {:error, {:github_graphql_errors, errors}}
  end

  defp decode_issue_graphql_issue(_), do: {:error, :github_unknown_payload}

  defp normalize_project_item(item) when is_map(item) do
    case item["content"] do
      %{"__typename" => "Issue"} = issue ->
        %Issue{
          id: to_string(issue["number"]),
          identifier: "GH-#{issue["number"]}",
          title: issue["title"],
          description: issue["body"],
          priority: nil,
          state: project_item_status_name(item),
          branch_name: nil,
          url: issue["url"],
          assignee_id: nil,
          blocked_by: [],
          labels: normalize_labels(get_in(issue, ["labels", "nodes"])),
          assigned_to_worker: true,
          created_at: parse_datetime(issue["createdAt"]),
          updated_at: parse_datetime(issue["updatedAt"])
        }

      _ ->
        nil
    end
  end

  defp normalize_project_item(_), do: nil

  defp normalize_issue_for_project(nil, _project_id), do: nil

  defp normalize_issue_for_project(issue, project_id) when is_map(issue) and is_binary(project_id) do
    case find_issue_project_item(issue, project_id) do
      nil ->
        nil

      project_item ->
        %Issue{
          id: to_string(issue["number"]),
          identifier: "GH-#{issue["number"]}",
          title: issue["title"],
          description: issue["body"],
          priority: nil,
          state: project_item_status_name(project_item),
          branch_name: nil,
          url: issue["url"],
          assignee_id: nil,
          blocked_by: [],
          labels: normalize_labels(get_in(issue, ["labels", "nodes"])),
          assigned_to_worker: true,
          created_at: parse_datetime(issue["createdAt"]),
          updated_at: parse_datetime(issue["updatedAt"])
        }
    end
  end

  defp find_issue_project_item(issue, project_id) when is_map(issue) and is_binary(project_id) do
    issue
    |> get_in(["projectItems", "nodes"])
    |> List.wrap()
    |> Enum.find(fn
      %{"project" => %{"id" => ^project_id}} -> true
      _ -> false
    end)
  end

  defp find_issue_project_item(_issue, _project_id), do: nil

  defp project_item_status_name(project_item) when is_map(project_item) do
    case get_in(project_item, ["fieldValueByName", "name"]) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp issue_for_repository?(project_item, repo_owner, repo_name)
       when is_map(project_item) and is_binary(repo_owner) and is_binary(repo_name) do
    expected = String.downcase("#{repo_owner}/#{repo_name}")

    case get_in(project_item, ["content", "repository", "nameWithOwner"]) do
      value when is_binary(value) -> String.downcase(value) == expected
      _ -> false
    end
  end

  defp issue_for_repository?(_, _, _), do: false

  defp state_set(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_), do: ""

  defp status_option_id_for_state(status_options, state_name)
       when is_map(status_options) and is_binary(state_name) do
    case Map.get(status_options, normalize_state(state_name)) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :github_state_option_not_found}
    end
  end

  defp maybe_update_issue_open_state(repo_owner, repo_name, issue_number, state_name)
       when is_binary(state_name) do
    terminal_states = state_set(Config.linear_terminal_states())
    desired_state = if MapSet.member?(terminal_states, normalize_state(state_name)), do: "closed", else: "open"

    with {:ok, response} <- patch_issue_state(repo_owner, repo_name, issue_number, desired_state),
         true <- response.status in [200, 201] do
      {:ok, response}
    else
      false -> {:error, :github_issue_state_patch_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_state_patch_failed}
    end
  end

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    issue_id
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_issue_number(_), do: {:error, :invalid_github_issue_id}

  defp project_owner do
    case Config.github_project_owner() do
      owner when is_binary(owner) ->
        owner
        |> String.trim()
        |> then(fn
          "" -> {:error, :missing_github_project_owner}
          trimmed -> {:ok, trimmed}
        end)

      _ ->
        {:error, :missing_github_project_owner}
    end
  end

  defp project_number do
    case Config.github_project_number() do
      number when is_integer(number) and number > 0 -> {:ok, number}
      _ -> {:error, :missing_github_project_number}
    end
  end

  defp repository_parts do
    case Config.github_repository() do
      repository when is_binary(repository) ->
        repository
        |> String.trim()
        |> String.split("/", parts: 2)
        |> case do
          [owner, name] ->
            owner = String.trim(owner)
            name = String.trim(name)

            if owner != "" and name != "" do
              {:ok, %{owner: owner, name: name}}
            else
              {:error, :invalid_github_repository}
            end

          _ ->
            {:error, :invalid_github_repository}
        end

      _ ->
        {:error, :missing_github_repository}
    end
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [String.downcase(name)]
      _ -> []
    end)
  end

  defp normalize_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp post_issue_comment(repo_owner, repo_name, issue_number, body) do
    with {:ok, headers} <- github_rest_headers() do
      Req.post(github_issue_url(repo_owner, repo_name, issue_number) <> "/comments",
        headers: headers,
        json: %{body: body},
        connect_options: [timeout: 30_000]
      )
    end
  end

  defp patch_issue_state(repo_owner, repo_name, issue_number, desired_state) do
    with {:ok, headers} <- github_rest_headers() do
      Req.request(
        method: :patch,
        url: github_issue_url(repo_owner, repo_name, issue_number),
        headers: headers,
        json: %{state: desired_state},
        connect_options: [timeout: 30_000]
      )
    end
  end

  defp github_issue_url(repo_owner, repo_name, issue_number) do
    "https://api.github.com/repos/#{repo_owner}/#{repo_name}/issues/#{issue_number}"
  end

  @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}) when is_binary(query) and is_map(variables) do
    payload = %{"query" => query, "variables" => variables}

    with {:ok, headers} <- github_graphql_headers(),
         {:ok, %{status: 200, body: body}} <-
           Req.post(Config.github_endpoint(),
             headers: headers,
             json: payload,
             connect_options: [timeout: 30_000]
           ) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error("GitHub GraphQL request failed status=#{response.status}")
        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp github_graphql_headers do
    case Config.github_api_token() do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"}
         ]}
    end
  end

  defp github_rest_headers do
    case Config.github_api_token() do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"},
           {"Content-Type", "application/json"}
         ]}
    end
  end
end
