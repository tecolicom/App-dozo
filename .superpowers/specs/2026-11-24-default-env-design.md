# Leaving out the default environment variables

## Why

dozo always passes DEFAULT_ENV to the container, and it includes the API
keys (DEEPL_AUTH_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY,
LLM_PERPLEXITY_KEY).  When the container runs code that is not trusted,
such as the dependencies cabal fetches from Hackage in the skylighting
build, that code can read the keys.  `--no-env` discards only the `-E`
values, so there is no way to stop it.

A list of names to leave out would miss the variables added to the
defaults later.  The defaults are therefore dropped by group.

## Goals

- Drop the secrets (API keys and the like) and keep the standard
  variables: `--no-secrets`.
- Drop every default variable and pass only what `-E` gives after it:
  `--no-env`.
- Both can be written in `.dozorc`, and work in the order given.

## Non-goals

- Without these options nothing changes; the keys are still passed.
  Moving the keys out of the defaults (and xlate passing them with
  `-E`) is a separate task, if ever.
- No user-defined groups and no new variables in the defaults.

## Approaches

1. Two new flags, `--no-secrets` and `--no-default-env`, merged after
   parsing.  Leaves `--no-env` as it is, but adds two options.
2. One option naming the groups to drop (`--drop-env=secrets,all`).
   Too much for two groups.
3. The defaults are the initial value of `-E`, so `--no-env` drops
   them as it drops any value given so far, plus `--no-secrets`
   (chosen, the user's proposal).  One new option, and the rule that
   `--no-OPTION` discards the values so far now covers the defaults.
   It changes `--no-env`: LANG, TZ and the rest are no longer passed
   after it.

## Design

- DEFAULT_ENV keeps the standard variables: LANG TZ, the proxies,
  TERM_PROGRAM TERM_BGCOLOR COLORTERM.  The proxies stay here although
  a URL may hold a password: builds need them.
- A new SECRET_ENV holds the four API keys.  Secrets added in future go
  here.
- OPTS: `env` starts with both groups; `secrets` is a flag, on by
  default, with a callback.

  ```
  [     env | E @ # environment variable to inherit ]="(${DEFAULT_ENV[*]} ${SECRET_ENV[*]})"
  [ secrets |   # pass API keys and other secrets ]=1
  ```

- The `secrets` callback runs when `--secrets` or `--no-secrets` is
  parsed: it removes from `env` every value whose name (before `=`) is
  in SECRET_ENV, then adds SECRET_ENV back when the flag is on.  So
  the options act in order:

  ```
  --no-secrets               -> LANG TZ ...
  --no-secrets -E KEY=x      -> LANG TZ ... KEY=x
  -E KEY=v --no-secrets      -> LANG TZ ...
  --no-env -E LANG           -> LANG
  --no-secrets --secrets     -> LANG TZ ... and the keys
  ```

  The callback ends with `return 0` (set -e).
- The merge becomes `ENV=("${env[@]}")` plus `HOME=$workdir` for `-H`,
  added after the options and so never dropped.
  `DOZO_RUNNING_ON_DOCKER` and `XLATE_RUNNING_ON_DOCKER` are set
  separately and stay (`-S` finds containers by the former).
- The `.dozorc` files are parsed one by one with the same option state,
  so a `--no-env` in `$HOME/.dozorc` holds for later files, and a
  later `-E` or `--secrets` adds to it.
- The variables are the same for `docker run` and `docker exec` (-L),
  since both use env_opts.
- DEFAULT_ENV and SECRET_ENV must be defined before OPTS.

## Compatibility

`--no-env` used to keep the defaults; now it drops them.  Changes
says so.

## Documentation

- OPTIONS: `-E` says the defaults are its initial values and
  `--no-env` drops them; a new item for `--no-secrets`.
- The paragraph on `--no-OPTION` mentions the defaults of `-E`.
- ENVIRONMENT, Inherited Variables: the two groups, and which option
  drops each.
- The xlate image section says the API keys are inherited; add that
  `--no-secrets` stops it.
- SYNOPSIS line for `--no-secrets`.

## Tests

- t/03_dozo.t with `-n`: the `-e` options in the docker command for the
  default, `--no-secrets`, `--no-env`, `--no-secrets -E KEY=x`,
  `-E KEY=v --no-secrets`, `--no-env -H` (HOME stays), and `.dozorc`
  `--no-secrets` taken back by `--secrets` on the command line.
- Check that existing tests using `--no-env` still hold.

## Left to the builder

- Exact help text and POD wording.
- Where the tests go in t/03_dozo.t.
