#!/usr/bin/env bash
# The Linux CI jobs as one script (docs/design/local-first.md). The GitHub workflow (.github/workflows/ci.yml) runs `test` and `webdav`
# in the pinned swift image; scripts/local-ci.sh runs `docker test` and `docker webdav` on a Mac. Each JOB runs inside the swift:6.4-noble image and installs what it needs.
#
#   scripts/ci-linux.sh test           build, then the package tests with no network (scripts/test-offline.sh; the benchmark
#                                      targets are skipped, scripts/bench.sh runs them),
#                                      the portability guard and the removable-importers check
#   scripts/ci-linux.sh webdav         the WebDAV integration tests against wsgidav (scripts/test-webdav.sh)
#   scripts/ci-linux.sh static [ARCH]  the fully static release binary (scripts/build-linux-static.sh; Swift 6.4.2
#                                      image), host architecture by default
#   scripts/ci-linux.sh docker JOB...  run each JOB (or JOB:ARG, e.g. static:x86_64) in the right image with Docker, from a Mac or any Linux host. The
#                                      checkout is mounted, but .build is a Docker volume of its own
#                                      (sempere-linux-build-…), so the host's build folder is never touched;
#                                      ~/.swiftpm (the Static Linux SDK) is the volume sempere-linux-swiftpm.
#
# test and webdav skip a test target whose inputs hash to one that already passed (scripts/ci-hash.py, docs/design/ci-lean.md),
# say which commit passed it, and record what they ran once it passed (in Docker, in the host's ~/.cache/sempere-ci-pass,
# or $SEMPERE_CI_PASS_DIR; run bare, in .build/ci-pass: the build volume). docker marks its containers with the label
# sempere-ci-run=$SEMPERE_CI_RUN_ID (local-ci.sh removes its own when it stops early) and runs them with --init. SEMPERE_CI_FORCE_ALL=1 runs everything.
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

# Hash-based skipping (docs/design/ci-lean.md): scripts/ci-hash.py hashes each test target's inputs and skips a target
# that already passed with the same hash, naming the commit that passed it. The records live in the build volume
# (.build/ci-pass), so they are as durable as the build cache. SEMPERE_CI_FORCE_ALL=1 runs everything.
ci_store() { echo "${SEMPERE_CI_PASS_DIR:-$PWD/.build/ci-pass}"; }

# One job at a time per build volume. The volume is shared by every checkout on this Docker host, and a job builds in one
# process and runs `swift test --skip-build` in another: without the lock, another checkout's build could replace .build in
# between, and this job would record passes for code it never tested. The lock is held (fd 9) until the job's process ends,
# so it is released with it, even when the container is removed.
lock_build() {
  mkdir -p .build
  exec 9>.build/.ci-job.lock
  if ! flock -n 9; then echo "ci-linux: another Linux job is using this build volume; waiting for it"; flock 9; fi
}

job_test() {
  lock_build
  # zbar (QR decode), zip (archive interop), poppler (PDF text and background pixel checks), jq (the recovery
  # kit script), the UCD (BidiTest.txt), iproute2 (the offline guard), util-linux (setpriv), python3 (ci-hash.py)
  apt_install zlib1g-dev curl zbar-tools zip poppler-utils unicode-data jq iproute2 util-linux python3
  install_age
  python3 scripts/ci-hash.py --self-test | tail -1
  scripts/test-ci-hash-guard.sh | tail -1
  python3 scripts/ci-hash.py check-reads   # a test reading a file the hash does not cover fails here
  export SEMPERE_CI_PASS_DIR; SEMPERE_CI_PASS_DIR=$(ci_store)
  local plan; plan=$(mktemp)
  python3 scripts/ci-hash.py plan --job linux-test --out "$plan"
  local skips=() runs=0 t
  while read -r t; do skips+=(--skip "^$t\\."); done < <(python3 scripts/ci-hash.py skips "$plan")
  runs=$(python3 scripts/ci-hash.py runs "$plan" | wc -l)
  # The build always runs (incremental, cheap when warm): the benchmark targets are never tested but must still compile.
  swift build --build-tests ${SEMPERE_BUILD_JOBS:+-j "$SEMPERE_BUILD_JOBS"}
  if [[ $runs -eq 0 ]]; then
    echo "ci-linux: every test target skipped: each passed with its current hash (lines above name the commits)"
  else
    SEMPERE_REQUIRE_AGE_PQ=1 SEMPERE_REQUIRE_POPPLER=1 SEMPERE_REQUIRE_TOOLS=zbar,zip,pdftotext,bidi CI=1 \
      scripts/test-offline.sh --skip-build --parallel --skip 'Benchmarks\.' ${skips[@]+"${skips[@]}"} ${SEMPERE_BUILD_JOBS:+--num-workers "$SEMPERE_BUILD_JOBS"}
    python3 scripts/ci-hash.py record --plan "$plan"   # only after the whole run passed (set -e)
  fi
  # The web viewer's golden files are what the CLI writes now (web/scripts/golden.sh). Runs every time, after any skip: a skipped
  # target cannot hide a mismatch. The CLI is built above.
  local golden; golden=$(mktemp -d)
  SEMPERE="$PWD/.build/debug/sempere" web/scripts/golden.sh "$golden" >/dev/null
  diff -r web/test/golden "$golden" >/dev/null || { echo "ci-linux: web/test/golden differs from the CLI's output (web/scripts/golden.sh)"; diff -rq web/test/golden "$golden" | head; exit 1; }
  rm -rf "$golden"
  scripts/check-portability.sh
  scripts/check-removable-importers.sh
}

