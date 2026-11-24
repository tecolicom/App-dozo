# Default Environment Variables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--no-env` drops the default variables too, and a new `--no-secrets` drops only the API keys.

**Architecture:** The default variables become the initial value of the `env` list option, so getoptlong's `--no-env` clears them like any value given so far.  The API keys move to SECRET_ENV; a `secrets` flag (default 1) has a callback that removes the secret names from `env` and adds them back when the flag is on, so options act in the order given.

**Tech Stack:** Bash 4.4+, getoptlong.sh (Getopt::Long::Bash), Perl Test::More, Minilla.

**Spec:** `.superpowers/specs/2026-11-24-default-env-design.md`

## Global Constraints

- Without the new options, the variables passed are as in 1.03 (standard ones, then the four keys, then `-E` values); only `HOME=/work` of `-H` moves to the front.
- SECRET_ENV: `DEEPL_AUTH_KEY OPENAI_API_KEY ANTHROPIC_API_KEY LLM_PERPLEXITY_KEY`.
- DEFAULT_ENV: `LANG TZ HTTP_PROXY HTTPS_PROXY http_proxy https_proxy TERM_PROGRAM TERM_BGCOLOR COLORTERM`.
- `HOME=/work` from `-H`, `DOZO_RUNNING_ON_DOCKER=1` and `XLATE_RUNNING_ON_DOCKER=1` are never dropped.
- Every new function ends with `return 0` (set -euo pipefail).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, no `Claude-Session:` line.
- Do not touch Changes (written at release).
- After POD changes, run `minil build` and commit README.md.

## Review Focus

- `-E OPENAI_API_KEY` without a value, before `--no-secrets`: removed (the name is the whole value).
- `--no-secrets` given twice, or in two `.dozorc` files: no duplicates, keys stay out.
- `--secrets` when the keys are already there: no duplicate `-e` (callback removes before adding).
- `.dozorc` in `$HOME` with `--no-env`, project `.dozorc` with `-E LANG`: only LANG (state carries across files).
- `-L` exec path uses the same `env_opts`: no separate code; check by reading that `env_opts` is built once from `env`.

---

### Task 1: Groups, `--no-secrets`, and `--no-env` for the defaults

**Files:**
- Modify: `script/dozo:362-372` (DEFAULT_ENV, new SECRET_ENV)
- Modify: `script/dozo:456` (OPTS `env` initial value, new `secrets`)
- Modify: `script/dozo:481` (register the callback)
- Modify: `script/dozo:535-541` (merge)
- Test: `t/03_dozo.t` (new subtest after 'list options')

**Interfaces:**
- Produces: option `--secrets`/`--no-secrets` (variable `$secrets`, `1` or empty); function `secrets_set` (getoptlong callback, no arguments used); array `SECRET_ENV`.

- [ ] **Step 1: Write the failing test** — subtest `'default environment variables'` in `t/03_dozo.t`, with the docker stub of 'list options' (prints `[%s]` for each `run` argument) and `my $run = sub { scalar `$dozo -U -I alpine @_ true 2>/dev/null` }`; `my $keys = qr/\[(?:DEEPL_AUTH_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|LLM_PERPLEXITY_KEY)\]/`.

```perl
my $out = $run->('');
like($out, qr/\[-e\]\[LANG\]/, 'default: LANG');
like($out, qr/\[-e\]\[OPENAI_API_KEY\]/, 'default: keys');

$out = $run->('--no-secrets');
like($out, qr/\[-e\]\[LANG\]/, '--no-secrets: LANG stays');
unlike($out, $keys, '--no-secrets: no keys');

$out = $run->('--no-env');
unlike($out, qr/\[(?:LANG|TZ)\]/, '--no-env: no standard variables');
unlike($out, $keys, '--no-env: no keys');
like($out, qr/\[DOZO_RUNNING_ON_DOCKER=1\]/, '--no-env: DOZO_RUNNING_ON_DOCKER stays');

like($run->('--no-env -E LANG'), qr/\[-e\]\[LANG\]/, '--no-env -E LANG: LANG');
unlike($run->('--no-env -E LANG'), qr/\[TZ\]/, '--no-env -E LANG: no TZ');

$out = $run->('--no-secrets -E OPENAI_API_KEY=x');
like($out, qr/\[OPENAI_API_KEY=x\]/, '-E after --no-secrets: added');
unlike($out, qr/\[ANTHROPIC_API_KEY\]/, '-E after --no-secrets: others stay out');

unlike($run->('-E OPENAI_API_KEY=v --no-secrets'), qr/OPENAI_API_KEY/, '-E before --no-secrets: removed');
unlike($run->('-E OPENAI_API_KEY --no-secrets'), qr/OPENAI_API_KEY/, '-E NAME before --no-secrets: removed');

$out = $run->('--secrets');
is(scalar(() = $out =~ /\[OPENAI_API_KEY\]/g), 1, '--secrets: no duplicate');
unlike($run->('--no-secrets --no-secrets'), $keys, '--no-secrets twice');
like($run->('--no-secrets --secrets'), qr/\[OPENAI_API_KEY\]/, '--secrets takes it back');

like(scalar `$dozo -H -I alpine --no-env true 2>/dev/null`, qr/\[HOME=\/work\]/, '--no-env -H: HOME stays');
```

