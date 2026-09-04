# cf-preview

`cf-preview` puts a static site on a throwaway `*.workers.dev` URL so someone
who is not on GitHub can look at a change in a browser and say yes or no. It is
one bash script: deploy a directory or a git ref, send the link, delete the
preview when the answer comes back.

The problem it solves: branch links and PR previews assume the approver has an
account on your forge or your hosting platform. A client, a colleague in
marketing, or an external reviewer usually has neither, and screenshots do not
let them click anything.

## Requirements

- `bash` 4 or newer (developed and tested on bash 5), `curl`, and `sed`, `tr`,
  `cut` from coreutils
- `jq` or `python3`, to read Cloudflare API responses. Only `list`, `delete`
  and the `workers.dev` subdomain lookup need one; set `CF_WORKERS_SUBDOMAIN`
  and `deploy` does not
- `sha256sum` or `shasum`, used only to shorten names over 54 characters
- `node` with `npx`, which fetches `wrangler` on first use
- `git`, if you deploy a git ref rather than a directory
- A Cloudflare account with a registered `workers.dev` subdomain

## Quickstart

1. Put the script on your `PATH` and export credentials. They are read from the
   environment only; `cf-preview` never writes them anywhere.

   ```sh
   export CLOUDFLARE_API_TOKEN=...      # scope below
   export CLOUDFLARE_ACCOUNT_ID=...     # Cloudflare dashboard, Workers page
   ```

2. Deploy a built site directory, or a git ref plus the command that builds it.

   ```sh
   cf-preview deploy ./public --name pricing-copy
   cf-preview deploy feature/pricing --name pricing-copy --build "npm run build" --output dist
   ```

   Both print one receipt line:

   ```
   deployed: preview-pricing-copy  https://preview-pricing-copy.<your-subdomain>.workers.dev/  (from ./public)
   ```

3. Send that URL. When the answer comes back, take the preview down.

   ```sh
   cf-preview delete pricing-copy
   ```

Add `--dry-run` to any command to see exactly what it would run without doing
it.

## The approver workflow

1. `cf-preview deploy ... --name <slug>` and copy the URL from the receipt.
2. Post the URL wherever the approver already is: a chat thread, an email, a
   ticket comment. They click, they look, they answer.
3. `cf-preview delete <slug>`. Previews do not expire on their own, so this
   step is yours. `cf-preview list` shows every preview still alive.

Redeploying the same `--name` replaces the site behind the same URL, so an
approver can keep one link open across several rounds of changes.

## Hardening, and why it is on by default

A `*.workers.dev` URL is public. Without care, a preview of your site can be
crawled and indexed, and then it competes with the real site in search results
or leaks unreleased copy into a search index. So `cf-preview` hardens every
deploy, and there is no flag to turn it off:

- `robots.txt` with `User-agent: *` and `Disallow: /` is written into the
  preview, so crawlers that read it do not fetch the pages.
- `_headers` with `X-Robots-Tag: noindex, nofollow` is written into the
  preview. Workers static assets applies `_headers` to asset responses, so a
  crawler that ignores `robots.txt` still gets told not to index the page. If
  your build already produces a `_headers` file, the rule is appended to a copy
  of it and your own rules are kept, so the preview renders under the same
  header rules as production. If you would rather not depend on `_headers` at
  all, `--header-worker` deploys a small worker that sets the same header on
  every response in code and serves the assets through it.
- A `CNAME` file at the top of the output is removed from the preview, so a
  preview never carries your production hostname.
- Every top-level entry whose name begins with a dot is removed from the
  preview, `.well-known` excepted. Point `cf-preview` at a directory that was
  never built for publishing, such as a repository root, and it would otherwise
  serve `.git`, `.env`, `.npmrc`, `.netrc` and `.ssh` on a public URL. The
  names dropped are printed on stderr.
- Every top-level symlink is removed from the preview rather than followed.
  Following one would copy the file it points at, which is how a link named
  `passwd.html` publishes `/etc/passwd`.

Two things this is not. It is not access control: anyone with the link can
read the site, and `X-Robots-Tag` is a request to well-behaved crawlers, not a
lock. If the content must not be seen by strangers, do not use a public
preview. And the hardening is applied to a **copy** of your build output in a
temporary directory. Your source tree and your build output are read and never
modified, so nothing here can leak into a production deploy.

When you pass a git ref, the build runs in a detached `git worktree` of that
ref, not in your working tree. Whatever you have half-finished on disk cannot
end up in something an approver signs off on. `--no-worktree` opts out (useful
when the build needs an installed `node_modules` in the checkout) and says so
on stderr when it does.

