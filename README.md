# digline-action

Hold this branch's LLM output against the baseline committed in your repository,
and put the comparison on the pull request.

```yaml
name: digline
on: [pull_request]

permissions:
  contents: read
  pull-requests: write     # only if you want the comment

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: digline/digline-action@v1
        with:
          suite: eval/suite.py
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

That runs the suite, compares the result against
`.digline/<tenant>/baselines/<suite>.json` — the baseline you committed — and
fails the job if anything got worse. On a regression it comments:

> ### digline — `eval/suite.py`
>
> **Something got worse.**
>
> ```
> 1 check got worse compared with the reference. Every case could be judged.
> 1 case is suspended. The suite is unchanged from the reference.
>
>   temperature 0.3 → 0.7
>
> how-do-i-return · llm_rubric · dropped from 0.910000 to 0.640000, below its
> threshold of 0.700000, and beyond the 0.880000–0.950000 this check measured
> across 5 samples
> ```

The block is `digline compare`'s own output, verbatim. It is not reassembled
here into a table: the sentence a reviewer reads on the pull request is the
sentence the HTML report shows and the sentence the CLI prints, because two
renderings of one comparison drift apart the day either of them moves.

## The exit codes are the contract

| | |
|---|---|
| `0` | nothing got worse — the job passes |
| `1` | something got worse — the job fails, and it comments |
| `2` | the run could not be judged — the job fails, and it comments. Nothing downstream of it is meaningful, including any conclusion from the green checks beside it |
| `64` | digline refused the request you made. Not a verdict on the suite |

The action does not translate these into a pass or a fail of its own: it exits
with digline's code, so a later step can tell `1` from `2` and act on the
difference.

The outputs are readable **even when the gate fails**, which is the case that
matters — the action records the verdict and then carries it, in that order, and
its own CI asserts this against a red fixture:

```yaml
      - uses: digline/digline-action@v1
        id: gate
        continue-on-error: true          # so the job can decide for itself
        with:
          suite: eval/suite.py

      - if: always()
        env:
          # Through `env:`, never interpolated into the script body. The
          # headline is digline's own fixed vocabulary and counts, so nothing
          # here is injectable today — but this is the line people copy for
          # other values, and `${{ }}` inside a `run:` is how a workflow gets
          # a shell injection.
          HEADLINE: ${{ steps.gate.outputs.headline }}
          CODE: ${{ steps.gate.outputs.exit-code }}
        run: |
          echo "$HEADLINE"
          case "$CODE" in
            0) echo "proceed" ;;
            1) echo "something got worse"; exit 1 ;;
            2) echo "could not be judged — nothing downstream is meaningful"; exit 1 ;;
          esac
```

Without `continue-on-error` the job simply stops at the action, which is the
right default and needs none of this.

## Inputs

| | | |
|---|---|---|
| `suite` | **required** | `path/to/suite.py[:attribute]` or `path/to/suite.toml`, from the repository root |
| `root` | `.` | the directory holding `.digline/` — the CLI's `--root` |
| `tenant` | | verify the suite's tenant. Verifies, never overrides: a CI job states what it believes it is running and is told when it is wrong |
| `env` | | verify the suite's environment, the same way |
| `image` | `ghcr.io/digline/digline:0.9.0` | see below |
| `run` | `true` | produce a run before comparing. **This calls your provider and spends money.** `false` compares the run a previous step already produced |
| `comment` | `true` | post the comparison on the pull request. Needs `pull-requests: write` |
| `comment-on-success` | `false` | comment when nothing got worse, too |
| `forward-env` | the three first-party plugins' variables | which environment variables to pass into the container, **by name** |
| `github-token` | `${{ github.token }}` | the token the comment is posted with |

Outputs: `exit-code`, `headline` (the one-sentence verdict), `run-key`, and
`report` (the path to the compare output, verbatim, if you want to attach it as
an artifact). All four are set whether the gate passes or fails.

`suite`, `root`, `tenant` and `env` are the CLI's own flag names and mean exactly
what they mean there.

### Why `comment-on-success` is off

A comment on every green pull request is what teaches a reviewer to scroll past
digline's comments, and by the time one matters they have learned to. The green
check mark already carries that news. A regression and an unjudged run always
comment, whatever this is set to.

## The escape hatch: your own image

The default image is `ghcr.io/digline/digline`, which contains the CLI and the
three provider plugins and — deliberately — **nothing else**. No dynamic
installs at runtime, ever: an image that sometimes pip-installs what a suite
turns out to need is an image whose contents nobody can state, and a gate whose
contents nobody can state is not a gate.

That is fine for a `suite.toml`, and for a `suite.py` that imports nothing but
digline. It is **not** fine for the common case, because `digline compare` loads
your suite and your suite imports your application:

```python
import app                    # <- this has to exist inside the image
from digline.run import Suite
```

So derive the image once:

```dockerfile
FROM ghcr.io/digline/digline:0.9.0
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt
```

and point the action at it:

```yaml
      - uses: digline/digline-action@v1
        with:
          suite: eval/suite.py
          image: ghcr.io/acme/digline-with-our-app:0.9.0
