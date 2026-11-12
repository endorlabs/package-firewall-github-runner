# Endor Labs Package Firewall runner image

CI jobs install packages from public registries, and a malicious package's install script runs with the job's secrets. This repository builds a GitHub-hosted runner image that sends npm, pip, Maven, Gradle, Go, NuGet, gem, and Bundler installs through [Endor Labs Package Firewall](https://docs.endorlabs.com/package-firewall). Known malicious packages, including transitive dependencies, are blocked before they download. Your [Package Firewall policy](https://docs.endorlabs.com/package-firewall/policy) decides what else is warned or blocked.

Workflows opt in by replacing `runs-on: ubuntu-latest` with:

```yaml
runs-on:
  group: ubuntu-latest-endor
```

Once every workflow has moved, disable GitHub's standard runners. Jobs can then only run on the firewall image.

## How it works

| | Name | What it is |
|---|---|---|
| Build machine | `ubuntu-latest-endor-builder` | Ubuntu larger runner. The build workflow configures the firewall here and saves a snapshot. |
| Disk image | `ubuntu-latest-endor-image` | The saved disk, under the organization's **Actions → Custom images**. |
| Job runner | `ubuntu-latest-endor` | Larger runner that boots from `ubuntu-latest-endor-image`. Workflows run here. |

Each runner sits alone in a runner group of the same name, and workflows target the group. Never add another runner to these groups, or jobs can land on a machine without the firewall. The build runs every Monday on GitHub's latest Ubuntu image. It only saves a new version if a normal install succeeds and Endor's test package is blocked.

## Setup

Requires GitHub Team or Enterprise Cloud. Step 1 needs an enterprise owner. Steps 4, 5, 7, and 10 need an organization owner.

0. Create your own copy. On this repository's page, click **Use this template** → **Create a new repository**, choose your organization as the owner, and set visibility to **Private**. Don't fork it: the build workflow does not run in forks. Every later step refers to your copy as "this repository".
1. Allow custom images. An enterprise owner opens github.com, clicks their profile picture (top right) → **Your enterprises** → the enterprise → **Policies** → **Actions**, and under **Custom images** enables them for your organization. In the same section, set the retention policy to keep two versions: the current one and one to roll back to.
2. In Endor Labs, create an API key with only the Package Firewall User role, and set an expiration date. Note the namespace and the host: `factory.endorlabs.com` (US) or `factory.eu.endorlabs.com` (EU).
3. Add secrets and variables to this repository. Open this repository on github.com → **Settings** tab → left sidebar **Secrets and variables** → **Actions**. Add secrets with **New repository secret**, then open the **Variables** tab and add variables with **New repository variable**.

   | Type | Name | Value |
   |---|---|---|
   | Secret | `ENDOR_PFW_API_KEY` | API key from step 2 |
   | Secret | `ENDOR_PFW_API_SECRET` | API secret from step 2 |
   | Variable | `ENDOR_NAMESPACE` | Your Endor Labs namespace |
   | Variable | `ENDOR_PFW_HOST` | `factory.endorlabs.com` or `factory.eu.endorlabs.com` |

4. Create two runner groups. Open your organization on github.com (`https://github.com/<org>`) → **Settings** tab → left sidebar **Actions** → **Runner groups** → **New runner group**. For each group, set **Repository access** as below, and leave **Allow public repositories** off.

   | Group name | Repository access |
   |---|---|
   | `ubuntu-latest-endor-builder` | **Selected repositories**: this repository only |
   | `ubuntu-latest-endor` | **All repositories** |

5. Create the build machine. In the organization, **Settings** → **Actions** → **Runners** → **New runner** → **New GitHub-hosted runner**.

   - Name: `ubuntu-latest-endor-builder`
   - Platform: Linux x64
   - Image: **GitHub-owned** tab → Ubuntu Latest, then tick **Enable this runner to generate custom images**
   - Size: 2-core
   - Maximum concurrency: 1
   - Runner group: `ubuntu-latest-endor-builder`

6. Build the image. Open this repository → **Actions** tab → **Build Package Firewall runner image** in the left list → **Run workflow** → **Run workflow**. When it succeeds, open the organization's **Settings** → **Actions** → **Custom images** and wait until `ubuntu-latest-endor-image` shows as ready. This can take minutes to several hours.
7. Create the job runner. In the organization, **Settings** → **Actions** → **Runners** → **New runner** → **New GitHub-hosted runner**. Leave image generation off.

   - Name: `ubuntu-latest-endor`
   - Platform: Linux x64
   - Image: **Custom** tab → `ubuntu-latest-endor-image`, version **Latest**
   - Size: 2-core or larger
   - Maximum concurrency: the most jobs you expect to run at once
   - Runner group: `ubuntu-latest-endor`

8. Run **Verify Package Firewall runner** from this repository's **Actions** tab. Every check must pass:

   ```
   PASS: lodash installed via Package Firewall
   PASS: endor-firewall-test blocked with 403
   PASS: requests installed via Package Firewall
   PASS: endor-firewall-test (pypi) blocked with 403
   PASS: commons-lang3 installed via Package Firewall
   PASS: endor-java-webapp-demo blocked with 403
   PASS: endor-java-webapp-demo blocked with 403 (mvnw after setup-java)
   PASS: commons-lang3 installed via Package Firewall (gradle)
   PASS: endor-java-webapp-demo (gradle) blocked with 403
   PASS: github.com/google/uuid installed via Package Firewall
   PASS: endor-firewall-test (go) blocked with 403
   PASS: Newtonsoft.Json installed via Package Firewall
   PASS: endor-firewall-test (nuget) blocked with 403
   PASS: minitest installed via Package Firewall
   PASS: endor-firewall-test (gem) blocked with 403
   PASS: minitest installed via Package Firewall (bundler)
   PASS: endor-firewall-test (bundler) blocked with 403
   ```

   Blocked installs appear in the [Package Firewall logs](https://docs.endorlabs.com/package-firewall/logs).

9. Move workflows. In each workflow file (`.github/workflows/*.yml`) of the repositories in the `ubuntu-latest-endor` group, replace `runs-on: ubuntu-latest` with the `runs-on` block at the top of this page.
10. Enforce it. When every workflow has moved, open the organization's **Settings** → **Actions** → **General**, and under **Standard hosted runners** choose **Disable for all repositories**, then **Save**.

## ARM64 (optional)

The same workflows build and verify an ARM64 image alongside x64. Each architecture has its own build machine, image, and job runner.

| | x64 | ARM64 |
|---|---|---|
| Build machine and group | `ubuntu-latest-endor-builder` | `ubuntu-latest-arm-endor-builder` |
| Disk image | `ubuntu-latest-endor-image` | `ubuntu-latest-arm-endor-image` |
| Job runner and group | `ubuntu-latest-endor` | `ubuntu-latest-arm-endor` |

1. In this repository, **Settings** → **Secrets and variables** → **Actions** → **Variables** tab → **New repository variable**: name `PFW_ARM64`, value `true`.
2. Create the runner groups `ubuntu-latest-arm-endor-builder` and `ubuntu-latest-arm-endor` as in step 4.
3. Create the build machine as in step 5, with name `ubuntu-latest-arm-endor-builder`, platform **Linux ARM64**, an Ubuntu image with **Enable this runner to generate custom images** ticked, and runner group `ubuntu-latest-arm-endor-builder`.
4. Run **Build Package Firewall runner image**. It now builds both images. Wait until `ubuntu-latest-arm-endor-image` shows as ready under **Custom images**.
5. Create the job runner as in step 7, with name `ubuntu-latest-arm-endor`, platform **Linux ARM64**, image **Custom** → `ubuntu-latest-arm-endor-image` version **Latest**, and runner group `ubuntu-latest-arm-endor`.
6. Run **Verify Package Firewall runner**. It checks both job runners.

ARM64 workflows use:

```yaml
runs-on:
  group: ubuntu-latest-arm-endor
```

## Operations

- **Weekly rebuild.** Keep the schedule enabled. It applies GitHub's Ubuntu patches, and custom images expire under the enterprise retention policy. The job runner follows **Latest**, so it picks up each new version.
- **Storage.** Each build saves a new version of about 75 GB, and every retained version is billed as Actions storage beyond the plan's included amount (75 GB on Team, 150 GB on Enterprise Cloud). See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions). Keeping two versions caps it at about 150 GB per architecture.
- **Key rotation.** Before the API key expires, create a new one, update both secrets, and run **Build Package Firewall runner image**. The old key stays in older image versions until they are deleted.

## Layout

```
.github/workflows/build-pfw-runner-image.yml   weekly and manual image build (x64, optional ARM64)
.github/workflows/verify-pfw-runner.yml        check of the job runners
scripts/configure-pfw.sh                       writes package manager config
scripts/verify-pfw.sh                          normal install must pass, test package must 403
```

## Security

The API key is in the image, and any job on `ubuntu-latest-endor` can read it. Use a key with only the Package Firewall User role, which only grants access to the firewall. Don't run untrusted code on the job runner, such as pull requests from forks: leave **Allow public repositories** off on the runner groups. Anyone who can run the build workflow can publish a new image version, so keep the `-builder` groups limited to this repository and restrict who has write access to it.

## Known gaps

- A project `.npmrc` or `actions/setup-node` `registry-url` that sets its own registry overrides the image.
- Maven, including the Maven Wrapper (`./mvnw`), gets the firewall through `/etc/mavenrc`. A job that sets `MAVEN_SKIP_RC` skips that file.
- Gradle gets the firewall from `~/.gradle/init.d/endor-firewall.gradle`, which redirects only Maven Central. Plugins from the Gradle Plugin Portal and libraries from Google's Maven repository are not checked. A job that sets `GRADLE_USER_HOME` skips the init script.
- A `GOPROXY` environment variable set by a job overrides the image. Modules matched by `GOPRIVATE` or `GONOPROXY`, and modules the firewall returns 404 or 410 for, are fetched directly from source.
- NuGet gets the firewall from `~/.nuget/NuGet/NuGet.Config`, which clears every other source. A `DOTNET_CLI_HOME` environment variable makes NuGet read the config from that directory instead. A repository `nuget.config`, a `dotnet restore --configfile`, or `RestoreAdditionalProjectSources` that adds nuget.org is not checked.
- gem gets the firewall from `~/.gemrc`. `gem install --source` skips it.
- Bundler gets the firewall from a global mirror of `https://rubygems.org` in `~/.bundle/config`. Fallback to rubygems.org is turned off. A project `.bundle/config` overrides the mirror, and a Gemfile source other than rubygems.org is fetched directly.

## License

[MIT](LICENSE). Provided as is, without warranty of any kind.
