---
name: release
description: Publish what is on origin/main as a new AIPace version, from the version bump to the GitHub release with the DMG.
disable-model-invocation: true
---

# Release

Pushing a `v<version>` tag runs `.github/workflows/release.yml`, which builds the DMG and publishes the GitHub release. That workflow requires the tag to match `Info.plist` and `CHANGELOG.md` to hold a section for the version. This skill merges that version bump into `main`, then pushes the tag.

**Invoking `/release` is Nacho's approval for every git write in this flow: the commit, the branch push, the PR, the merge and the tag push. Run them without asking.** The version number is the only question. A failed check or command halts the run: report what failed and the state it left (branch, PR, tag).

The release is `origin/main` as it stands. All edits happen in a temporary worktree at `/tmp/ai-pace-release-<version>`, so the checkout `/release` was invoked from, and any uncommitted work in it, stays untouched. Pass `--repo NachoJorquera/ai-pace` to every `gh` command, because `gh` resolves to the upstream parent by default.

## 1. Preconditions

```bash
git fetch origin --tags --prune
git cat-file -e origin/main:.github/workflows/release.yml
git show origin/main:CHANGELOG.md
git tag -l 'v*' --sort=-v:refname | head -1
```

Done when `release.yml` exists on `origin/main`, the `## [Unreleased]` section of that `CHANGELOG.md` holds at least one entry, and you know the latest tag. An empty `[Unreleased]` halts the run: there is nothing to release.

## 2. Version

Propose the next version from the latest tag and the `[Unreleased]` subsections:

- Only `### Fixed` or `### Security`: patch.
- Any other subsection (`Added`, `Changed`, `Deprecated`, `Removed`): minor.
- Major only when Nacho picks it.

Ask once with AskUserQuestion. The proposal goes first, marked (Recommended), with a one-line reason naming the entries that decided it; the other bump levels are the remaining options.

Done when the chosen version is a dotted number greater than the latest tag, and `v<version>` exists neither locally (`git tag -l v<version>`) nor on origin (`git ls-remote --tags origin v<version>`).

## 3. Version bump

```bash
git worktree add -b chore/release-<version> /tmp/ai-pace-release-<version> origin/main
```

In the worktree, make two edits:

- `app/Sources/AIPace/Info.plist`: replace the `<string>` value under `CFBundleShortVersionString` and the one under `CFBundleVersion` with `<version>`. Edit the text in place; PlistBuddy rewrites the file with every key reordered.
- `CHANGELOG.md`: add `## [<version>] - <today, date +%F>` as its own paragraph right below `## [Unreleased]`. Every entry moves under the new heading and `[Unreleased]` stays empty for the next cycle.

Done when `git -C /tmp/ai-pace-release-<version> diff --stat` lists exactly those two files, and `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString'` and `-c 'Print :CFBundleVersion'` on the edited `Info.plist` both print `<version>`.

## 4. Commit, PR and merge

Run `/verify` on the worktree right before the commit; a NOT ready verdict halts the run. Then:

```bash
git -C /tmp/ai-pace-release-<version> commit -am "chore(release): bump version to <version>"
git -C /tmp/ai-pace-release-<version> push -u origin chore/release-<version>
git worktree remove /tmp/ai-pace-release-<version>
gh pr create --repo NachoJorquera/ai-pace --base main --head chore/release-<version> \
  --title "chore(release): <version>" --body "<body>"
gh pr merge <number> --repo NachoJorquera/ai-pace --merge --delete-branch
```

The PR body is one line saying that merging and pushing `v<version>` publishes the release, followed by the new changelog section. After the merge, delete the local `chore/release-<version>` branch if it still exists.

Done when `gh pr view <number> --repo NachoJorquera/ai-pace --json state,mergeCommit` reports `MERGED` with a merge commit SHA.

## 5. Tag

```bash
git fetch origin main
git tag -a v<version> -m "AIPace <version>" <merge commit SHA>
git push origin v<version>
```

Tag the merge commit SHA from step 4, so the release is exactly the merged bump.

Done when `git ls-remote --tags origin v<version>` lists the tag.

## 6. Release run

Find the run the tag started; its `headBranch` is the tag name:

```bash
gh run list --repo NachoJorquera/ai-pace --workflow release.yml --limit 5 --json databaseId,headBranch,status,url
```

A run takes a few seconds to register, so look twice before concluding there is none. No run for the tag means Actions is not running on the fork: it needs a one-time enable from the repository's Actions tab. Report that and stop; re-pushing the tag afterwards is Nacho's call.

Watch the run with `gh run watch <id> --repo NachoJorquera/ai-pace --exit-status` as a background command; the build takes several minutes. On failure, report the output of `gh run view <id> --repo NachoJorquera/ai-pace --log-failed` and the state: the bump is merged, the tag exists, no release was published.

Done when the run succeeded and `gh release view v<version> --repo NachoJorquera/ai-pace --json url,assets` shows `AIPace-<version>.dmg` with a `sha256:` digest. Report the PR URL, the release URL and the DMG name, and that the installed app picks it up from Settings > Updates.