Then, with `local $ENV{HOME} = tempdir(CLEANUP => 1)`, chdir there, `.dozorc` containing `--no-secrets`:
`unlike($run->(''), $keys, '.dozorc --no-secrets')` and `like($run->('--secrets'), qr/\[OPENAI_API_KEY\]/, 'command line --secrets takes it back')`.  Then `.dozorc` `--no-env` in `$HOME` and a git-less cwd subdirectory `.dozorc` with `-E LANG` (cd into it): `like` `[LANG]`, `unlike` `[TZ]`.  Restore cwd afterwards (`chdir $empty_home`).

- [ ] **Step 2: Run it to make sure it fails**

Run: `prove -v t/03_dozo.t 2>&1 | grep -A3 'default environment'`
Expected: FAIL — `--no-secrets` gives "no such option", `--no-env` still passes LANG.

- [ ] **Step 3: Implement in `script/dozo`**

- Remove the four keys from DEFAULT_ENV; add `SECRET_ENV=(DEEPL_AUTH_KEY OPENAI_API_KEY ANTHROPIC_API_KEY LLM_PERPLEXITY_KEY)` with the comment `# Secrets, inherited unless --no-secrets`.
- OPTS: `[ env | E @ # environment variable to inherit ]="(${DEFAULT_ENV[*]} ${SECRET_ENV[*]})"`; add `[ secrets | # pass API keys and other secrets ]=1` after it, aligned with the others.
- `secrets_set()`, defined before `getoptlong init`: keep the values of `env` whose name (`${e%%=*}`) is not in SECRET_ENV; append SECRET_ENV when `$secrets`; `return 0`.  Comment: runs when `--secrets` or `--no-secrets` is parsed, so the options act in order.
- `getoptlong init OPTS && getoptlong callback image image_set && getoptlong callback secrets secrets_set`.
- Merge: `ENV=()`, `[[ $mount_home ]] && ENV+=(HOME=$workdir)`, then `ENV+=("${env[@]}")`; remove `DEFAULT_ENV+=(HOME=$workdir)` from the `-H` line.  HOME goes first so that `-H -E HOME=x` still gives HOME=x (docker takes the last of the same name), as in 1.03.  DEFAULT_ENV is no longer used after OPTS.

- [ ] **Step 4: Run the tests**

Run: `prove -lr t`
Expected: all pass.

- [ ] **Step 5: Check the default is unchanged**

With the docker stub on PATH, save the output of `dozo -U -I alpine true`, `dozo -U -I alpine -E A=1 true` and `dozo -H -I alpine -E HOME=x true` from `git show HEAD:script/dozo` and from the working tree, and diff them.
Expected: the first two identical; the third differs only in where `HOME=/work` stands, and `HOME=x` is still after it.

- [ ] **Step 6: Commit**

```bash
git add script/dozo t/03_dozo.t
git commit -m "--no-env drops the default variables; add --no-secrets"
```

### Task 2: Documentation

**Files:**
- Modify: `script/dozo` POD — SYNOPSIS (after `-E`), `Environment Inheritance` item (~1151), the `--no-OPTION` paragraph (~1194), `-E` item (~1266), new `--no-secrets` item after it, xlate image `Environment` (~1848), `Inherited Variables` (~1867).
- Modify: `README.md` (regenerated)

- [ ] **Step 1: Edit the POD**

- SYNOPSIS: `    --no-secrets   do not inherit API keys and other secrets`.
- `-E`: the default variables (see ENVIRONMENT) are its initial values; `--no-env` drops them as well as the values given so far.
- `--no-secrets` item: drops the secrets (ENVIRONMENT lists them), including those given with `-E` before it; `-E` after it adds one back; `--secrets` takes it back.
- `--no-OPTION` paragraph: add that for `-E` this includes the default variables.
- Environment Inheritance: mention `--no-secrets` and `--no-env`.
- xlate image: the API keys are inherited unless `--no-secrets`.
- Inherited Variables: two lists, standard and secrets; `--no-env` drops both, `--no-secrets` the second; `HOME` from `-H` and the container variables are always set.

- [ ] **Step 2: Build and check**

Run: `minil build && prove -lr t && script/dozo --help | grep -n secrets`
Expected: tests pass; the SYNOPSIS line is shown.

- [ ] **Step 3: Commit**

```bash
git add script/dozo README.md
git commit -m "Document --no-secrets and --no-env for the default variables"
```
