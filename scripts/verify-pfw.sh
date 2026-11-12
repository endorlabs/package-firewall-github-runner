#!/usr/bin/env bash
# Prove Package Firewall is in the path:
#   1. a normal package installs fine
#   2. Endor's known-malicious test package is blocked (HTTP 403)
# Exits non-zero if either check fails.
set -uo pipefail

fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== Effective config =="
echo "npm registry: $(npm config get registry)"
pip3 config list 2>/dev/null | sed -E 's#//[^@]*@#//***@#' || true
echo "maven mirror: $(grep -ho '<url>[^<]*' "${HOME}/.m2/settings.xml" 2>/dev/null | sed 's/<url>//')"
echo "go proxy: $(go env GOPROXY | sed -E 's#//[^@]*@#//***@#')"

# Keep package caches in the work dir so the snapshot does not keep them.
# Do not set DOTNET_CLI_HOME: NuGet reads ~/.nuget/NuGet/NuGet.Config from that
# directory when it is set, and the firewall config would be skipped.
export NUGET_PACKAGES="$work/nuget/packages"
export NUGET_HTTP_CACHE_PATH="$work/nuget/http"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export GEM_HOME="$work/gem-home"
export GEM_PATH="$GEM_HOME"
export GEM_SPEC_CACHE="$work/gem-specs"
export BUNDLE_PATH="$work/bundler-gems"
tfm="net$(dotnet --version 2>/dev/null | cut -d. -f1).0"

echo "nuget sources:"
dotnet nuget list source 2>/dev/null || true
echo "gem sources:"
gem sources --list 2>/dev/null | sed -E 's#//[^@]*@#//***@#' || true
echo

echo "== npm: benign install (expect success) =="
mkdir -p "$work/npm-ok" && cd "$work/npm-ok" && npm init -y >/dev/null
if npm install --no-audit --no-fund lodash@4.17.21; then
  echo "PASS: lodash installed via Package Firewall"
else
  echo "::error::FAIL: benign npm install failed (check credentials / namespace / host)"; fail=1
fi

echo "== npm: malicious test package (expect 403) =="
mkdir -p "$work/npm-bad" && cd "$work/npm-bad" && npm init -y >/dev/null
if npm install --no-audit --no-fund endor-firewall-test@1.0.0 >out.log 2>&1; then
  cat out.log; echo "::error::FAIL: endor-firewall-test was NOT blocked"; fail=1
elif grep -q '403' out.log; then
  echo "PASS: endor-firewall-test blocked with 403"
else
  cat out.log; echo "::error::FAIL: install failed but not with a 403"; fail=1
fi

echo "== pip: benign install (expect success) =="
python3 -m venv "$work/venv"
if "$work/venv/bin/pip" install --no-cache-dir --disable-pip-version-check requests; then
  echo "PASS: requests installed via Package Firewall"
else
  echo "::error::FAIL: benign pip install failed"; fail=1
fi

echo "== pip: malicious test package (expect 403) =="
if "$work/venv/bin/pip" install --no-cache-dir --disable-pip-version-check endor-firewall-test==1.0.0 >"$work/pip.log" 2>&1; then
  cat "$work/pip.log"; echo "::error::FAIL: endor-firewall-test (pypi) was NOT blocked"; fail=1
elif grep -qiE '403|forbidden' "$work/pip.log"; then
  echo "PASS: endor-firewall-test (pypi) blocked with 403"
else
  sed -E 's#//[^@]*@#//***@#' "$work/pip.log"; echo "::error::FAIL: pip install failed but not with a 403"; fail=1
fi

# mvn_get <mvn-command> <artifact> [maven args]
mvn_get() {
  local cmd="$1" artifact="$2"; shift 2
  "$cmd" -B -ntp -Dmaven.repo.local="$work/m2" "$@" dependency:get -Dtransitive=false -Dartifact="$artifact"
}

# mvn_blocked <label> <mvn-command> [maven args]
mvn_blocked() {
  local label="$1"; shift
  if mvn_get "$1" io.github.endorlabs:endor-java-webapp-demo:4.1 "${@:2}" >"$work/mvn.log" 2>&1; then
    cat "$work/mvn.log"; echo "::error::FAIL: endor-java-webapp-demo was NOT blocked${label}"; fail=1
  elif grep -q '403' "$work/mvn.log"; then
    echo "PASS: endor-java-webapp-demo blocked with 403${label}"
  else
    cat "$work/mvn.log"; echo "::error::FAIL: maven install failed but not with a 403${label}"; fail=1
  fi
}

