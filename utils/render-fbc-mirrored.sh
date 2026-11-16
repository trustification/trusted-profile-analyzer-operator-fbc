#!/usr/bin/env bash
#
# Render and validate FBC fragments resolving every image through the quay
# component repositories declared in .tekton/images-mirror-set.yaml.
#
# Why: the Konflux task check-related-images-mediatype resolves related images
# against production registry.redhat.io, so a fragment that references a bundle
# which has not been released yet always fails with MANIFEST_UNKNOWN. The same
# images are reachable in the quay repos the builds push to, so this script
# reproduces the render + validate + mediatype check locally, before the
# release lands.
#
# Resolution is per digest, mirror first, source as fallback: the quay repos
# only hold the current builds, while already released bundles exist solely in
# registry.redhat.io.
#
# Usage:
#   utils/render-fbc-mirrored.sh [options] <fragment>... | all
#
# Options:
#   --write                 overwrite <fragment>/catalog/<pkg>/catalog.json with
#                           the rendered catalog (default: render to a temp dir
#                           and diff against the committed one)
#   --check-only            skip rendering, just resolve and check the images
#                           referenced by the committed catalog.json
#   --authfile <path>       container auth file, needed to reach
#                           registry.redhat.io (released bundles)
#   --mirror-set <path>     default: .tekton/images-mirror-set.yaml
#   --no-preserve-legacy    do not carry over relatedImages of the legacy
#                           1.0.x/1.1.x bundles from the existing catalog
#   --keep                  keep the work directory
#   -h, --help              this help
#
# Examples:
#   utils/render-fbc-mirrored.sh --check-only v4.21
#   utils/render-fbc-mirrored.sh --authfile ~/.docker/config.json v4.20
#   utils/render-fbc-mirrored.sh --authfile ~/.docker/config.json --write all
#
# Exit status: 1 if any image is missing in both the mirror and the source, or
# if opm validate fails. Images that only fail with an authentication error are
# reported as warnings (they need --authfile), not as failures.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PACKAGE="rhtpa-operator"
OPM_CMD=${OPM_CMD:-opm}
SKOPEO_CMD=${SKOPEO_CMD:-skopeo}
JQ_CMD=${JQ_CMD:-jq}

MIRROR_SET="${REPO_ROOT}/.tekton/images-mirror-set.yaml"
AUTHFILE=""
WRITE=0
CHECK_ONLY=0
PRESERVE_LEGACY=1
KEEP=0
FRAGMENTS=()

RED=''; GREEN=''; YELLOW=''; BOLD=''; OFF=''
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
fi

usage() { sed -n '3,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die() { echo "${RED}error:${OFF} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write)              WRITE=1; shift ;;
    --check-only)         CHECK_ONLY=1; shift ;;
    --no-preserve-legacy) PRESERVE_LEGACY=0; shift ;;
    --keep)               KEEP=1; shift ;;
    --authfile)           AUTHFILE="${2:?--authfile needs a path}"; shift 2 ;;
    --mirror-set)         MIRROR_SET="${2:?--mirror-set needs a path}"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    -*)                   die "unknown option: $1" ;;
    *)                    FRAGMENTS+=("${1%/}"); shift ;;
  esac
done

for bin in "$OPM_CMD" "$SKOPEO_CMD" "$JQ_CMD" python3; do
  command -v "$bin" >/dev/null || die "$bin not found in PATH"
