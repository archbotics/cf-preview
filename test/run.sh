#!/usr/bin/env bash
# cf-preview test suite. Plain bash, no test framework, no network.
#
# Every external command cf-preview can reach out with (npx, curl, git) is
# shadowed by a stub in test/stubs, which records its arguments to a log the
# assertions read. Nothing here contacts Cloudflare and nothing is deployed.
#
#   ./test/run.sh            run everything
#   ./test/run.sh hardening  run cases whose name contains "hardening"
# Cases are dispatched by name out of a registry, which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI="$ROOT/cf-preview"
STUBS="$ROOT/test/stubs"
FILTER="${1:-}"

PASS=0
FAIL=0
CURRENT=""
WORK=""
ORIG_PATH="$PATH"
ORIG_TMPDIR="${TMPDIR:-/tmp}"

# --- harness -----------------------------------------------------------------

setup_case() {
  CURRENT="$1"
  # PATH first: a case may narrow it, and the harness needs its own tools back
  # before it touches the filesystem.
  export PATH="$STUBS:$ORIG_PATH"
  WORK=$(mktemp -d "$ORIG_TMPDIR/cf-preview-test.XXXXXXXX") || exit 1
  export TMPDIR="$WORK/tmp"
  mkdir -p "$TMPDIR"
  export CF_PREVIEW_TEST_LOG="$WORK/calls.log"
  : >"$CF_PREVIEW_TEST_LOG"
  export CLOUDFLARE_API_TOKEN="test-token-not-a-real-secret"
  export CLOUDFLARE_ACCOUNT_ID="0123456789abcdef"
  export CF_WORKERS_SUBDOMAIN="teststub"
  unset CF_PREVIEW_TEST_REF CF_PREVIEW_TEST_REPO CF_PREVIEW_TEST_WORKTREE_SRC 2>/dev/null || true
  OUT="$WORK/stdout"
  ERR="$WORK/stderr"
  STATUS=0
  CLI_PATH=""
  LEAKED=0
}

teardown_case() {
  export PATH="$STUBS:$ORIG_PATH"
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  WORK=""
}

# Run cf-preview, capturing stdout, stderr and exit status without tripping -e.
# CLI_PATH narrows PATH for the tool alone; the harness keeps its own tools.
#
# Every invocation is checked for a leaked credential. This is an invariant of
# the harness rather than one case, because a token can escape through any
# output path the tool has: a receipt, an error message, a dry run, a stack of
# curl output echoed on failure.
cli() {
  STATUS=0
  PATH="${CLI_PATH:-$PATH}" "$CLI" "$@" >"$OUT" 2>"$ERR" || STATUS=$?
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] \
     && grep -qF -- "$CLOUDFLARE_API_TOKEN" "$OUT" "$ERR" 2>/dev/null; then
    LEAKED=1
    fail "the API token appeared in cf-preview output"
  fi
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] \
     && grep -qF -- "$CLOUDFLARE_API_TOKEN" "$CF_PREVIEW_TEST_LOG" 2>/dev/null; then
    LEAKED=1
    fail "the API token appeared in a subprocess argument list"
  fi
  return 0
}

out() { cat "$OUT"; }
err() { cat "$ERR"; }
calls() { cat "$CF_PREVIEW_TEST_LOG"; }

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n     %s\n' "$CURRENT" "$1"
  if [ -s "$OUT" ]; then printf '     stdout: %s\n' "$(head -c 600 "$OUT" | tr '\n' '|')"; fi
  if [ -s "$ERR" ]; then printf '     stderr: %s\n' "$(head -c 600 "$ERR" | tr '\n' '|')"; fi
}

ok() {
  if [ "${LEAKED:-0}" -eq 1 ]; then return 0; fi   # cli() already failed it
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$CURRENT"
}

assert_status() {
  [ "$STATUS" = "$1" ] || { fail "expected exit $1, got $STATUS"; return 1; }
}

