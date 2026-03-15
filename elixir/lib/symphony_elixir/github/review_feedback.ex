defmodule SymphonyElixir.Github.ReviewFeedback do
  @moduledoc """
  Extracts actionable PR review feedback linked to a GitHub issue and formats it
  for the agent prompt.
  """

  @spec has_actionable_feedback?(map() | nil) :: boolean()
  def has_actionable_feedback?(issue), do: has_actionable_feedback?(issue, nil)

  @spec has_actionable_feedback?(map() | nil, DateTime.t() | nil) :: boolean()
  def has_actionable_feedback?(issue, issue_updated_at) when is_map(issue) do
    issue
    |> normalize_pull_requests(issue_updated_at)
    |> Enum.any?(fn pull_request ->
      pull_request.active_threads != [] or
        pull_request.fresh_reviews != [] or
        pull_request.fresh_comments != []
    end)
  end

  def has_actionable_feedback?(_issue, _issue_updated_at), do: false

  @spec build_prompt_context(map() | nil) :: String.t() | nil
  def build_prompt_context(issue), do: build_prompt_context(issue, nil)

  @spec build_prompt_context(map() | nil, DateTime.t() | nil) :: String.t() | nil
  def build_prompt_context(issue, issue_updated_at) when is_map(issue) do
    pull_requests =
      issue
      |> normalize_pull_requests(issue_updated_at)
      |> Enum.filter(fn pull_request ->
        pull_request.active_threads != [] or
          pull_request.fresh_reviews != [] or
          pull_request.fresh_comments != []
      end)

    case pull_requests do
      [] ->
        nil

      _ ->
        [
          "Open PR review feedback requires batch handling.",
          "Resolve every active item below in one pass before finishing; do not focus only on the newest comment.",
          Enum.map_join(pull_requests, "\n\n", &format_pull_request/1)
        ]
        |> Enum.join("\n")
        |> String.trim()
    end
  end

  def build_prompt_context(_issue, _issue_updated_at), do: nil

  defp normalize_pull_requests(issue, issue_updated_at) do
    issue
    |> linked_pull_requests()
    |> Enum.uniq_by(& &1["number"])
    |> Enum.filter(&(normalize_text(&1["state"]) == "OPEN"))
    |> Enum.map(&normalize_pull_request(&1, issue_updated_at))
  end

  defp linked_pull_requests(issue) when is_map(issue) do
    issue
    |> get_in(["timelineItems", "nodes"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"source" => %{"__typename" => "PullRequest"} = pull_request} -> [pull_request]
      _ -> []
    end)
  end

  defp normalize_pull_request(pull_request, issue_updated_at) do
    review_decision = normalize_text(pull_request["reviewDecision"])

    %{
      number: pull_request["number"],
      title: compact_text(pull_request["title"]),
      url: compact_text(pull_request["url"]),
      review_decision: review_decision,
      decision_changes_requested?: review_decision == "CHANGES_REQUESTED",
      active_threads: normalize_active_threads(pull_request),
      fresh_reviews: normalize_fresh_reviews(pull_request, issue_updated_at),
      fresh_comments: normalize_fresh_comments(pull_request, issue_updated_at)
    }
  end

  defp normalize_active_threads(pull_request) when is_map(pull_request) do
    pull_request
    |> get_in(["reviewThreads", "nodes"])
    |> List.wrap()
    |> Enum.filter(&active_thread?/1)
    |> Enum.map(&normalize_thread/1)
    |> Enum.reject(&(&1.comments == []))
  end

  defp normalize_fresh_reviews(pull_request, issue_updated_at) when is_map(pull_request) do
    pull_request
    |> get_in(["reviews", "nodes"])
    |> List.wrap()
    |> Enum.filter(fn review ->
      non_empty_body?(review["body"]) and
        (updated_after_issue?(review["submittedAt"], issue_updated_at) or issue_updated_at == nil)
    end)
    |> Enum.map(fn review ->
      %{
        author: author_login(review),
        state: compact_text(review["state"]),
        body: compact_text(review["body"]),
        url: compact_text(review["url"])
      }
    end)
  end

  defp normalize_fresh_comments(pull_request, issue_updated_at) when is_map(pull_request) do
    pull_request
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.filter(fn comment ->
      non_empty_body?(comment["body"]) and
        (updated_after_issue?(comment["updatedAt"], issue_updated_at) or issue_updated_at == nil)
    end)
    |> Enum.map(fn comment ->
      %{
        author: author_login(comment),
        body: compact_text(comment["body"]),
        url: compact_text(comment["url"])
      }
    end)
  end

  defp active_thread?(%{"isResolved" => false, "isOutdated" => false}), do: true
  defp active_thread?(%{"isResolved" => false, "isOutdated" => true}), do: false
  defp active_thread?(%{"isResolved" => false}), do: true
  defp active_thread?(_thread), do: false

  defp normalize_thread(thread) when is_map(thread) do
    comments =
      thread
      |> get_in(["comments", "nodes"])
      |> List.wrap()
      |> Enum.filter(&non_empty_body?(&1["body"]))
      |> Enum.map(fn comment ->
        %{
          author: author_login(comment),
          body: compact_text(comment["body"]),
          url: compact_text(comment["url"])
        }
      end)

    %{
      path: compact_text(thread["path"]),
      line: thread["line"],
      comments: comments,
      url: thread_url(thread, comments)
    }
  end

  defp format_pull_request(pull_request) do
    sections = [
      format_pull_request_header(pull_request),
      format_active_threads(pull_request.active_threads),
      format_reviews("Fresh review summaries/comments since last issue update", pull_request.fresh_reviews),
      format_reviews("Fresh top-level PR comments since last issue update", pull_request.fresh_comments)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_pull_request_header(pull_request) do
    title_suffix =
      case pull_request.title do
        nil -> ""
        title -> ": #{title}"
      end

    decision_suffix =
      case pull_request.review_decision do
        nil -> ""
        decision -> " [decision=#{decision}]"
      end

    [
      "PR ##{pull_request.number}#{title_suffix}#{decision_suffix}",
      pull_request.url
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_active_threads([]), do: nil

  defp format_active_threads(threads) do
    [
      "Active review threads:",
      Enum.with_index(threads, 1)
      |> Enum.map_join("\n", fn {thread, index} ->
        [
          "#{index}. #{format_thread_location(thread)}",
          Enum.map_join(thread.comments, "\n", &format_thread_comment/1),
          format_optional_url(thread.url)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)
    ]
    |> Enum.join("\n")
  end

  defp format_reviews(_heading, []), do: nil

  defp format_reviews(heading, entries) do
    [
      heading <> ":",
      Enum.with_index(entries, 1)
      |> Enum.map_join("\n", fn {entry, index} ->
        prefix =
          ["#{index}.", entry[:author], entry[:state]]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(" ")

        [
          prefix,
          indent_block(entry.body, 2),
          format_optional_url(entry.url)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)
    ]
    |> Enum.join("\n")
  end

  defp format_thread_location(thread) do
    location =
      case {thread.path, thread.line} do
        {nil, nil} -> "thread"
        {path, nil} -> path
        {nil, line} -> "line #{line}"
        {path, line} -> "#{path}:#{line}"
      end

    "#{location}"
  end

  defp format_thread_comment(comment) do
    author = if comment.author, do: "- #{comment.author}:", else: "- comment:"
    author <> "\n" <> indent_block(comment.body, 4)
  end

  defp format_optional_url(nil), do: nil
  defp format_optional_url(url), do: "  URL: #{url}"

  defp thread_url(_thread, [%{url: url} | _rest]) when is_binary(url), do: url
  defp thread_url(_thread, _comments), do: nil

  defp indent_block(text, spaces) when is_binary(text) and is_integer(spaces) and spaces >= 0 do
    indent = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> indent <> line end)
  end

  defp compact_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp compact_text(_value), do: nil

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(_value), do: nil

  defp non_empty_body?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_body?(_value), do: false

  defp author_login(%{"author" => %{"login" => login}}) when is_binary(login), do: login
  defp author_login(_payload), do: nil

  defp updated_after_issue?(timestamp, %DateTime{} = issue_updated_at) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, %DateTime{} = datetime, _offset} ->
        DateTime.compare(datetime, issue_updated_at) in [:gt, :eq]

      _ ->
        false
    end
  end

  defp updated_after_issue?(timestamp, nil) when is_binary(timestamp), do: true
  defp updated_after_issue?(_timestamp, _issue_updated_at), do: false
end
