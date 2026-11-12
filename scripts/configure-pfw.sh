#!/usr/bin/env bash
# Configure npm, pip, Maven, Gradle, Go, NuGet, gem, and Bundler on this machine to resolve packages through Endor Labs Package Firewall.
#
# Required env:  ENDOR_NAMESPACE, ENDOR_API_KEY, ENDOR_API_SECRET
# Optional env:  ENDOR_PFW_HOST (default factory.endorlabs.com; EU tenants use factory.eu.endorlabs.com)
#
# Writes to the user AND global config locations so the setting survives
# actions/setup-node (which redirects the *user* npmrc when registry-url is set) and
# actions/setup-java (which overwrites ~/.m2/settings.xml).
# Meant for a fresh runner: fails if any config file already exists, except the
# defaults GitHub and Maven ship, which are replaced.
set -euo pipefail

: "${ENDOR_NAMESPACE:?ENDOR_NAMESPACE is required}"
: "${ENDOR_API_KEY:?ENDOR_API_KEY is required}"
: "${ENDOR_API_SECRET:?ENDOR_API_SECRET is required}"
ENDOR_PFW_HOST="${ENDOR_PFW_HOST:-factory.endorlabs.com}"

BASE="https://${ENDOR_PFW_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall"
NPM_REGISTRY="${BASE}/npm/"
NPM_AUTH="$(printf '%s:%s' "$ENDOR_API_KEY" "$ENDOR_API_SECRET" | base64 | tr -d '\n')"

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
URL_CREDS="$(urlenc "$ENDOR_API_KEY"):$(urlenc "$ENDOR_API_SECRET")"
PIP_INDEX="https://${URL_CREDS}@${ENDOR_PFW_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"
GO_PROXY="https://${URL_CREDS}@${ENDOR_PFW_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/go/,direct"

# Keep credentials out of the job log
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::add-mask::${NPM_AUTH}"
  echo "::add-mask::${URL_CREDS}"
fi

# write_new <file> <content> [sudo]
write_new() {
  local file="$1" content="$2" sudo="${3:-}"
  if [[ -e "$file" ]]; then
    echo "::error::${file} already exists on the base image; refusing to overwrite" >&2
    exit 1
  fi
  $sudo mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" | $sudo tee "$file" >/dev/null
  echo "  configured ${file}"
}

NPM_CONFIG="registry=${NPM_REGISTRY}
//${NPM_REGISTRY#https://}:_auth=${NPM_AUTH}"

echo "npm -> ${NPM_REGISTRY}"
write_new "${HOME}/.npmrc" "$NPM_CONFIG"

# Global npmrc for every Node install on the box (system node + hosted toolcache versions)
shopt -s nullglob
for node_bin in /usr/local/bin/node /usr/bin/node /opt/hostedtoolcache/node/*/*/bin/node; do
  [[ -x "$node_bin" ]] || continue
  prefix="$(cd "$(dirname "$node_bin")/.." && pwd)"
  write_new "${prefix}/etc/npmrc" "$NPM_CONFIG" sudo
done

PIP_CONFIG="[global]
index-url = ${PIP_INDEX}"

echo "pip -> ${ENDOR_PFW_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/pypi/simple/"
write_new "${HOME}/.config/pip/pip.conf" "$PIP_CONFIG"

# GitHub's Ubuntu 24.04+ images ship this exact /etc/pip.conf. Replace it, but keep
# break-system-packages so jobs can still pip install into the system Python.
GITHUB_PIP_CONF="[global]
break-system-packages = true"
if [[ -f /etc/pip.conf && "$(< /etc/pip.conf)" == "$GITHUB_PIP_CONF" ]]; then
  sudo rm /etc/pip.conf
fi
write_new /etc/pip.conf "${PIP_CONFIG}
break-system-packages = true" sudo

MAVEN_SETTINGS="<settings>
  <servers>
    <server>
      <id>endor-firewall</id>
      <username>${ENDOR_API_KEY}</username>
      <password>${ENDOR_API_SECRET}</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>endor-firewall</id>
      <name>Endor Labs Package Firewall</name>
      <url>${BASE}/maven/</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
</settings>"

echo "maven -> ${BASE}/maven/"
write_new "${HOME}/.m2/settings.xml" "$MAVEN_SETTINGS"