assert_contains() {
  printf '%s' "$1" | grep -qF -- "$2" || { fail "expected to contain: $2"; return 1; }
}

assert_not_contains() {
  printf '%s' "$1" | grep -qF -- "$2" && { fail "expected NOT to contain: $2"; return 1; }
  return 0
}

assert_file_contains() {
  [ -f "$1" ] || { fail "missing file: $1"; return 1; }
  grep -qF -- "$2" "$1" || { fail "$1 does not contain: $2"; return 1; }
}

assert_no_file() {
  [ ! -e "$1" ] || { fail "expected absent: $1"; return 1; }
  return 0
}

# sha256 manifest of a directory tree, used to prove the source is untouched.
manifest() {
  (cd "$1" && find . \( -type f -o -type d \) | LC_ALL=C sort | while read -r p; do
    if [ -d "$p" ]; then printf 'd %s\n' "$p"; else printf 'f %s %s\n' "$p" "$(sha256sum "$p" | cut -d' ' -f1)"; fi
  done)
}

# A PATH holding only the named commands, so a case can prove what happens
# when a dependency is missing. The stub directory is prepended by the caller.
restricted_path() {
  local dir="${WORK:?restricted_path needs a case working directory}/bin" c src
  rm -rf "$dir"; mkdir -p "$dir"
  for c in "$@"; do
    src=$(command -v "$c" 2>/dev/null) || continue
    ln -sf "$src" "$dir/$c"
  done
  printf '%s' "$dir"
}

# The working directory cf-preview kept behind, read from its own receipt.
kept_workdir() {
  sed -n 's/^cf-preview: kept working directory: //p' "$ERR" | tail -1
}

case_names=()
register() { case_names+=("$1"); }

# --- cases -------------------------------------------------------------------

case_help_prints_usage() {
  cli --help
  assert_status 0 || return
  assert_contains "$(out)" "Usage:" || return
  assert_contains "$(out)" "cf-preview deploy <dir-or-git-ref> --name <slug>" || return
  ok
}
register case_help_prints_usage

case_no_args_is_an_error() {
  cli
  assert_status 1 || return
  assert_contains "$(err)" "Usage:" || return
  ok
}
register case_no_args_is_an_error

case_unknown_command_is_an_error() {
  cli frobnicate
  assert_status 1 || return
  assert_contains "$(err)" "unknown command: frobnicate" || return
  ok
}
register case_unknown_command_is_an_error

case_version_prints_a_version() {
  cli --version
  assert_status 0 || return
  assert_contains "$(out)" "cf-preview 0." || return
  ok
}
register case_version_prints_a_version

case_deploy_requires_a_name() {
  cli deploy "$ROOT/example"
  assert_status 1 || return
  assert_contains "$(err)" "deploy needs --name" || return
  ok
}
register case_deploy_requires_a_name

case_deploy_requires_a_source() {
  cli deploy --name demo
  assert_status 1 || return
  assert_contains "$(err)" "deploy needs a directory or git ref" || return
  ok
}
register case_deploy_requires_a_source

case_deploy_rejects_two_sources() {
  cli deploy ./a ./b --name demo
  assert_status 1 || return
  assert_contains "$(err)" "takes one directory or git ref" || return
  ok
}
register case_deploy_rejects_two_sources

case_deploy_rejects_unknown_option() {
  cli deploy "$ROOT/example" --name demo --wat
  assert_status 1 || return
  assert_contains "$(err)" "unknown option for deploy: --wat" || return
  ok
}
register case_deploy_rejects_unknown_option

case_prefix_must_be_dns_safe() {
  cli deploy "$ROOT/example" --name demo --prefix "Bad_Prefix" --dry-run
  assert_status 1 || return
  assert_contains "$(err)" "--prefix must start with a lowercase letter" || return
  cli list --prefix "pre fix"
  assert_status 1 || return
  assert_contains "$(err)" "may only contain" || return
  ok
}
register case_prefix_must_be_dns_safe

