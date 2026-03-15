# Fork notes

## Upstream

- Upstream repository: [`openai/symphony`](https://github.com/openai/symphony)
- Upstream branch tracked here: `main`
- This fork is rebased on top of upstream rather than developed as a long-lived divergent rewrite.

## Why this fork exists

This fork exists to carry practical extensions and operating defaults that are useful in real OSS use:

- GitHub Projects v2 tracker support in the Elixir implementation
- stronger PR review/rework handling, especially batching active review feedback instead of reacting to only the latest comment
- space for faster fork-local iteration while upstream and downstream needs are still settling

## Current differences from upstream

At the moment, this fork may include changes such as:

- GitHub-backed tracker support alongside the original tracker flow
- PR review feedback collection injected into agent context
- rework guidance that treats active PR feedback as a batch queue
- fork-local workflow/docs adjustments to make the behavior easier to understand and operate as an OSS repo

For exact code differences, compare branches directly:

- upstream: `openai/symphony:main`
- fork: `bohdanpodvirnyi/symphony:main`

## Compatibility

- Goal: stay close to upstream behavior unless a fork-specific change is intentional
- The fork is best treated as **upstream plus additional capabilities/defaults**, not a separate product
- Some workflow text, prompt behavior, and tracker configuration may differ from upstream

If you are adopting this fork, check both:

- the root [README.md](./README.md)
- the Elixir implementation docs in [`elixir/README.md`](./elixir/README.md)

## Sync policy

- Rebase regularly onto `openai/symphony/main`
- Keep fork-specific commits as isolated and reviewable as possible
- Prefer upstream-compatible changes when feasible

## Upstreaming policy

Likely candidates to upstream:

- generally useful bug fixes
- review/rework flow improvements that are not fork-specific
- tracker/runtime fixes that improve base Symphony behavior

Likely to remain fork-local:

- opinionated operating defaults for this fork
- experiments that depend on this repo's maintenance style
- features that upstream does not want to carry yet

## Contributing

Issues and PRs are welcome here for fork-specific behavior.

If a change looks broadly useful to all Symphony users, upstreaming it to `openai/symphony` is encouraged as well.

## Status

This is an unofficial maintained fork, not the canonical upstream repository.
