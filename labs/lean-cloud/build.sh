#!/usr/bin/env bash
# build.sh — fetch lean-cloud at a pinned commit and build its images.
#
#   lean-cloud-demo:floci   the scheduler/worker image (deploy/build.sh, unmodified)
#   lean-cloud-build:floci  the Dockerfile's build stage, used to run the repo's own
#                           storage contract test (cloud_storage_tests)
#
# The first build compiles Lean dependencies and takes a while; later builds reuse
# Docker's layer cache. Nothing in the lean-cloud checkout is edited.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO=https://github.com/palladin/lean-cloud
PIN=${LEAN_CLOUD_REF:-0ab87f003faa756e5dd75c7832d7a4f788f0b931}
SRC=.work/lean-cloud

if [ ! -d "$SRC/.git" ]; then
  git clone --quiet "$REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$PIN" 2>/dev/null || true
git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$PIN"
echo "lean-cloud at $(git -C "$SRC" rev-parse --short HEAD)"

version=$(sed 's|leanprover/lean4:v||' "$SRC/lean-toolchain" | tr -d '\n\r')

"$SRC/deploy/build.sh" "$SRC" lean-cloud-demo:floci
# The repo's integration suite, exactly as its CI builds it (compose profile "test").
docker buildx build --load --target integration --build-arg "LEAN_VERSION=$version" \
  -t lean-cloud-integration:floci "$SRC"
# The opt-in provider check, cloud_storage_tests, has no Dockerfile target of its own:
# build it on top of the build stage the same way CI does (lake build cloud_storage_tests).
docker buildx build --load --target build --build-arg "LEAN_VERSION=$version" \
  -t lean-cloud-build:floci "$SRC"
docker buildx build --load -t lean-cloud-storage-tests:floci - <<'EOF'
FROM lean-cloud-build:floci
WORKDIR /src/runtime
RUN lake build cloud_storage_tests
ENTRYPOINT ["/src/runtime/.lake/build/bin/cloud_storage_tests"]
EOF
echo "images built: lean-cloud-demo:floci lean-cloud-integration:floci lean-cloud-storage-tests:floci"