## API token scope

Create a token at Cloudflare with one account permission:

- **Workers Scripts: Edit**

That is the permission the four operations map to: uploading the preview
through `wrangler`, listing scripts, deleting a script, and reading the
account's `workers.dev` subdomain. Nothing `cf-preview` itself sends needs Zone
permissions, DNS, or account settings.

Treat that as the starting point rather than a guarantee. `wrangler` is a
separate program on a release cadence of its own, and Cloudflare's own CI
guidance points people at the broader **Edit Cloudflare Workers** token
template, which bundles several permissions. If a deploy fails with a
permission error, widen the token one permission at a time and please open an
issue saying which one was needed. Setting `CF_WORKERS_SUBDOMAIN` removes the
subdomain endpoint from the picture entirely, so the token only has to satisfy
`wrangler`, `list` and `delete`.

A narrower token is worth the two minutes. This token can overwrite and delete
Workers on the account it is scoped to, so scope it to the one account you use
for previews and give it no other permission. A broad token that can also touch
DNS or zone settings turns a leaked preview credential into a leaked production
credential. If you can, use a separate Cloudflare account for previews.

`cf-preview` reads the token from `CLOUDFLARE_API_TOKEN` at run time and never
stores it. The token is handed to `curl` as a config on standard input rather
than as an argument, because on Linux any process on the machine can read
another process's arguments out of `/proc`. `--dry-run` prints the request it
would send with the token left as the literal string `$CLOUDFLARE_API_TOKEN`,
so dry-run output is safe to paste into a ticket. What `wrangler` does with the
token once it has it in the environment is `wrangler`'s business, not this
tool's.

Set `CF_WORKERS_SUBDOMAIN` to your `workers.dev` subdomain to skip the lookup
call, or pass `--subdomain`.

## Cost

Cloudflare's free Workers plan covers this use. A preview is a static site on
`workers.dev`, and the default deploy contains no worker code at all, only
assets. `--header-worker` does add a worker that runs on every request, which
counts against Workers request limits.

`cf-preview` never calls a billing API and cannot tell you what your account is
actually charged. Check Cloudflare's current Workers pricing before you assume,
and delete previews you are finished with.

## Limits

- Anyone with the link can read the preview. There is no password.
- Previews never expire. `cf-preview list` and `cf-preview delete` are how they
  go away.
- Static files only. No server-side rendering, no bindings, no secrets, no
  environment variables reach the preview.
- `_headers` is capped by Cloudflare at 100 rules and 2000 characters per
  line. A site already close to that ceiling loses the noindex rule this tool
  appends, so use `--header-worker` there.
- If your own `_headers` already sets `X-Robots-Tag`, the preview sends both
  values joined by a comma rather than the appended rule winning. A site that
  deliberately sets `index` needs `--header-worker`, which sets the header in
  code after the asset response is built.
- `--header-worker` runs a Worker on every request. On the free plan, requests
  over the daily limit are answered with HTTP 429 rather than falling back to
  serving the asset, so a preview that goes viral goes down. The default
  assets-only deploy has no such failure mode.
- Symlinks below the top level of the output are copied as symlinks and are
  not swept. Only the top level is checked.
- The worker name is `<prefix>-<slug>`, lowercased with everything outside
  `a-z0-9` collapsed to hyphens. Names longer than 54 characters are truncated
  and given a hash suffix, so two long names cannot collide.
- `list` and `delete` identify previews by name prefix and nothing else. If a
  real worker on the account is called `preview-something`, `delete` will
  delete it. Use `--prefix` to pick a prefix that only previews use.
- The first `deploy` on a machine downloads `wrangler` through `npx`, which
  needs network access and takes a while.
- A positional argument that is an existing directory is deployed as is;
  anything else is treated as a git ref. A ref that shares its name with a
  directory in your current directory will be read as the directory.

## Development

```sh
make test     # or ./test/run.sh
make check    # bash -n on every script, plus shellcheck if it is installed
```

The tests are plain bash and run offline. `npx`, `curl` and `git` are replaced
by stubs on `PATH` that record their arguments, so no test deploys anything,
contacts Cloudflare, or touches a repository. `./test/run.sh <substring>` runs a
subset.

`example/` is a small static site the tests deploy against. To watch a whole
deploy without a Cloudflare account:

```sh
./cf-preview deploy ./example --name demo --dry-run
```

## License

Apache-2.0. Copyright 2026 Archbotics Oy. See `LICENSE`.
