# Releasing

ShopNexus runs two stacks on the cluster, `stack-dev` and `stack-prod`
(`infra/argocd/stacks.yaml`). Dev follows `main` on its own. Prod changes only
when someone runs a release.

Prod has not been released yet: there is no `v*` tag, and `stack-prod` names
`v0.1.0`, which the first release replaces.

## Dev

1. A push to `main` of `server`, `clients` (website, console), `docs` or
   `agent` runs that repository's CI. The CI builds the image once and tags it
   `:main` and `:sha-<commit>`.
2. Argo CD Image Updater sees the new `:main` digest and rolls `stack-dev`
   (namespace `shopnexus-dev`) within minutes.
3. `stack-dev` reads the chart and `values-dev.yaml` from the umbrella's
   `main`, so a push of `infra/` reaches dev too.
4. Each sync runs the migration jobs first (wave 1), then the server
   (wave 2), then the website and the console (wave 3).

The umbrella's submodule pointers do not matter for dev. They choose what the
next prod release ships, and what the API contract check compares.

## Prod

A release is one version for everything on the cluster, `X.Y.Z`:

| Part | When |
|---|---|
| minor, `1.4.0` → `1.5.0` | a release with new features: what `main` has |
| patch, `1.4.0` → `1.4.1` | a hotfix |
| major, `1.x` → `2.0.0` | a milestone, or a change old app versions cannot follow |

To release:

1. Bump the umbrella's submodules to the commits you want and push `main`.
2. Run `infra/release-plan.sh` (or read the plan of the release run). It
   prints, for each image, the commit prod runs and the commit the release
   would run:

   ```
   | image   | prod now | this release |                   |
   | server  | 13aa05d9 | 13aa05d9     | unchanged         |
   | website | 991ff690 | f9cc614f     | rolls (2 commits) |
   ```

   If it shows something you did not mean to ship, stop and fix `main` first.
3. Actions → Release → Run, with the version. The workflow:
   - finds each image CI built: server, docs and agent at their submodule's
     commit; website and console at the last `clients` commit that changed
     `website/` or `brand/web/`, and `console/`. One missing image stops the
     release before anything is tagged;
   - tags every image `X.Y.Z`, so GHCR shows what each release ran;
   - writes each image's digest and commit into `infra/stack/values-prod.yaml`
     and `vX.Y.Z` into `stack-prod`, commits `release X.Y.Z`, tags it `vX.Y.Z`
     and pushes;
   - Argo CD then syncs `stack-prod` (namespace `shopnexus-prod`).

Prod pins images by digest, so prod runs exactly what dev ran. An image whose
digest did not change renders the same manifest, and Argo CD leaves its pods
running. A hotfix of the website restarts only the website.

A release also ships:

- every change to `infra/` (chart, `values-prod.yaml`, the shared env files)
  that reached `main` since the last release, because `stack-prod` moves to
  the new umbrella tag;
- a fresh run of the migration jobs. With no new migration they finish at
  once and change nothing.

### Hotfix

Say prod runs `1.4.0` and the website has a bug:

1. Fix it on `clients` `main`. CI builds the image and dev runs it.
2. Check the fix on dev.
3. Bump `clients` in the umbrella and push.
4. Run `infra/release-plan.sh`: only `website` should roll.
5. Release `1.4.1`.

### Rollback

Revert the `release X.Y.Z` commit on the umbrella's `main` and push. Argo CD
goes back to the previous digests.

## Rules that keep this safe

- **`main` is always releasable.** Whatever is merged has run on dev and can
  ship. Unfinished work stays off `main`, or later behind a feature flag. The
  system has no feature flags yet.
- **The server stays backward compatible.** During a rollout the old website
  talks to the new server for a short while, and old app versions talk to it
  for months. Add a field or an endpoint first, move the clients to it, and
  remove the old one in a later release (expand, then contract).
- **Nothing is changed by hand on prod.** Every change goes through `main`,
  dev, then a release.

## The Android app

The app is not part of `X.Y.Z`: a store release takes review, rolls out in
stages and cannot be pulled back. It will get its own line, a tag
`app-vX.Y.Z` in `clients` that builds a signed bundle for Google Play. That
pipeline does not exist yet; the app's `live` flavor runs against the dev API.