echo "== maven: benign install (expect success) =="
if mvn_get mvn org.apache.commons:commons-lang3:3.17.0; then
  echo "PASS: commons-lang3 installed via Package Firewall"
else
  echo "::error::FAIL: benign maven install failed"; fail=1
fi

echo "== maven: malicious test package (expect 403) =="
mvn_blocked "" mvn

# An empty user settings file stands in for the one actions/setup-java writes. The wrapper
# downloads Maven from Central because mvnw does not send the firewall credentials.
echo "== maven wrapper with replaced user settings (expect 403) =="
mkdir -p "$work/mvnw" && cd "$work/mvnw" && printf '<settings/>\n' > settings.xml
export MAVEN_USER_HOME="$work/mvnw-home"
if mvn -B -ntp -q -Dmaven.repo.local="$work/m2" wrapper:wrapper -Dtype=only-script \
     -DdistributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.11/apache-maven-3.9.11-bin.zip; then
  mvn_blocked " (mvnw after setup-java)" ./mvnw -s settings.xml
else
  echo "::error::FAIL: could not install the Maven Wrapper"; fail=1
fi

# A throwaway Gradle home that reads the real init.d keeps Gradle's caches out of the image.
mkdir -p "$work/gradle/home" && cd "$work/gradle"
ln -s "${GRADLE_USER_HOME:-${HOME}/.gradle}/init.d" home/init.d
printf "rootProject.name = 'verify'\n" > settings.gradle
cat > build.gradle <<'EOF'
repositories { mavenCentral() }
def probe = configurations.create('probe') { transitive = false }
dependencies.add('probe', project.property('dep'))
tasks.register('resolve') { doLast { probe.files } }
EOF
gradle_get() { gradle -q --no-daemon -g "$work/gradle/home" -Pdep="$1" resolve; }

echo "== gradle: benign install (expect success) =="
if gradle_get org.apache.commons:commons-lang3:3.17.0; then
  echo "PASS: commons-lang3 installed via Package Firewall (gradle)"
else
  echo "::error::FAIL: benign gradle install failed"; fail=1
fi

echo "== gradle: malicious test package (expect 403) =="
if gradle_get io.github.endorlabs:endor-java-webapp-demo:4.1 >"$work/gradle.log" 2>&1; then
  cat "$work/gradle.log"; echo "::error::FAIL: endor-java-webapp-demo (gradle) was NOT blocked"; fail=1
elif grep -q '403' "$work/gradle.log"; then
  echo "PASS: endor-java-webapp-demo (gradle) blocked with 403"
else
  cat "$work/gradle.log"; echo "::error::FAIL: gradle install failed but not with a 403"; fail=1
fi

export GOMODCACHE="$work/gomod" GOFLAGS=-modcacherw
mkdir -p "$work/go" && cd "$work/go" && go mod init verify >/dev/null 2>&1

echo "== go: benign install (expect success) =="
if go mod download github.com/google/uuid@v1.6.0; then
  echo "PASS: github.com/google/uuid installed via Package Firewall"
else
  echo "::error::FAIL: benign go install failed"; fail=1
fi

echo "== go: malicious test package (expect 403) =="
if go mod download github.com/endorlabstest/endor-firewall-test@v1.0.0 >"$work/go.log" 2>&1; then
  cat "$work/go.log"; echo "::error::FAIL: endor-firewall-test (go) was NOT blocked"; fail=1
elif grep -q '403' "$work/go.log"; then
  echo "PASS: endor-firewall-test (go) blocked with 403"
else
  cat "$work/go.log"; echo "::error::FAIL: go install failed but not with a 403"; fail=1
fi

# nuget_project <dir>
nuget_project() {
  mkdir -p "$1"
  cat > "$1/verify.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>${tfm}</TargetFramework>
  </PropertyGroup>
</Project>
EOF
}

