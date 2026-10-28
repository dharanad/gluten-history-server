#!/usr/bin/env bash
# Prepares dist/spark (copied into the image) and jars/ (mounted at run time). Safe to re-run.
#
#   ./setup.sh                               download Spark (if dist/spark is missing)
#   ./setup.sh --spark /path/to/spark-dir    copy an existing Spark distribution into dist/spark
#   ./setup.sh --spark /path/to/spark.tgz    extract an existing Spark tarball into dist/spark
#   ./setup.sh --force                       re-download Spark even if dist/spark is already set up
#   ./setup.sh --publish                     also build the image and push it to $IMAGE
#   ./setup.sh --pull                        check jars/, pull $IMAGE and (re)start docker compose with it
#
# The Gluten bundle is not fetched: copy it into jars/ yourself. The script checks it is there.
# IMAGE (e.g. dharanaditya/gluten-history-server:latest on Docker Hub) is read from the shell
# or .env. Log in to the registry first (docker login).
set -euo pipefail

SPARK_VERSION=3.5.2
SPARK_PKG="spark-${SPARK_VERSION}-bin-hadoop3-scala2.13"
SPARK_URL="https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_PKG}.tgz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist/spark"
STAGE="$ROOT/dist/.spark.tmp"
JARS="$ROOT/jars"

spark_src=""
force=false
mode=setup
tmp=""

cleanup() { rm -rf "$STAGE" ${tmp:+"$tmp"}; }
trap cleanup EXIT

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spark)  [[ $# -ge 2 ]] || die "--spark needs a path"; spark_src="$2"; shift 2 ;;
    --force)  force=true; shift ;;
    --publish) mode=publish; shift ;;
    --pull)    mode=pull; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage 1 ;;
  esac
done

compose() { docker compose --project-directory "$ROOT" "$@"; }

# The image name compose resolves from IMAGE (shell or .env); publishing and pulling need a registry path.
require_image() {
  local image
  image="$(compose config --images)"
  [[ "$image" == */* ]] || die "set IMAGE to a registry path (in .env or the shell); docker compose resolves it to '$image'"
  echo "$image"
}

check_gluten_jar() {
  local existing
  shopt -s nullglob
  existing=("$JARS"/gluten-*.jar)
  shopt -u nullglob

  if [[ ${#existing[@]} -eq 0 ]]; then
    die "no Gluten jar in jars/. Copy your Gluten bundle (gluten-velox-bundle-spark${SPARK_VERSION}_2.13-*.jar) into jars/ and re-run"
  elif [[ ${#existing[@]} -gt 1 ]]; then
    die "more than one Gluten jar in jars/; keep only one: ${existing[*]##*/}"
  fi
  echo "Gluten jar found: jars/${existing[0]##*/}"

  [[ "${existing[0]##*/}" == *"spark${SPARK_VERSION}_2.13"* ]] \
    || echo "warning: ${existing[0]##*/} doesn't look like a spark${SPARK_VERSION}_2.13 build" >&2
}

if [[ "$mode" == pull ]]; then
  image="$(require_image)"
  check_gluten_jar
  echo "Pulling $image"
  compose pull
  compose up -d --no-build
  echo "Running $image on http://localhost:18080"
  exit 0
fi

is_spark_dist() { [[ -f "$1/sbin/start-history-server.sh" ]]; }

# Fills $STAGE, validates it, then swaps it into place so a failed run never leaves a half-written dist/spark.
install_spark() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE"

  if [[ -d "$spark_src" ]]; then
    is_spark_dist "$spark_src" || die "$spark_src is not a Spark distribution (no sbin/start-history-server.sh)"
    echo "Copying Spark from $spark_src"
    cp -R "$spark_src/." "$STAGE/"
  elif [[ -f "$spark_src" ]]; then
    echo "Extracting Spark from $spark_src"
    tar -xzf "$spark_src" -C "$STAGE" --strip-components=1
  elif [[ -n "$spark_src" ]]; then
    die "--spark path not found: $spark_src"
  else
    tmp="$(mktemp -d)"
    echo "Downloading $SPARK_URL"
    curl -fL --progress-bar -o "$tmp/$SPARK_PKG.tgz" "$SPARK_URL"
    curl -fsSL -o "$tmp/$SPARK_PKG.tgz.sha512" "$SPARK_URL.sha512"
    echo "Verifying checksum"
    if command -v shasum >/dev/null; then
      (cd "$tmp" && shasum -a 512 -c "$SPARK_PKG.tgz.sha512")
    else
      (cd "$tmp" && sha512sum -c "$SPARK_PKG.tgz.sha512")
    fi
    tar -xzf "$tmp/$SPARK_PKG.tgz" -C "$STAGE" --strip-components=1
  fi

  is_spark_dist "$STAGE" || die "result is not a Spark distribution (no sbin/start-history-server.sh); is the tarball nested differently?"
  rm -rf "$DIST"
  mv "$STAGE" "$DIST"
  echo "Spark ready in dist/spark"
}

if [[ -n "$spark_src" ]] || $force || ! is_spark_dist "$DIST"; then
  install_spark
else
  echo "Spark already in dist/spark (use --spark or --force to replace it)"
fi

check_gluten_jar

if [[ "$mode" == publish ]]; then
  image="$(require_image)"
  echo "Building and pushing $image"
  compose build
  compose push
  echo
  echo "Published $image. Elsewhere, run: ./setup.sh --pull"
  exit 0
fi

echo
echo "Done. Start with: docker compose up -d --build"