case_name_must_have_an_alphanumeric() {
  cli deploy "$ROOT/example" --name "---" --dry-run
  assert_status 1 || return
  assert_contains "$(err)" "--name must contain at least one letter or digit" || return
  ok
}
register case_name_must_have_an_alphanumeric

case_output_must_be_relative() {
  cli deploy "$ROOT/example" --name demo --output /etc --dry-run
  assert_status 1 || return
  assert_contains "$(err)" "--output must be relative" || return
  ok
}
register case_output_must_be_relative

case_dry_run_prints_the_commands() {
  cli deploy "$ROOT/example" --name demo --dry-run
  assert_status 0 || return
  local o; o=$(out)
  assert_contains "$o" "+ mktemp -d" || return
  assert_contains "$o" "+ cp -a $ROOT/example/." || return
  assert_contains "$o" "+ write /tmp/cf-preview.XXXXXXXX/site/robots.txt" || return
  assert_contains "$o" "| Disallow: /" || return
  assert_contains "$o" "X-Robots-Tag: noindex, nofollow" || return
  assert_contains "$o" "+ rm -f /tmp/cf-preview.XXXXXXXX/site/CNAME" || return
  assert_contains "$o" '| name = "preview-demo"' || return
  assert_contains "$o" "+ npx --yes wrangler deploy --config /tmp/cf-preview.XXXXXXXX/wrangler.toml" || return
  assert_contains "$o" "dry run: would deploy preview-demo" || return
  assert_contains "$o" "https://preview-demo.teststub.workers.dev/" || return
  ok
}
register case_dry_run_prints_the_commands

case_dry_run_touches_nothing() {
  local before after
  before=$(manifest "$ROOT/example")
  cli deploy "$ROOT/example" --name demo --dry-run
  assert_status 0 || return
  after=$(manifest "$ROOT/example")
  [ "$before" = "$after" ] || { fail "dry run modified the source directory"; return; }
  [ -z "$(ls -A "$TMPDIR")" ] || { fail "dry run created files under TMPDIR"; return; }
  [ -z "$(calls)" ] || { fail "dry run called an external command: $(calls)"; return; }
  ok
}
register case_dry_run_touches_nothing

case_dry_run_without_a_subdomain_says_so() {
  unset CF_WORKERS_SUBDOMAIN
  cli deploy "$ROOT/example" --name demo --dry-run
  assert_status 0 || return
  assert_contains "$(out)" "https://preview-demo.<subdomain>.workers.dev/" || return
  ok
}
register case_dry_run_without_a_subdomain_says_so

case_deploy_hardening_copy() {
  cli deploy "$ROOT/example" --name demo --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)
  [ -n "$w" ] || { fail "no kept working directory in the receipt"; return; }
  assert_file_contains "$w/site/robots.txt" "Disallow: /" || return
  assert_file_contains "$w/site/robots.txt" "User-agent: *" || return
  assert_file_contains "$w/site/_headers" "X-Robots-Tag: noindex, nofollow" || return
  assert_no_file "$w/site/CNAME" || return
  assert_file_contains "$w/site/index.html" "Example site" || return
  [ -f "$w/site/404.html" ] || { fail "404.html was not copied"; return; }
  ok
}
register case_deploy_hardening_copy

case_deploy_leaves_the_source_untouched() {
  local before after
  before=$(manifest "$ROOT/example")
  cli deploy "$ROOT/example" --name demo --keep-temp
  assert_status 0 || return
  after=$(manifest "$ROOT/example")
  [ "$before" = "$after" ] || { fail "deploy modified the source directory"; return; }
  [ -f "$ROOT/example/CNAME" ] || { fail "deploy removed the source CNAME"; return; }
  assert_no_file "$ROOT/example/robots.txt" || return
  assert_no_file "$ROOT/example/_headers" || return
  ok
}
register case_deploy_leaves_the_source_untouched