```

The default tag tracks this action's own version, so `@v1` and the image it runs
are released together. Pin your derivation to the same digline version and they
stay in step.

## Keys

Set them as `env:` on the step. The action forwards each name in `forward-env`
that is actually set — **by name**, as `docker run --env NAME`, so no value ever
appears in a command line where a log could show it.

```yaml
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          AWS_REGION: eu-west-1
```

For a provider that is not one of the three, add its variable:

```yaml
        with:
          forward-env: "OPENAI_API_KEY MISTRAL_API_KEY"
```

Nothing is baked into an image and nothing is written to disk.

## Splitting the spend from the gate

`run: false` compares a run somebody else produced, which is the shape to reach
for when you want the two costs separate in the log — or when a matrix of jobs
should gate on one run rather than each buying its own:

`--user` is not optional here either: without it the run writes `.digline/`
as root and every later step that touches it fails.

```yaml
      - run: |
          docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" \
            ghcr.io/digline/digline:0.9.0 run --suite eval/suite.py
      - uses: digline/digline-action@v1
        with:
          suite: eval/suite.py
          run: false
```

## What it will not do

**It does not promote.** There is no input that makes this run the new baseline.
A baseline is an *approved reference*, and the approval is a person's: it is
what a reviewer signed, what ships in the pull request, and what a customer is
shown. `promote` writes into `.digline/<tenant>/baselines/`, which is committed,
so anything landing there arrives in somebody's diff and must arrive because
they put it there. A job that promoted before it compared would be comparing a
run with itself and passing by construction.

**It sends nothing anywhere.** The container talks to the provider your suite
configured and to nothing else. Everything it writes lands in `.digline/` inside
your checkout, owned by the user who owns that checkout — the action passes
`--user "$(id -u):$(id -g)"` for exactly that, and warns you in the log if the
files come back owned by somebody else.

## The trust model, and the one way to get it badly wrong

**This action runs code from the checkout.** `digline compare` loads your
suite, and a `suite.py` is Python: it imports your application and runs at
collection. That is the design — a suite is code and says so — and it decides
how this action may be triggered.

**Use `pull_request`.** A pull request from a fork then runs with a read-only
`GITHUB_TOKEN` and **no access to your secrets**, which is what makes it safe to
execute a contributor's suite at all. The comment step simply does not post on
such a run, and that is correct rather than a limitation.

> **Never `pull_request_target` with a checkout of the pull request's head.**
> That combination gives a fork's code your secrets — your provider API keys —
> and this action would be the thing that runs it. It is the classic
> "pwn request", and an evaluation gate is an unusually attractive place for
> it because the secrets in reach are exactly the ones worth stealing.
>
> ```yaml
> # DO NOT DO THIS
> on: pull_request_target
> jobs:
>   gate:
>     steps:
>       - uses: actions/checkout@v5
>         with:
>           ref: ${{ github.event.pull_request.head.sha }}   # fork's code…
>       - uses: digline/digline-action@v1                    # …with your keys
> ```

**A fork can edit the workflow.** Under `pull_request`, the workflow that runs
is the one on the fork's branch, so a contributor can point `image:` at any
registry they like. What that image gets is the public checkout, a read-only
token and no secrets — the ordinary fork-PR bargain, unchanged by this action.
If that is not a bargain you want, gate the job on a label or require approval
for first-time contributors; GitHub's "Require approval for all external
contributors" setting is the blunt version.

**The inputs are yours, not a contributor's.** `suite`, `root`, `tenant`, `env`
and `image` reach the container as argv, each as exactly one element — an
adversarial pass fed them spaces, quotes, `$()`, backticks, `;` and appended
`--privileged`, and every one arrived as a single inert string. But they come
from your workflow file, and a workflow file that a fork can edit is a workflow
file a fork controls; the paragraph above is the part that matters.

## Requirements

A Linux runner with Docker — `ubuntu-latest` has both. The comment step uses
`gh`, which is pre-installed on GitHub-hosted runners.

## The rest

- [digline.dev](https://digline.dev/) — what it is and why
- [The official image](https://digline.dev/product/docker/) — what it contains,
  its tags, and how to derive it
- [`pytest-digline`](https://digline.dev/product/pytest/) — the same gate as rows
  in pytest's own report, for a repository that already runs one
- [github.com/digline/digline](https://github.com/digline/digline) — the engine

Apache-2.0, like digline itself.
