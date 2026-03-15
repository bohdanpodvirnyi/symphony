defmodule SymphonyElixir.Github.ReviewFeedbackTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Github.ReviewFeedback

  test "build_prompt_context includes every active thread comment plus fresh review notes" do
    issue_updated_at = DateTime.from_naive!(~N[2026-03-14 12:00:00], "Etc/UTC")

    issue = %{
      "timelineItems" => %{
        "nodes" => [
          %{
            "source" => %{
              "__typename" => "PullRequest",
              "number" => 58,
              "title" => "Batch review feedback",
              "url" => "https://example.test/pr/58",
              "state" => "OPEN",
              "reviewDecision" => "CHANGES_REQUESTED",
              "reviewThreads" => %{
                "nodes" => [
                  %{
                    "isResolved" => false,
                    "isOutdated" => false,
                    "path" => "lib/example.ex",
                    "line" => 42,
                    "comments" => %{
                      "nodes" => [
                        %{
                          "body" => "This comment has two issues: handle nil and add a regression test.",
                          "url" => "https://example.test/thread/1",
                          "author" => %{"login" => "review-bot"}
                        },
                        %{
                          "body" => "Ack, I will cover both in one pass.",
                          "url" => "https://example.test/thread/1#reply",
                          "author" => %{"login" => "bohdan"}
                        }
                      ]
                    }
                  },
                  %{
                    "isResolved" => false,
                    "isOutdated" => true,
                    "path" => "lib/ignore.ex",
                    "line" => 7,
                    "comments" => %{
                      "nodes" => [
                        %{
                          "body" => "Outdated thread",
                          "url" => "https://example.test/thread/old",
                          "author" => %{"login" => "review-bot"}
                        }
                      ]
                    }
                  }
                ]
              },
              "reviews" => %{
                "nodes" => [
                  %{
                    "state" => "COMMENTED",
                    "body" => "Please batch the remaining edge cases together.",
                    "url" => "https://example.test/reviews/1",
                    "submittedAt" => "2026-03-14T12:05:00Z",
                    "author" => %{"login" => "lead-reviewer"}
                  }
                ]
              },
              "comments" => %{
                "nodes" => [
                  %{
                    "body" => "Also update the PR note once the full batch is done.",
                    "url" => "https://example.test/comments/1",
                    "updatedAt" => "2026-03-14T12:06:00Z",
                    "author" => %{"login" => "lead-reviewer"}
                  }
                ]
              }
            }
          }
        ]
      }
    }

    context = ReviewFeedback.build_prompt_context(issue, issue_updated_at)

    assert context =~ "Open PR review feedback requires batch handling."
    assert context =~ "PR #58: Batch review feedback [decision=CHANGES_REQUESTED]"
    assert context =~ "1. lib/example.ex:42"
    assert context =~ "review-bot"
    assert context =~ "handle nil and add a regression test"
    assert context =~ "bohdan"
    assert context =~ "Ack, I will cover both in one pass"
    assert context =~ "Fresh review summaries/comments since last issue update"
    assert context =~ "Please batch the remaining edge cases together"
    assert context =~ "Fresh top-level PR comments since last issue update"
    assert context =~ "Also update the PR note once the full batch is done"
    refute context =~ "Outdated thread"
  end

  test "has_actionable_feedback ignores outdated threads and stale comments" do
    issue_updated_at = DateTime.from_naive!(~N[2026-03-14 12:00:00], "Etc/UTC")

    issue = %{
      "timelineItems" => %{
        "nodes" => [
          %{
            "source" => %{
              "__typename" => "PullRequest",
              "number" => 91,
              "title" => "Ignore stale feedback",
              "url" => "https://example.test/pr/91",
              "state" => "OPEN",
              "reviewDecision" => "CHANGES_REQUESTED",
              "reviewThreads" => %{
                "nodes" => [
                  %{
                    "isResolved" => false,
                    "isOutdated" => true,
                    "comments" => %{
                      "nodes" => [
                        %{
                          "body" => "Old thread",
                          "url" => "https://example.test/thread/stale",
                          "author" => %{"login" => "review-bot"}
                        }
                      ]
                    }
                  }
                ]
              },
              "reviews" => %{
                "nodes" => [
                  %{
                    "state" => "COMMENTED",
                    "body" => "Old summary",
                    "url" => "https://example.test/reviews/stale",
                    "submittedAt" => "2026-03-14T11:00:00Z",
                    "author" => %{"login" => "lead-reviewer"}
                  }
                ]
              },
              "comments" => %{
                "nodes" => [
                  %{
                    "body" => "Old top-level comment",
                    "url" => "https://example.test/comments/stale",
                    "updatedAt" => "2026-03-14T11:30:00Z",
                    "author" => %{"login" => "lead-reviewer"}
                  }
                ]
              }
            }
          }
        ]
      }
    }

    refute ReviewFeedback.has_actionable_feedback?(issue, issue_updated_at)
    assert ReviewFeedback.build_prompt_context(issue, issue_updated_at) == nil
  end
end