case_generated_wrangler_toml_assets_only() {
  cli deploy "$ROOT/example" --name demo --keep-temp
  assert_status 0 || return
  local w expected got
  w=$(kept_workdir)
  expected='name = "preview-demo"
compatibility_date = "2025-01-01"
workers_dev = true

[assets]
directory = "./site"
not_found_handling = "404-page"'
  got=$(grep -v '^#' "$w/wrangler.toml")
  [ "$got" = "$expected" ] || { fail "unexpected wrangler.toml:
$got"; return; }
  assert_no_file "$w/worker.js" || return
  ok
}
register case_generated_wrangler_toml_assets_only

case_generated_wrangler_toml_header_worker() {
  cli deploy "$ROOT/example" --name demo --header-worker --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)
  assert_file_contains "$w/wrangler.toml" 'main = "./worker.js"' || return
  assert_file_contains "$w/wrangler.toml" 'binding = "ASSETS"' || return
  assert_file_contains "$w/wrangler.toml" 'run_worker_first = true' || return
  assert_file_contains "$w/worker.js" 'X-Robots-Tag' || return
  assert_file_contains "$w/worker.js" 'env.ASSETS.fetch' || return
  # The worker must live outside the assets directory or it would be served.
  assert_no_file "$w/site/worker.js" || return
  ok
}
register case_generated_wrangler_toml_header_worker

case_deploy_calls_wrangler_and_prints_a_receipt() {
  cli deploy "$ROOT/example" --name demo
  assert_status 0 || return
  assert_contains "$(calls)" "npx --yes wrangler deploy --config" || return
  assert_contains "$(out)" "deployed: preview-demo  https://preview-demo.teststub.workers.dev/" || return
  ok
}
register case_deploy_calls_wrangler_and_prints_a_receipt

case_deploy_cleans_up_by_default() {
  cli deploy "$ROOT/example" --name demo
  assert_status 0 || return
  local leftovers
  leftovers=$(find "$TMPDIR" -maxdepth 1 -name 'cf-preview.*' 2>/dev/null)
  [ -z "$leftovers" ] || { fail "working directory left behind: $leftovers"; return; }
  ok
}
register case_deploy_cleans_up_by_default

case_deploy_custom_prefix_and_subdomain() {
  cli deploy "$ROOT/example" --name demo --prefix review --subdomain acme --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)
  assert_file_contains "$w/wrangler.toml" 'name = "review-demo"' || return
  assert_contains "$(out)" "https://review-demo.acme.workers.dev/" || return
  ok
}
register case_deploy_custom_prefix_and_subdomain

case_deploy_missing_output_dir_fails() {
  cli deploy "$ROOT/example" --name demo --output nope
  assert_status 1 || return
  assert_contains "$(err)" "nothing to deploy" || return
  ok
}
register case_deploy_missing_output_dir_fails

case_long_name_is_hashed_and_stable() {
  local slug="a-very-long-branch-name-that-nobody-would-ever-type-by-hand-but-here-we-are"
  cli deploy "$ROOT/example" --name "$slug" --keep-temp
  assert_status 0 || return
  local w name
  w=$(kept_workdir)
  name=$(sed -n 's/^name = "\(.*\)"$/\1/p' "$w/wrangler.toml")
  [ "${#name}" -le 54 ] || { fail "worker name is ${#name} chars: $name"; return; }
  cli url "$slug" --subdomain acme
  assert_status 0 || return
  assert_contains "$(out)" "https://$name.acme.workers.dev/" || return
  ok
}
register case_long_name_is_hashed_and_stable

case_name_is_slugified() {
  cli url "Feature/Add Pricing Page" --subdomain acme
  assert_status 0 || return
  assert_contains "$(out)" "https://preview-feature-add-pricing-page.acme.workers.dev/" || return
  ok
}
register case_name_is_slugified

case_url_needs_no_network_with_a_subdomain() {
  cli url demo --subdomain acme
  assert_status 0 || return
  [ -z "$(calls)" ] || { fail "url called an external command: $(calls)"; return; }
  ok
}
register case_url_needs_no_network_with_a_subdomain

