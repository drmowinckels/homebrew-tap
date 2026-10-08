# drmowinckels/homebrew-tap

Homebrew casks for [Dr. Mowinckel's](https://drmowinckels.io) macOS apps.

```sh
brew tap drmowinckels/tap
brew trust drmowinckels/tap
brew install --cask entracte
```

The repository is named `homebrew-tap`, so Homebrew resolves it from the short
name alone — no URL argument, unlike the per-repo taps this replaces.

`brew trust` is not optional and not specific to this tap: current Homebrew
refuses to load a cask from any third-party tap until you trust it, with
`Refusing to load cask … from untrusted tap`. Trusting a tap says you accept
that its casks run code from somewhere outside Homebrew's own repositories.

## What's here

| Cask       | App                                                                       | Status                                        |
| ---------- | ------------------------------------------------------------------------- | --------------------------------------------- |
| `entracte` | [Entracte](https://github.com/drmowinckels/entracte) — break reminder     | Tracks the stable line                        |
| `cairn`    | [Cairn](https://github.com/drmowinckels/cairn) — local-first time tracker | Not packaged yet — no stable release upstream |

Casks track **stable releases only.** A `brew` install cannot see an app's
in-app update-channel setting, so it has no way to opt out of a beta that
`brew upgrade` pushed onto it. To run betas, install from the app's releases
page and switch the channel in its preferences.

## Updating

`brew upgrade --cask entracte`, as usual. Homebrew refreshes the tap on its
own schedule; `brew update` forces it.

## Adding a cask

1. Write `Casks/<token>.rb`.
2. Add a `case` branch for `<token>` in [`scripts/bump-cask.sh`](scripts/bump-cask.sh)
   naming the upstream repo and the release assets each checksum comes from.
3. Add a row to the table above.

Step 2 is not optional. The bump job iterates over every file in `Casks/` and
fails the run on a cask it has no configuration for, rather than skipping it
quietly — a cask nobody bumps is worse than no cask at all, because
`brew upgrade` reports success while installing a version that is months old.

## How bumping works

[`bump-casks.yml`](.github/workflows/bump-casks.yml) runs hourly, asks each
upstream repo for its latest non-prerelease release, and commits any cask that
has fallen behind.

It polls rather than being pushed to, which is the unusual choice, for two
reasons:

- **No credential.** `GITHUB_TOKEN` is scoped to the single repository running
  the workflow regardless of who owns the others, so a push-based bump would
  need a PAT or deploy key copied into every app repo. Polling public release
  metadata needs no secret.
- **It recovers on its own.** Entracte's previous in-repo bump failed on eleven
  consecutive releases with nobody noticing, leaving the cask stranded behind
  the current release ([entracte#349](https://github.com/drmowinckels/entracte/issues/349)).
  This job re-derives the desired state from scratch every hour, so a tick that
  fails for any reason is repaired by the next one.

The cost is latency: a release can take up to an hour to reach `brew`. Nobody
notices, and `workflow_dispatch` is there when you want it now.

Two things worth knowing:

- **GitHub disables scheduled workflows after 60 days of repository
  inactivity.** Bump commits count as activity, so an app that ships at all
  regularly keeps this alive by itself. If every app here goes quiet for two
  months, GitHub emails the owner first, and any push re-enables the schedule.
- **The poller refuses to go backwards.** A release-triggered push can only
  ever move forward; a poller reading "latest" would happily follow it down if
  a release were deleted or un-published, handing every user a downgrade.
  `bump-cask.sh` compares versions and fails the run instead.

## Migrating from the old per-repo taps

Nothing to do. Each app repo carries a `tap_migrations.json` pointing its cask
here, so an existing install follows the move on the next `brew upgrade`. The
old taps can be removed at leisure:

```sh
brew untap drmowinckels/entracte
```
