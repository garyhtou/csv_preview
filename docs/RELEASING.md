# Releasing csv_preview

This is the maintainer's checklist: the one-time steps to take the repository public and publish the first release, then the steps for every release. The reasoning is in [`spec/branding-and-discoverability.md`](./spec/branding-and-discoverability.md) sections 4.3, 5.4, 5.5, 6.1 and 6.2. Commands use the [GitHub CLI](https://cli.github.com) (`gh`) where it can do the step, and name the settings page where it cannot.

## One-time setup

Do these in order. The order matters for steps 4 and 5.

### 1. Pre-public pass, then make the repository public

Once public, the full history is public, so look first.

- Scan the working tree and every commit for secrets with a scanner such as [gitleaks](https://github.com/gitleaks/gitleaks) (`gitleaks detect --source . --log-opts="--all"`) or [trufflehog](https://github.com/trufflesecurity/trufflehog) (`trufflehog git file://. --only-verified`).
- Grep the whole history for things a scanner will not know: absolute local paths (`git log --all -p | grep -nE '/(Users|home)/[a-z]'`), private notes, internal project or organisation names, and real names, emails or phone numbers in fixtures and images. Fixtures and brand images use fictional data.
- Check that no private notes or planning files are tracked (`git ls-files`).
- If anything turns up, rewrite the history (for example with `git filter-repo`) before going public, not after.

Then make the repository public:

```sh
gh repo edit garyhtou/csv_preview --visibility public --accept-visibility-change-consequences
```

### 2. About description, website, topics and social preview

The description is the copy deck's GitHub description (spec 1.3, used word for word); the website and topics are from spec 4.3.

```sh
gh repo edit garyhtou/csv_preview \
  --description "Beautiful CSV previews for Ruby and Rails. Renders CSV and TSV files to PNG, JPEG or WebP with libvips and adds an Active Storage previewer. No LibreOffice, headless browser or network." \
  --homepage "https://rubygems.org/gems/csv_preview" \
  --add-topic ruby,ruby-gem,rails,ruby-on-rails,activestorage,active-storage,csv,tsv,csv-preview,file-preview,preview,thumbnail,thumbnails,thumbnail-generator,libvips,vips,pango,image-generation
```

That is 18 topics; GitHub allows 20, so two stay free for later.

In the browser:

- On the repository page, click the gear next to **About**. Tick **Releases**; untick **Packages** and **Deployments** (empty sections look unfinished).
- Settings > General > **Social preview** > Edit > Upload an image: `docs/assets/brand/social-preview.png`.

### 3. Private vulnerability reporting and Dependabot

`SECURITY.md` points reporters at private vulnerability reporting, so it must be on.

```sh
gh api -X PUT repos/garyhtou/csv_preview/private-vulnerability-reporting
gh api -X PUT repos/garyhtou/csv_preview/vulnerability-alerts
gh api -X PUT repos/garyhtou/csv_preview/automated-security-fixes
```

Confirm in Settings > Code security that "Private vulnerability reporting", "Dependabot alerts" and "Dependabot security updates" are enabled. Version updates are configured by `.github/dependabot.yml` in the repository.

### 4. Create the `release` environment, before anything on RubyGems.org

The release workflow names `environment: release`. A workflow that names an environment that does not exist creates it on the spot, unprotected, so a tag alone could publish. Creating the protected environment first closes that gap (spec 5.4). Required reviewers are available only on public repositories, which is why this comes after step 1.

Settings > Environments > New environment > `release`, then:

- **Required reviewers:** add yourself.
- **Deployment branches and tags:** "Selected branches and tags", add a rule of type **Tag** with the pattern `v*`.

Or with the API:

```sh
OWNER_ID="$(gh api users/garyhtou --jq .id)"
gh api -X PUT repos/garyhtou/csv_preview/environments/release --input - <<JSON
{
  "reviewers": [{ "type": "User", "id": $OWNER_ID }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
gh api -X POST repos/garyhtou/csv_preview/environments/release/deployment-branch-policies \
  -f name='v*' -f type=tag
```

### 5. RubyGems.org: MFA and the pending trusted publisher

1. Sign in at [rubygems.org](https://rubygems.org), open Settings > Multi-factor authentication, and enable MFA (a security key or authenticator app, level "UI and API"). The gem's `rubygems_mfa_required` metadata makes RubyGems.org require MFA for owner actions on the gem, such as adding owners or pushing by hand. The release workflow's push needs no MFA code: trusted publishing satisfies the requirement.
2. Open [Trusted publishers](https://rubygems.org/profile/oidc/pending_trusted_publishers) in your profile, create a pending publisher, choose **GitHub Actions**, and enter:

   | Field | Value |
   |---|---|
   | RubyGem name | `csv_preview` |
   | Repository owner | `garyhtou` |
   | Repository name | `csv_preview` |
   | Workflow filename | `release.yml` |
   | Environment | `release` |

   The first successful push turns the pending publisher into a normal one and makes you the gem's owner. No API key is created or stored anywhere.

   Two things the publisher page tells you once it is saved:

   - **It is valid for about 12 hours.** Do the first release within that window, or delete and recreate it.
   - **The workflow must name the owner.** RubyGems.org shows your account's numeric ID and rejects a first push whose token exchange does not include it. `release.yml` does the exchange itself and sends that ID as `owner` (the `RUBYGEMS_OWNER` value), because `rubygems/release-gem` has no owner input yet. If you are not the account with the ID in `release.yml`, change it to the ID your publisher page shows.

### 6. Run the macOS workflow on every push

While the repository was private, `.github/workflows/macos.yml` ran only by hand, because macOS minutes cost ten times Linux minutes on private repositories. They are free on public ones, so change the trigger (and the header comment above it, which describes the manual-only setup):

```yaml
# before
on:
  workflow_dispatch:

# after
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

Commit it, and check the first run is green.

### 7. Re-measure performance on an idle machine

The README numbers were taken with other work running, so they are upper bounds. Close other applications, then from a checkout:

```sh
bundle exec bin/benchmark
bundle exec ruby --yjit bin/benchmark
```

Update the numbers in two places in `README.md`: the table and its environment line (machine, macOS, Ruby and libvips versions, date, and the "other work running" caveat) in the **Performance** section, and the paragraph in the FAQ answer "How fast is csv_preview?". `bin/benchmark` prints the environment line it ran in.

### Optional, after going public

- Submit the repository at [context7.com/add-library](https://context7.com/add-library) so coding agents can fetch its docs (spec 4.1).
- Read the README on github.com in light and dark themes and on a phone (spec 6.1): images load, tables scroll, nothing overflows.

## Every release

Steps 1 to 4 prepare the commit; steps 5 onward publish it. For the first release the version is `0.1.0`.

1. **Move the CHANGELOG entry.** In `CHANGELOG.md`, rename `## [Unreleased]` to a dated release, add a fresh empty `Unreleased` above it, and fix the link definitions at the bottom ([Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)). For the first release, delete the line "The first release, to be published as 0.1.0." and end up with:

   ```markdown
   ## [Unreleased]

   ## [0.1.0] - 2026-11-20

   ### Added

   - ...the existing entries...

   [Unreleased]: https://github.com/garyhtou/csv_preview/compare/v0.1.0...HEAD
   [0.1.0]: https://github.com/garyhtou/csv_preview/releases/tag/v0.1.0
   ```

   There is no earlier tag to compare with, so 0.1.0 links to its tag. For a later release, `[0.2.0]` links to `compare/v0.1.0...v0.2.0` and `[Unreleased]` to `compare/v0.2.0...HEAD`. Use the real date.
2. **Set the version** in `lib/csv_preview/version.rb` (`CsvPreview::VERSION`). It is already `0.1.0` for the first release. Later, follow [SemVer](https://semver.org/spec/v2.0.0.html) as the CHANGELOG describes: before 1.0 a breaking change bumps the minor version and its entry has an "Upgrading" note; fixes bump the patch. Rendered pixels are not part of the API, so a change in how previews look is not a breaking change, but the entry must say it.
3. **Regenerate the brand images** if rendering changed since the last release: run the "Brand images" workflow and commit its artifact (see CONTRIBUTING.md).
4. **Check locally and on CI.** Run `bundle exec rake docs:check` and `bundle exec rake test`, commit, push to `main`, and wait for CI to go green on that commit (`gh run list --commit "$(git rev-parse HEAD)"`, then `gh run watch`).
5. **Tag and push.** The tag must be `v` plus the version, or the workflow stops before publishing:

   ```sh
   git tag -a v0.1.0 -m "csv_preview 0.1.0"
   git push origin v0.1.0
   ```

6. **Approve the deployment.** Open the "Release" run in the Actions tab (`gh run list --workflow release.yml`), click **Review deployments**, tick `release` and approve. The run builds the gem, publishes it through trusted publishing and uploads Sigstore attestations.
7. **Check the RubyGems page**, [rubygems.org/gems/csv_preview](https://rubygems.org/gems/csv_preview):
   - the version is listed, with the Homepage, Source Code, Documentation, Changelog and Bug Tracker links;
   - "Built and signed on GitHub Actions" appears with links to the build, commit and workflow;
   - "New versions require MFA" appears.

   If the provenance panel is missing, the attestation upload failed and the action fell back to pushing without it, as happened on RubyGems.org in October 2025 ([status page](https://status.rubygems.org/incidents/5r3wp6tnf5xp)). Check [status.rubygems.org](https://status.rubygems.org) and the "Release" run's log. A published version cannot be pushed again, so the fix is the next release; yank the version (`gem yank csv_preview -v 0.1.0`) only if it is also broken.
8. **Create the GitHub Release** with the CHANGELOG entry as its notes. Copy the entry's body (everything under its `## [0.1.0]` heading, without the link definitions) into a file and pass it in:

   ```sh
   gh release create v0.1.0 --verify-tag --title "csv_preview 0.1.0" --notes-file notes.md
   ```

9. **Confirm rubydoc.info** renders the README with images at [rubydoc.info/gems/csv_preview](https://rubydoc.info/gems/csv_preview). It builds on first request and is occasionally down; try again later if it is.
10. **Check RubyGems search** (spec 6.2). Search [rubygems.org](https://rubygems.org) for "csv preview", "csv thumbnail", "active storage previewer" and "csv png". csv_preview should appear for each; search indexing can lag a few minutes.

## After release

Announcements (RubyFlow, the Rails forum, newsletters, and the schedule for the first two weeks) are in spec sections 6.2 and 6.3. Lead with the problem and a picture.