case_url_looks_up_the_subdomain() {
  unset CF_WORKERS_SUBDOMAIN
  cli url demo
  assert_status 0 || return
  assert_contains "$(calls)" "/workers/subdomain" || return
  assert_contains "$(out)" "https://preview-demo.teststub.workers.dev/" || return
  ok
}
register case_url_looks_up_the_subdomain

case_list_filters_by_prefix() {
  cli list
  assert_status 0 || return
  local o; o=$(out)
  assert_contains "$o" "preview-demo  https://preview-demo.teststub.workers.dev/  modified 2026-01-02T03:04:05Z" || return
  assert_contains "$o" "preview-other" || return
  assert_not_contains "$o" "production-api" || return
  assert_not_contains "$o" "staging-preview-demo" || return
  ok
}
register case_list_filters_by_prefix

case_list_with_no_matches_says_so() {
  cli list --prefix nomatch
  assert_status 0 || return
  assert_contains "$(err)" "no workers named nomatch-*" || return
  ok
}
register case_list_with_no_matches_says_so

case_list_requires_credentials() {
  unset CLOUDFLARE_API_TOKEN
  cli list
  assert_status 1 || return
  assert_contains "$(err)" "CLOUDFLARE_API_TOKEN is not set" || return
  ok
}
register case_list_requires_credentials

case_delete_calls_the_api() {
  cli delete demo
  assert_status 0 || return
  assert_contains "$(calls)" "-X DELETE https://api.cloudflare.com/client/v4/accounts/0123456789abcdef/workers/scripts/preview-demo" || return
  assert_contains "$(out)" "deleted: preview-demo" || return
  ok
}
register case_delete_calls_the_api

case_delete_dry_run_sends_nothing() {
  cli delete demo --dry-run
  assert_status 0 || return
  [ -z "$(calls)" ] || { fail "dry run called an external command: $(calls)"; return; }
  assert_contains "$(out)" "curl -sS --config - -X DELETE" || return
  assert_contains "$(out)" "/workers/scripts/preview-demo" || return
  ok
}
register case_delete_dry_run_sends_nothing

case_dry_run_never_prints_the_token() {
  cli delete demo --dry-run
  assert_status 0 || return
  assert_not_contains "$(out)$(err)" "test-token-not-a-real-secret" || return
  # shellcheck disable=SC2016  # the literal, unexpanded name is the assertion
  assert_contains "$(out)" 'Bearer $CLOUDFLARE_API_TOKEN' || return
  cli list --dry-run
  assert_not_contains "$(out)$(err)" "test-token-not-a-real-secret" || return
  ok
}
register case_dry_run_never_prints_the_token

case_delete_needs_a_slug() {
  cli delete
  assert_status 1 || return
  assert_contains "$(err)" "delete needs a slug" || return
  ok
}
register case_delete_needs_a_slug

case_ref_mode_builds_in_a_detached_worktree() {
  export CF_PREVIEW_TEST_REF="main"
  export CF_PREVIEW_TEST_REPO="$WORK/repo"
  export CF_PREVIEW_TEST_WORKTREE_SRC="$WORK/fixture"
  mkdir -p "$CF_PREVIEW_TEST_REPO" "$CF_PREVIEW_TEST_WORKTREE_SRC"
  printf '<h1>from the worktree</h1>\n' >"$CF_PREVIEW_TEST_WORKTREE_SRC/index.html"
  printf 'example.com\n' >"$CF_PREVIEW_TEST_WORKTREE_SRC/CNAME"

  cli deploy main --name demo --build "mkdir -p dist && cp index.html CNAME dist/" --output dist --keep-temp
  assert_status 0 || return
  local c w
  c=$(calls)
  assert_contains "$c" "worktree add --detach --quiet" || return
  assert_contains "$c" "npx --yes wrangler deploy" || return
  assert_contains "$c" "worktree remove --force" || return
  w=$(kept_workdir)
  assert_file_contains "$w/site/index.html" "from the worktree" || return
  assert_no_file "$w/site/CNAME" || return
  assert_file_contains "$w/site/robots.txt" "Disallow: /" || return
  ok
}
register case_ref_mode_builds_in_a_detached_worktree