# Every Maven install ships a default conf/settings.xml. Replace it so the mirror still
# applies after actions/setup-java overwrites ~/.m2/settings.xml. Its only active entry,
# a mirror that blocks plain-HTTP repositories, is redundant once * goes to the firewall.
for maven_home in /usr/share/apache-maven-*; do
  printf '%s\n' "$MAVEN_SETTINGS" | sudo tee "${maven_home}/conf/settings.xml" >/dev/null
  echo "  configured ${maven_home}/conf/settings.xml"
done

# The Maven Wrapper (./mvnw) runs its own Maven, which has its own conf/settings.xml.
# Every Maven 3 launcher sources /etc/mavenrc and passes MAVEN_OPTS to Java, and
# maven.conf picks the conf directory, so this points them all at the system Maven's.
if [[ -z "${maven_home:-}" ]]; then
  echo "::error::no Maven install found under /usr/share" >&2
  exit 1
fi
write_new /etc/mavenrc "MAVEN_OPTS=\"\${MAVEN_OPTS:-} -Dmaven.conf=${maven_home}/conf\"" sudo

# Go's per-user env file (what `go env -w` writes) is read by every Go version,
# including ones actions/setup-go installs later.
echo "go -> ${BASE}/go/"
go_env_file="$(go env GOENV)"
write_new "$go_env_file" "GOPROXY=${GO_PROXY}"

# Gradle ignores Maven's settings.xml. Gradle runs every script in ~/.gradle/init.d,
# including for ./gradlew. Only Maven Central is redirected: the firewall does not
# serve the Gradle Plugin Portal or Google's Maven repository.
GRADLE_INIT="def firewall = '${BASE}/maven/'
def central = ['https://repo.maven.apache.org/maven2', 'https://repo1.maven.org/maven2']
def useFirewall = { RepositoryHandler repos ->
    repos.withType(MavenArtifactRepository).configureEach { repo ->
        if (central.contains(repo.url.toString().replaceAll('/+\$', ''))) {
            repo.url = firewall
            repo.credentials {
                username = '${ENDOR_API_KEY}'
                password = '${ENDOR_API_SECRET}'
            }
        }
    }
}
settingsEvaluated { settings ->
    useFirewall(settings.pluginManagement.repositories)
    if (GradleVersion.current() >= GradleVersion.version('6.8')) {
        useFirewall(settings.dependencyResolutionManagement.repositories)
    }
}
allprojects {
    useFirewall(buildscript.repositories)
    useFirewall(repositories)
}"

echo "gradle -> ${BASE}/maven/ (Maven Central only)"
write_new "${HOME}/.gradle/init.d/endor-firewall.gradle" "$GRADLE_INIT"

# Every dotnet SDK reads this user config, including ones actions/setup-dotnet
# installs later. <clear /> drops nuget.org. Jobs have no API key in the
# environment, so the credentials live in the file, as they do for Maven.
NUGET_CONFIG="$(cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="endor-firewall" value="${BASE}/nuget/v3/index.json" protocolVersion="3" />
  </packageSources>
  <packageSourceCredentials>
    <endor-firewall>
      <add key="Username" value="${ENDOR_API_KEY}" />
      <add key="ClearTextPassword" value="${ENDOR_API_SECRET}" />
      <add key="ValidAuthenticationTypes" value="basic" />
    </endor-firewall>
  </packageSourceCredentials>
</configuration>
EOF
)"

echo "nuget -> ${BASE}/nuget/v3/index.json"
write_new "${HOME}/.nuget/NuGet/NuGet.Config" "$NUGET_CONFIG"

# ~/.gemrc replaces the default rubygems.org source for every Ruby on the box.
GEMRC="$(cat <<EOF
---
:sources:
- "https://${URL_CREDS}@${ENDOR_PFW_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/gem/"
EOF
)"

echo "gem -> ${BASE}/gem/"
write_new "${HOME}/.gemrc" "$GEMRC"

# Bundler keeps https://rubygems.org in the Gemfile and fetches from the mirror.
# fallback_timeout false skips the TCP probe, whose default of 0.1s would give
# up on the firewall and download from rubygems.org instead.
BUNDLE_CONFIG="$(cat <<EOF
---
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "https://${URL_CREDS}@${ENDOR_PFW_HOST}/v1/namespaces/${ENDOR_NAMESPACE}/firewall/gem/"
BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/__FALLBACK_TIMEOUT: false
EOF
)"

echo "bundler -> ${BASE}/gem/ (mirror of https://rubygems.org)"
write_new "${HOME}/.bundle/config" "$BUNDLE_CONFIG"

echo "Endor Package Firewall configuration complete."