done
[[ -f "$MIRROR_SET" ]] || die "mirror set not found: $MIRROR_SET"
[[ ${#FRAGMENTS[@]} -gt 0 ]] || { usage; exit 2; }

if [[ "${FRAGMENTS[0]}" == "all" ]]; then
  FRAGMENTS=()
  for d in "$REPO_ROOT"/v[0-9]*; do
    [[ -f "$d/graph.yaml" ]] && FRAGMENTS+=("$(basename "$d")")
  done
fi

SKOPEO_AUTH=()
if [[ -n "$AUTHFILE" ]]; then
  [[ -f "$AUTHFILE" ]] || die "auth file not found: $AUTHFILE"
  SKOPEO_AUTH=(--authfile "$AUTHFILE")
  # opm has no --authfile flag, it reads the standard container auth env vars
  export REGISTRY_AUTH_FILE="$AUTHFILE"
fi

WORKDIR=$(mktemp -d -t fbc-mirrored-XXXXXX)
cleanup() { [[ $KEEP -eq 1 ]] && echo "work directory kept: $WORKDIR" || rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------- mirror map

# source repo -> space separated list of mirror repos (uncommented entries only)
declare -A MIRRORS=()
while IFS=$'\t' read -r src mir; do
  [[ -n "$src" && -n "$mir" ]] || continue
  MIRRORS["$src"]="${MIRRORS[$src]:-} $mir"
done < <(python3 -I - "$MIRROR_SET" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
for entry in (doc.get("spec") or {}).get("imageDigestMirrors") or []:
    source = entry.get("source")
    for mirror in entry.get("mirrors") or []:
        if source and mirror:
            print(f"{source}\t{mirror}")
PY
)

echo "${BOLD}Mirrors from $(realpath --relative-to="$REPO_ROOT" "$MIRROR_SET")${OFF}"
if [[ ${#MIRRORS[@]} -eq 0 ]]; then
  echo "  (none active - every entry is commented out)"
else
  for src in "${!MIRRORS[@]}"; do
    echo "  $src ->${MIRRORS[$src]}"
  done
fi
echo

# ------------------------------------------------------------------ resolver

# Populated by resolve_ref: resolved pullspec, how it resolved, media type and
# the error of the last attempt.
RESOLVED_REF=""; RESOLVED_VIA=""; RESOLVED_MEDIATYPE=""; RESOLVED_ERROR=""

declare -A PROBE_STATUS=() PROBE_MEDIATYPE=() PROBE_ERROR=()

# probe <pullspec> -> 0 if the manifest exists, caches the result
probe() {
  local ref="$1" out rc
  if [[ -n "${PROBE_STATUS[$ref]:-}" ]]; then
    [[ "${PROBE_STATUS[$ref]}" == "ok" ]]
    return
  fi
  set +e
  out=$("$SKOPEO_CMD" inspect --raw "${SKOPEO_AUTH[@]}" "docker://$ref" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    PROBE_STATUS[$ref]="ok"
    PROBE_MEDIATYPE[$ref]=$(printf '%s' "$out" | "$JQ_CMD" -r '.mediaType // "unknown"')
    return 0
  fi
  PROBE_STATUS[$ref]="fail"
  PROBE_ERROR[$ref]=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g')
  return 1
}

# resolve_ref <pullspec@digest>
#   via=mirror|source  -> found, RESOLVED_REF is usable
#   via=auth           -> not found, the source denied authentication
#   via=missing        -> not found anywhere
resolve_ref() {
  local ref="$1" repo digest cand
  repo="${ref%@*}"; digest="${ref##*@}"
  RESOLVED_REF=""; RESOLVED_VIA=""; RESOLVED_MEDIATYPE=""; RESOLVED_ERROR=""

  if [[ "$ref" != *"@sha256:"* ]]; then
    RESOLVED_VIA="missing"; RESOLVED_ERROR="not pinned by digest"; return 1
  fi

  for mirror in ${MIRRORS[$repo]:-}; do
    cand="$mirror@$digest"
    if probe "$cand"; then
      RESOLVED_REF="$cand"; RESOLVED_VIA="mirror"
      RESOLVED_MEDIATYPE="${PROBE_MEDIATYPE[$cand]}"
      return 0
    fi
  done

  if probe "$ref"; then
    RESOLVED_REF="$ref"; RESOLVED_VIA="source"
    RESOLVED_MEDIATYPE="${PROBE_MEDIATYPE[$ref]}"
    return 0
  fi

  RESOLVED_ERROR="${PROBE_ERROR[$ref]:-unknown error}"
  if [[ "$RESOLVED_ERROR" == *[Uu]nauthorized* || "$RESOLVED_ERROR" == *authentication* ]]; then
    RESOLVED_VIA="auth"
  else
    RESOLVED_VIA="missing"
  fi
  return 1
}

# ------------------------------------------------------------------- helpers

migrate_flag_for() { # <fragment dir name>, mirrors render_catalog.sh
  local v="${1#v}" major minor
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if (( major > 4 )) || (( major == 4 && minor >= 17 )); then
    echo "--migrate-level=bundle-object-to-csv-metadata"
  fi
}

normalize_graph() { # <graph.yaml> <out.yaml>
  # graph.yaml keeps the channels and the deprecations as separate YAML
  # documents next to the olm.template.basic one. opm >= 1.6x rejects that
  # ("template has unknown schema"), so fold every document into the entries
  # of a single olm.template.basic document, which is the documented layout.
  python3 -I - "$1" "$2" <<'PY'
import sys, yaml
entries = []
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict):
        continue
    if doc.get("schema") == "olm.template.basic":
        entries.extend(doc.get("entries") or [])
    else:
        entries.append(doc)
with open(sys.argv[2], "w") as out:
    yaml.safe_dump({"schema": "olm.template.basic", "entries": entries}, out, sort_keys=False)
PY
}

bundle_images_of_graph() { # <graph.yaml> -> the olm.bundle images of the template
  python3 -I - "$1" <<'PY'
import sys, yaml
seen = set()
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict):
        continue
    entries = doc.get("entries") if doc.get("schema") == "olm.template.basic" else None
    for entry in entries or []:
        image = isinstance(entry, dict) and entry.get("schema") == "olm.bundle" and entry.get("image")
        if image and image not in seen:
            seen.add(image)
            print(image)
PY
}

images_of_catalog() { # <catalog.json> -> every bundle image and related image
  "$JQ_CMD" -s -r '
    [ .[] | select(.schema == "olm.bundle")
          | (.image, (.relatedImages // [])[].image) ]
    | map(select(. != null and . != "")) | unique | .[]' "$1"
}

FAILURES=0
WARNINGS=0

check_images() { # <catalog.json> <label>
  local catalog="$1" label="$2" ref short digest
  echo "${BOLD}Related image check ($label)${OFF}"
  local total=0 ok_mirror=0 ok_source=0 broken=0 auth=0
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    total=$((total + 1))
    digest="${ref##*@sha256:}"
    short="${ref%@*}"; short="${short##*/}@${digest:0:12}"
    if resolve_ref "$ref"; then
      [[ "$RESOLVED_VIA" == "mirror" ]] && ok_mirror=$((ok_mirror + 1)) || ok_source=$((ok_source + 1))
      printf '  %bOK%b   %-6s %-45s %s\n' "$GREEN" "$OFF" "$RESOLVED_VIA" "$short" "$RESOLVED_MEDIATYPE"
    elif [[ "$RESOLVED_VIA" == "auth" ]]; then
      auth=$((auth + 1))
      printf '  %bWARN%b %-6s %-45s needs credentials (--authfile)\n' "$YELLOW" "$OFF" "auth" "$short"
    else
      broken=$((broken + 1))
      printf '  %bFAIL%b %-6s %-45s %s\n' "$RED" "$OFF" "missing" "$short" "$RESOLVED_ERROR"
    fi
  done < <(images_of_catalog "$catalog")
  echo "  total=$total mirror=$ok_mirror source=$ok_source broken=$broken needs-auth=$auth"
  (( broken > 0 )) && FAILURES=$((FAILURES + 1))
  (( auth > 0 )) && WARNINGS=$((WARNINGS + 1))
  return 0
}

validate_catalog() { # <catalog.json> <label>
  local catalog="$1" label="$2" dir
  dir="$WORKDIR/validate-$label/$PACKAGE"
  mkdir -p "$dir"
  cp "$catalog" "$dir/catalog.json"
  if "$OPM_CMD" validate "$WORKDIR/validate-$label"; then
    echo "  ${GREEN}opm validate OK${OFF}"
  else
    echo "  ${RED}opm validate FAILED${OFF}"
    FAILURES=$((FAILURES + 1))
  fi
}

render_fragment() { # <fragment>
  local frag="$1"
  local graph="$REPO_ROOT/$frag/graph.yaml"
  local committed="$REPO_ROOT/$frag/catalog/$PACKAGE/catalog.json"
  local out="$WORKDIR/$frag"
  mkdir -p "$out"

  cp "$graph" "$out/graph.yaml"
  : > "$out/back.sed"

  echo "${BOLD}Resolving bundle images of $frag${OFF}"
  local ref unresolved=0
  while read -r ref; do
    [[ -n "$ref" ]] || continue
    if resolve_ref "$ref"; then
      if [[ "$RESOLVED_VIA" == "mirror" ]]; then
        printf '  %bmirror%b %s\n' "$GREEN" "$OFF" "$RESOLVED_REF"
        # render through the mirror, then put the canonical ref back
        printf 's|%s|%s|g\n' "$ref" "$RESOLVED_REF" >> "$out/fwd.sed"
        printf 's|%s|%s|g\n' "$RESOLVED_REF" "$ref" >> "$out/back.sed"
      else
        printf '  source %s\n' "$ref"
      fi
    else
      unresolved=$((unresolved + 1))
      printf '  %b%-6s%b %s (%s)\n' "$RED" "$RESOLVED_VIA" "$OFF" "$ref" "$RESOLVED_ERROR"
    fi
  done < <(bundle_images_of_graph "$out/graph.yaml")

  if (( unresolved > 0 )); then
    echo "  ${RED}$unresolved bundle image(s) unreachable, cannot render $frag${OFF}"
    echo "  hint: released bundles live only in registry.redhat.io, pass --authfile"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  [[ -f "$out/fwd.sed" ]] && sed -i -f "$out/fwd.sed" "$out/graph.yaml"

  normalize_graph "$out/graph.yaml" "$out/template.yaml"

  echo "  rendering with opm $(migrate_flag_for "$frag")"
  # shellcheck disable=SC2046
  if ! "$OPM_CMD" alpha render-template basic $(migrate_flag_for "$frag") \
       "$out/template.yaml" > "$out/rendered.json" 2> "$out/render.err"; then
    echo "  ${RED}opm render-template failed${OFF}"
    sed 's/^/    /' "$out/render.err" | head -10
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  sed -i -f "$out/back.sed" "$out/rendered.json"

  local related='{}'
  if (( PRESERVE_LEGACY )) && [[ -f "$committed" ]]; then
    # same carry over as render_catalog.sh, drop it once 1.1.x is deprecated
    related=$("$JQ_CMD" -s '
      reduce .[] as $item ({};
        if ($item.schema == "olm.bundle"
            and $item.name != "rhtpa-operator.v1.0.1"
            and (["v1.0.0","v1.0.1","v1.0.2","v1.1.0","v1.1.1","v1.1.2"]
                 | any(. as $v | $item.name | contains($v))))
        then .[$item.name] = $item.relatedImages
        else . end)' "$committed")
  fi

  "$JQ_CMD" -s --indent 4 --argjson related "$related" '
    map(if .schema == "olm.bundle"
        then . + { relatedImages: ($related[.name] // .relatedImages) }
        else . end) | .[]' "$out/rendered.json" > "$out/catalog.json"

  if [[ ! -s "$out/catalog.json" ]] \
     || ! "$JQ_CMD" -s -e 'any(.[]; .schema == "olm.bundle")' "$out/catalog.json" >/dev/null 2>&1; then
    echo "  ${RED}rendered catalog is empty or malformed${OFF}"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  validate_catalog "$out/catalog.json" "$frag"
  check_images "$out/catalog.json" "$frag rendered"

  if [[ -f "$committed" ]]; then
    if diff -q "$committed" "$out/catalog.json" >/dev/null; then
      echo "  ${GREEN}rendered catalog matches the committed one${OFF}"
    else
      echo "  ${YELLOW}rendered catalog differs from the committed one${OFF}"
      diff -u "$committed" "$out/catalog.json" | head -60 || true
    fi
  fi

  if (( WRITE )); then
    mkdir -p "$(dirname "$committed")"
    cp "$out/catalog.json" "$committed"
    echo "  written: $(realpath --relative-to="$REPO_ROOT" "$committed")"
  fi
}

# ---------------------------------------------------------------------- main

for frag in "${FRAGMENTS[@]}"; do
  echo "${BOLD}=== $frag ===${OFF}"
  committed="$REPO_ROOT/$frag/catalog/$PACKAGE/catalog.json"
  if (( CHECK_ONLY )); then
    [[ -f "$committed" ]] || die "no catalog to check: $committed"
    validate_catalog "$committed" "$frag"
    check_images "$committed" "$frag committed"
  else
    [[ -f "$REPO_ROOT/$frag/graph.yaml" ]] || die "no graph.yaml in $frag"
    render_fragment "$frag" || true
  fi
  echo
done

if (( FAILURES > 0 )); then
  echo "${RED}${BOLD}FAILURE${OFF}: $FAILURES fragment check(s) failed"
  exit 1
fi
if (( WARNINGS > 0 )); then
  echo "${YELLOW}${BOLD}OK with warnings${OFF}: some images could only be reached with credentials"
  exit 0
fi
echo "${GREEN}${BOLD}OK${OFF}"