case_ref_mode_rejects_an_unknown_ref() {
  export CF_PREVIEW_TEST_REF="main"
  export CF_PREVIEW_TEST_REPO="$WORK/repo"
  mkdir -p "$CF_PREVIEW_TEST_REPO"
  cli deploy nosuchref --name demo --repo "$CF_PREVIEW_TEST_REPO"
  assert_status 1 || return
  assert_contains "$(err)" "neither an existing directory nor a git ref" || return
  assert_not_contains "$(calls)" "worktree add" || return
  ok
}
register case_ref_mode_rejects_an_unknown_ref

case_no_worktree_builds_in_place_and_warns() {
  export CF_PREVIEW_TEST_REF="main"
  export CF_PREVIEW_TEST_REPO="$WORK/repo"
  mkdir -p "$CF_PREVIEW_TEST_REPO"
  printf '<h1>working tree</h1>\n' >"$CF_PREVIEW_TEST_REPO/index.html"

  cli deploy main --name demo --repo "$CF_PREVIEW_TEST_REPO" --no-worktree --keep-temp
  assert_status 0 || return
  assert_contains "$(err)" "--no-worktree: building the working tree" || return
  assert_not_contains "$(calls)" "worktree add" || return
  assert_file_contains "$(kept_workdir)/site/index.html" "working tree" || return
  ok
}
register case_no_worktree_builds_in_place_and_warns

case_no_worktree_is_a_noop_for_a_directory() {
  cli deploy "$ROOT/example" --name demo --no-worktree
  assert_status 0 || return
  assert_contains "$(err)" "--no-worktree has no effect when deploying a directory" || return
  ok
}
register case_no_worktree_is_a_noop_for_a_directory

case_failed_build_stops_the_deploy() {
  export CF_PREVIEW_TEST_REF="main"
  export CF_PREVIEW_TEST_REPO="$WORK/repo"
  export CF_PREVIEW_TEST_WORKTREE_SRC="$WORK/fixture"
  mkdir -p "$CF_PREVIEW_TEST_REPO" "$CF_PREVIEW_TEST_WORKTREE_SRC"
  printf 'x\n' >"$CF_PREVIEW_TEST_WORKTREE_SRC/index.html"

  cli deploy main --name demo --build "exit 3"
  assert_status 1 || return
  assert_contains "$(err)" "build command failed" || return
  assert_not_contains "$(calls)" "npx" || return
  ok
}
register case_failed_build_stops_the_deploy

case_list_works_without_jq() {
  # The jq path is what the other cases exercise; this one proves the python3
  # fallback parses the same response.
  local bin; bin=$(restricted_path bash env python3 cat sed tr cut)
  CLI_PATH="$STUBS:$bin"
  if ( PATH="$CLI_PATH"; command -v jq >/dev/null ); then
    fail "jq is still reachable, the case proves nothing"; return
  fi
  cli list
  assert_status 0 || return
  assert_contains "$(out)" "preview-demo  https://preview-demo.teststub.workers.dev/  modified 2026-01-02T03:04:05Z" || return
  assert_not_contains "$(out)" "production-api" || return
  ok
}
register case_list_works_without_jq

case_api_needs_jq_or_python3() {
  local bin; bin=$(restricted_path bash env cat sed tr cut)
  CLI_PATH="$STUBS:$bin"
  cli list
  assert_status 1 || return
  assert_contains "$(err)" "need jq or python3" || return
  ok
}
register case_api_needs_jq_or_python3

