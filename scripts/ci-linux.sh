#!/usr/bin/env bash
# The Linux CI jobs as one script, so Gitea Actions and a local run do exactly the same thing
# (docs/design/local-first.md). Each JOB runs inside the swift:6.4-noble image and installs what it needs.
#
#   scripts/ci-linux.sh test           build, then the package tests with no network (scripts/test-offline.sh),
#                                      the portability guard and the removable-importers check
#   scripts/ci-linux.sh webdav         the WebDAV integration tests against wsgidav (scripts/test-webdav.sh)
#   scripts/ci-linux.sh static [ARCH]  the fully static release binary (scripts/build-linux-static.sh; Swift 6.4.2
#                                      image), host architecture by default
#   scripts/ci-linux.sh docker JOB...  run each JOB (or JOB:ARG, e.g. static:x86_64) in the right image with Docker, from a Mac or any Linux host. The
#                                      checkout is mounted, but .build is a Docker volume of its own
#                                      (sempere-linux-build-…), so the host's build folder is never touched;
#                                      ~/.swiftpm (the Static Linux SDK) is the volume sempere-linux-swiftpm.
#
# test: SEMPERE_REQUIRE_AGE_PQ, SEMPERE_REQUIRE_POPPLER and SEMPERE_REQUIRE_TOOLS make a missing tool fail its test
# instead of skipping it. webdav: SEMPERE_WEBDAV_LARGE_MB defaults to 64 here. SEMPERE_BUILD_JOBS=N caps the
# build's and the tests' parallelism (the Orin runner's memory is shared with other CI, sysadmin
# docs/fil-ci-runner.md §2.3).
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_IMAGE=${SEMPERE_LINUX_IMAGE:-swift:6.4-noble}
STATIC_IMAGE=swift:6.4.2-noble   # scripts/build-linux-static.sh pins the SDK to exactly this compiler
AGE_VERSION=1.3.2
age_sha256() {
  case $1 in
    amd64) echo cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10 ;;
    arm64) echo 6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4 ;;
  esac
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null
  apt-get install -y -q "$@" >/dev/null
}

install_age() {   # age 1.3 (post-quantum interop; Ubuntu's package is 1.1)
  command -v age >/dev/null && age --version | grep -q "^v$AGE_VERSION" && return 0
  local arch; arch=$(dpkg --print-architecture)
  curl -fsSL -o /tmp/age.tgz "https://github.com/FiloSottile/age/releases/download/v$AGE_VERSION/age-v$AGE_VERSION-linux-$arch.tar.gz"
  echo "$(age_sha256 "$arch")  /tmp/age.tgz" | sha256sum -c - >/dev/null
  tar xzf /tmp/age.tgz -C /usr/local/bin --strip-components=1 age/age age/age-keygen
  rm -f /tmp/age.tgz
}

job_test() {
  # zbar (QR decode), zip (archive interop), poppler (PDF text and background pixel checks), jq (the recovery
  # kit script), the UCD (BidiTest.txt), iproute2 (the offline guard), util-linux (setpriv)
  apt_install zlib1g-dev curl zbar-tools zip poppler-utils unicode-data jq iproute2 util-linux
  install_age
  swift build --build-tests ${SEMPERE_BUILD_JOBS:+-j "$SEMPERE_BUILD_JOBS"}
  SEMPERE_REQUIRE_AGE_PQ=1 SEMPERE_REQUIRE_POPPLER=1 SEMPERE_REQUIRE_TOOLS=zbar,zip,pdftotext,bidi CI=1 \
    scripts/test-offline.sh --skip-build --parallel ${SEMPERE_BUILD_JOBS:+--num-workers "$SEMPERE_BUILD_JOBS"}
  scripts/check-portability.sh
  scripts/check-removable-importers.sh
}

job_webdav() {
  apt_install zlib1g-dev curl python3-venv
  [[ -x /opt/dav/bin/wsgidav ]] || { python3 -m venv /opt/dav && /opt/dav/bin/pip install --quiet -r scripts/webdav-server-requirements.txt; }
  SEMPERE_WEBDAV_LARGE_MB=${SEMPERE_WEBDAV_LARGE_MB:-64} PATH=/opt/dav/bin:$PATH scripts/test-webdav.sh ${SEMPERE_BUILD_JOBS:+-j "$SEMPERE_BUILD_JOBS"}
}

job_static() {
  local arch=${1:-$(uname -m)}
  [[ $arch == arm64 ]] && arch=aarch64
  apt_install curl
  scripts/build-linux-static.sh "$arch" "build/linux-static/sempere-$arch"
}

in_docker() {   # JOB or JOB:ARG (static:x86_64)
  command -v docker >/dev/null || { echo "error: need Docker" >&2; exit 1; }
  local job=${1%%:*} arg="" image=$TEST_IMAGE caps=()
  [[ $1 == *:* ]] && arg=${1#*:}
  [[ $job == static ]] && image=$STATIC_IMAGE
  [[ $job == test ]] && caps=(--cap-add=SYS_ADMIN --cap-add=NET_ADMIN)   # test-offline's network namespace
  local volume="sempere-linux-build-${image//[:.]/-}"
  local tty=(); [[ -t 1 ]] && tty=(-t)
  docker run --rm ${tty[@]+"${tty[@]}"} ${caps[@]+"${caps[@]}"} -v "$PWD:/src" -v "$volume:/src/.build" -v sempere-linux-swiftpm:/root/.swiftpm -w /src "$image" \
    scripts/ci-linux.sh "$job" ${arg:+"$arg"}
}

case ${1:-} in
  test) shift; job_test "$@" ;;
  webdav) shift; job_webdav "$@" ;;
  static) shift; job_static "$@" ;;
  docker) shift; for job in "$@"; do in_docker "$job"; done ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