echo "== nuget: benign install (expect success) =="
nuget_project "$work/nuget-ok"
if dotnet add "$work/nuget-ok/verify.csproj" package Newtonsoft.Json --version 13.0.3; then
  echo "PASS: Newtonsoft.Json installed via Package Firewall"
else
  echo "::error::FAIL: benign nuget install failed"; fail=1
fi

echo "== nuget: malicious test package (expect 403) =="
nuget_project "$work/nuget-bad"
if dotnet add "$work/nuget-bad/verify.csproj" package endor-firewall-test --version 1.0.0 >"$work/nuget.log" 2>&1; then
  cat "$work/nuget.log"; echo "::error::FAIL: endor-firewall-test (nuget) was NOT blocked"; fail=1
elif grep -qiE '403|forbidden' "$work/nuget.log"; then
  echo "PASS: endor-firewall-test (nuget) blocked with 403"
else
  cat "$work/nuget.log"; echo "::error::FAIL: nuget install failed but not with a 403"; fail=1
fi

echo "== gem: benign install (expect success) =="
if gem install --no-document minitest -v 5.25.4 >"$work/gem-ok.log" 2>&1; then
  echo "PASS: minitest installed via Package Firewall"
else
  sed -E 's#//[^@]*@#//***@#' "$work/gem-ok.log"; echo "::error::FAIL: benign gem install failed"; fail=1
fi

echo "== gem: malicious test package (expect 403) =="
if gem install --no-document endor-firewall-test -v 1.0.0 >"$work/gem.log" 2>&1; then
  sed -E 's#//[^@]*@#//***@#' "$work/gem.log"; echo "::error::FAIL: endor-firewall-test (gem) was NOT blocked"; fail=1
elif grep -q '403' "$work/gem.log"; then
  echo "PASS: endor-firewall-test (gem) blocked with 403"
else
  sed -E 's#//[^@]*@#//***@#' "$work/gem.log"; echo "::error::FAIL: gem install failed but not with a 403"; fail=1
fi

# The base image ships RubyGems without the bundle executable.
if ! command -v bundle >/dev/null 2>&1; then
  echo "== bundler: install bundler (not on the base image) =="
  if gem install --no-document bundler >"$work/bundler-install.log" 2>&1; then
    export PATH="${GEM_HOME}/bin:${PATH}"
  else
    sed -E 's#//[^@]*@#//***@#' "$work/bundler-install.log"
    echo "::error::FAIL: could not install bundler"; fail=1
  fi
fi

if ! command -v bundle >/dev/null 2>&1; then
  echo "::error::FAIL: bundle is not available"; fail=1
else
  echo "bundler mirror:"
  bundle config get mirror.https://rubygems.org 2>/dev/null | sed -E 's#//[^@]*@#//***@#' || true

  echo "== bundler: benign install (expect success) =="
  mkdir -p "$work/bundler-ok" && cd "$work/bundler-ok" && bundle init >/dev/null
  if bundle add minitest --version 5.25.4 >"$work/bundler-ok.log" 2>&1; then
    echo "PASS: minitest installed via Package Firewall (bundler)"
  else
    sed -E 's#//[^@]*@#//***@#' "$work/bundler-ok.log"; echo "::error::FAIL: benign bundler install failed"; fail=1
  fi

  echo "== bundler: malicious test package (expect 403) =="
  mkdir -p "$work/bundler-bad" && cd "$work/bundler-bad" && bundle init >/dev/null
  if bundle add endor-firewall-test --version 1.0.0 >"$work/bundler.log" 2>&1; then
    sed -E 's#//[^@]*@#//***@#' "$work/bundler.log"; echo "::error::FAIL: endor-firewall-test (bundler) was NOT blocked"; fail=1
  elif grep -q '403' "$work/bundler.log"; then
    echo "PASS: endor-firewall-test (bundler) blocked with 403"
  else
    sed -E 's#//[^@]*@#//***@#' "$work/bundler.log"; echo "::error::FAIL: bundler install failed but not with a 403"; fail=1
  fi
fi

npm cache clean --force >/dev/null 2>&1 || true
rm -rf "${HOME}/.bundle/cache" "${HOME}/.gem" "${HOME}/.nuget/packages" "${HOME}/.local/share/NuGet"
exit $fail