case_hardening_keeps_an_existing_headers_file() {
  local site="$WORK/site"
  mkdir -p "$site"
  printf '<h1>hi</h1>\n' >"$site/index.html"
  printf '/*\n  Content-Security-Policy: default-src self\n' >"$site/_headers"

  cli deploy "$site" --name demo --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)
  assert_file_contains "$w/site/_headers" "Content-Security-Policy" || return
  assert_file_contains "$w/site/_headers" "X-Robots-Tag: noindex, nofollow" || return
  assert_contains "$(err)" "appending the noindex rule" || return
  # The site's own file is untouched.
  assert_not_contains "$(cat "$site/_headers")" "X-Robots-Tag" || return
  ok
}
register case_hardening_keeps_an_existing_headers_file

case_hardening_drops_a_git_directory() {
  # Deploying a repository root must not publish its history.
  local site="$WORK/site"
  mkdir -p "$site/.git/objects" "$site/assets"
  printf '<h1>hi</h1>\n' >"$site/index.html"
  printf 'ref: refs/heads/main\n' >"$site/.git/HEAD"
  printf 'body{}\n' >"$site/assets/app.css"

  cli deploy "$site" --name demo --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)
  [ -f "$w/site/assets/app.css" ] || { fail "hardening removed more than .git"; return; }
  ok
}
register case_hardening_drops_a_git_directory

case_hardening_sweeps_dotfiles_from_the_copy() {
  # A directory handed over unbuilt carries credentials. None of them may
  # reach a public URL.
  local site="$WORK/site"
  mkdir -p "$site/.git/objects" "$site/.ssh" "$site/.github/workflows" "$site/.well-known"
  printf '<h1>hi</h1>\n' >"$site/index.html"
  printf 'API_KEY=sekrit\n' >"$site/.env"
  printf '//registry.npmjs.org/:_authToken=sekrit\n' >"$site/.npmrc"
  printf 'machine example.com password sekrit\n' >"$site/.netrc"
  printf 'ref: refs/heads/main\n' >"$site/.git/HEAD"
  printf 'PRIVATE KEY\n' >"$site/.ssh/id_ed25519"
  printf 'on: push\n' >"$site/.github/workflows/ci.yml"
  printf 'contact: mailto:x@example.com\n' >"$site/.well-known/security.txt"

  local before; before=$(manifest "$site")
  cli deploy "$site" --name demo --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)

  assert_no_file "$w/site/.env" || return
  assert_no_file "$w/site/.npmrc" || return
  assert_no_file "$w/site/.netrc" || return
  assert_no_file "$w/site/.git" || return
  assert_no_file "$w/site/.ssh" || return
  assert_no_file "$w/site/.github" || return
  # .well-known is part of a served site and stays.
  assert_file_contains "$w/site/.well-known/security.txt" "mailto" || return
  assert_file_contains "$w/site/index.html" "hi" || return
  assert_contains "$(err)" "dotfiles kept out of the preview:" || return
  assert_contains "$(err)" ".env" || return

  # Nothing was taken out of the source, only out of the copy.
  [ "$before" = "$(manifest "$site")" ] || { fail "the sweep modified the source"; return; }
  ok
}
register case_hardening_sweeps_dotfiles_from_the_copy

case_hardening_reports_the_sweep_in_a_dry_run() {
  local site="$WORK/site"
  mkdir -p "$site"
  printf '<h1>hi</h1>\n' >"$site/index.html"
  printf 'API_KEY=sekrit\n' >"$site/.env"

  cli deploy "$site" --name demo --dry-run
  assert_status 0 || return
  assert_contains "$(err)" "dotfiles kept out of the preview: .env" || return
  assert_not_contains "$(out)" "sekrit" || return
  ok
}
register case_hardening_reports_the_sweep_in_a_dry_run

case_hardening_drops_top_level_symlinks() {
  # Following the link would copy the file it points at into the preview.
  local site="$WORK/site"
  mkdir -p "$site"
  printf '<h1>hi</h1>\n' >"$site/index.html"
  ln -s /etc/passwd "$site/passwd.html"
  ln -s /etc "$site/etc"

  cli deploy "$site" --name demo --keep-temp
  assert_status 0 || return
  local w; w=$(kept_workdir)
  assert_no_file "$w/site/passwd.html" || return
  assert_no_file "$w/site/etc" || return
  assert_contains "$(err)" "symlinks kept out of the preview:" || return
  [ -L "$site/passwd.html" ] || { fail "the sweep removed the source symlink"; return; }
  ok
}
register case_hardening_drops_top_level_symlinks

