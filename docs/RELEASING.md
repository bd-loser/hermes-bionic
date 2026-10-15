# Releasing

This guide is for maintainers. Users should read [INSTALL.md](INSTALL.md).

## Stable release

A stable release is a normal GitHub release (not a prerelease or draft) with a
`hermes-wheels-<version>-cp314.tar.gz` bundle and its `.sha256`. The installer
selects the newest stable release that has a bundle for the phone's Python.

1. Update `versions.json` to the upstream version, or let `watch-upstream`
   do it.
2. Run `build.yml` from `main` (the default inputs use `versions.json`).
3. Check the bundle before users see it:

   ```bash
   gh release download vX.Y.Z -R bd-loser/hermes-bionic -D /tmp/check
   cd /tmp/check && sha256sum -c hermes-wheels-*-cp314.tar.gz.sha256
   ```

4. Install it on a phone with `install.sh` and run a search through
   `ddgs` (see [DUCKDUCKGO.md](DUCKDUCKGO.md)).

## Experimental builds

Use the `experimental` input on `build.yml`. It publishes to
`vX.Y.Z-exp.<run_id>` as a prerelease, and the installer never selects those
tags. Use an experimental build to test a change before it reaches the stable
tag.

Never test a change by dispatching a default build from a branch: the default
publish overwrites the stable tag.

## Failed builds

`watch-upstream` stops dispatching automatic builds after a failed build.
Fix the failure, then run `build.yml` manually. A successful manual build
resumes automatic builds.

## Rollback

If a bad bundle is published, rebuild the previous version with `build.yml`
(input `version`) to restore it. Confirm the checksum afterwards.

## Checklist before publishing

- [ ] `bash -n install.sh` and `bash -n ci/*.sh` pass
- [ ] `ci/test_regressions.py` passes
- [ ] Build succeeded from the intended commit
- [ ] Checksum verified after download
- [ ] Fresh install on a phone works