job_webdav() {
  lock_build
  apt_install zlib1g-dev curl python3-venv python3
  export SEMPERE_CI_PASS_DIR; SEMPERE_CI_PASS_DIR=$(ci_store)
  # The job runs the tests whose name says Wsgidav, which live in these two targets (docs/ci.md "What runs when").
  local plan; plan=$(mktemp)
  python3 scripts/ci-hash.py plan --job linux-webdav --out "$plan" SempereWebDAVTests CLITests
  if [[ $(python3 scripts/ci-hash.py runs "$plan" | wc -l) -eq 0 ]]; then
    echo "ci-linux: the WebDAV job skipped: both of its targets passed with their current hash (lines above name the commits)"
    return 0
  fi
  [[ -x /opt/dav/bin/wsgidav ]] || { python3 -m venv /opt/dav && /opt/dav/bin/pip install --quiet -r scripts/webdav-server-requirements.txt; }
  SEMPERE_WEBDAV_LARGE_MB=${SEMPERE_WEBDAV_LARGE_MB:-64} PATH=/opt/dav/bin:$PATH scripts/test-webdav.sh ${SEMPERE_BUILD_JOBS:+-j "$SEMPERE_BUILD_JOBS"}
  python3 scripts/ci-hash.py record --plan "$plan"
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
  local volume="${SEMPERE_LINUX_BUILD_VOLUME:-sempere-linux-build-${image//[:.]/-}}"   # a name of your own when another run shares the Docker host
  local tty=(); [[ -t 1 ]] && tty=(-t)
  # The pass records (docs/design/ci-lean.md) live on the host, in the Mac gate's store, not in the build volume: a record is
  # the content hash of a target, so a pass recorded for one commit is honored for any later commit with the same hashes, and
  # it survives a new or pruned build volume. test and webdav use it; the build volume stays only a build cache.
  local store=() store_dir=${SEMPERE_CI_PASS_DIR:-$HOME/.cache/sempere-ci-pass}
  if [[ $job == test || $job == webdav ]]; then mkdir -p "$store_dir"; store=(-v "$store_dir:/ci-pass" -e SEMPERE_CI_PASS_DIR=/ci-pass); fi
  # The image's id goes into the target hashes: the local default tag floats (the runner's is pinned by digest in the workflow).
  local image_id; image_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || { docker pull -q "$image" >/dev/null && docker image inspect --format '{{.Id}}' "$image"; })
  docker run --rm --init --label "sempere-ci-run=${SEMPERE_CI_RUN_ID:-manual}" -e SEMPERE_CI_FORCE_ALL -e SEMPERE_CI_HOST -e "SEMPERE_CI_IMAGE_ID=$image_id" ${tty[@]+"${tty[@]}"} ${caps[@]+"${caps[@]}"} ${store[@]+"${store[@]}"} -v "$PWD:/src" -v "$volume:/src/.build" -v sempere-linux-swiftpm:/root/.swiftpm -w /src "$image" \
    scripts/ci-linux.sh "$job" ${arg:+"$arg"}
}

case ${1:-} in
  test) shift; job_test "$@" ;;
  webdav) shift; job_webdav "$@" ;;
  static) shift; job_static "$@" ;;
  docker) shift; for job in "$@"; do in_docker "$job"; done ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