case_output_may_not_climb_out_of_the_build_root() {
  cli deploy "$ROOT/example" --name demo --output ../../etc --dry-run
  assert_status 1 || return
  assert_contains "$(err)" "may not climb out of the build root" || return
  cli deploy "$ROOT/example" --name demo --output dist/../.. --dry-run
  assert_status 1 || return
  assert_contains "$(err)" "may not climb out of the build root" || return
  ok
}
register case_output_may_not_climb_out_of_the_build_root

case_long_name_needs_a_hash_command() {
  # Without sha256sum or shasum the hash would be empty, two long names would
  # collide on one worker, and the URL would end in a hyphen.
  local bin; bin=$(restricted_path bash env cat sed tr cut jq)
  CLI_PATH="$STUBS:$bin"
  cli url "a-very-long-branch-name-that-nobody-would-ever-type-by-hand-but-here-we-are" --subdomain acme
  assert_status 1 || return
  assert_contains "$(err)" "need sha256sum or shasum" || return
  ok
}
register case_long_name_needs_a_hash_command

case_deploy_checks_dependencies_before_uploading() {
  # The order matters: a check that runs after wrangler leaves a published
  # preview whose URL was never printed.
  unset CF_WORKERS_SUBDOMAIN
  local bin; bin=$(restricted_path bash env cat sed tr cut mktemp mkdir cp rm sha256sum tail)
  CLI_PATH="$STUBS:$bin"
  cli deploy "$ROOT/example" --name demo
  assert_status 1 || return
  assert_contains "$(err)" "need jq or python3" || return
  assert_not_contains "$(calls)" "npx" || return
  ok
}
register case_deploy_checks_dependencies_before_uploading

case_deploy_checks_credentials_before_uploading() {
  unset CLOUDFLARE_API_TOKEN
  cli deploy "$ROOT/example" --name demo
  assert_status 1 || return
  assert_contains "$(err)" "CLOUDFLARE_API_TOKEN is not set" || return
  assert_not_contains "$(calls)" "npx" || return
  ok
}
register case_deploy_checks_credentials_before_uploading

case_token_is_never_passed_in_argv() {
  # /proc makes another process's argv readable by anyone on the machine.
  cli list
  assert_status 0 || return
  assert_not_contains "$(calls)" "$CLOUDFLARE_API_TOKEN" || return
  assert_contains "$(calls)" "--config -" || return
  assert_contains "$(calls)" "curl-stdin: auth header present" || return
  cli delete demo
  assert_status 0 || return
  assert_not_contains "$(calls)" "$CLOUDFLARE_API_TOKEN" || return
  assert_contains "$(calls)" "curl-stdin: auth header present" || return
  ok
}
register case_token_is_never_passed_in_argv

case_example_site_has_no_hardening_files_checked_in() {
  # The example is a plain site on purpose: the tests above prove the
  # hardening files appear in the copy, which is meaningless if they are
  # already in the source.
  assert_no_file "$ROOT/example/robots.txt" || return
  assert_no_file "$ROOT/example/_headers" || return
  [ -f "$ROOT/example/CNAME" ] || { fail "example/CNAME is missing"; return; }
  ok
}
register case_example_site_has_no_hardening_files_checked_in

# --- run ---------------------------------------------------------------------

printf 'cf-preview tests (offline; npx, curl and git are stubbed)\n\n'
for name in "${case_names[@]}"; do
  if [ -n "$FILTER" ]; then
    case "$name" in *"$FILTER"*) ;; *) continue ;; esac
  fi
  setup_case "$name"
  "$name"
  teardown_case
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
