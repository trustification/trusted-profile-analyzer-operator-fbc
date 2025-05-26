#!/usr/bin/env bash
set -euo pipefail

BUNDLE_IMAGE="quay.io/mdessi/rhtpa-rhel9-operator-bundle@sha256:0b5a80a1db8b8db8143c6a487f57006c86412df8c9c26d4aa61eea2cf1079332"
BUNDLE_NAME="rhtpa-operator.v1.0.0"
GRAPH="./../v4.18/graph.yaml"

BUNDLE="$(yq e '(.entries[] | select(.schema=="olm.bundle" and .name=="'"$BUNDLE_NAME"'"))' $GRAPH)"
if [[ -n "$BUNDLE" ]]; then
  echo "Bundle '$BUNDLE_NAME' found. Updating image..."
  yq e '(.entries[] | select(.schema=="olm.bundle" and .name=="'"$BUNDLE_NAME"'")).image = "'"$BUNDLE_IMAGE"'"' -i $GRAPH
else
  echo "Bundle '$BUNDLE_NAME' not found. Adding new entry..."
  yq e '.entries += [{"image": "'"$BUNDLE_IMAGE"'", "name": "'"$BUNDLE_NAME"'", "schema": "olm.bundle"}]' -i $GRAPH
fi
