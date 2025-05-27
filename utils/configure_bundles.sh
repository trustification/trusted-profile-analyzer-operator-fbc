#!/usr/bin/env bash
set -euo pipefail
OCP_VERSION="v4.18"
BUNDLE_IMAGE="quay.io/mdessi/rhtpa-rhel9-operator-bundle@sha256:e29a4432d4a0fea92f63f4787e722ae843a6ee69172b477079f26c899a3f9ea3"
BUNDLE_NAME="rhtpa-operator.v1.0.0"
GRAPH="./../${OCP_VERSION}/graph.yaml"

BUNDLE="$(yq e '(.entries[] | select(.schema=="olm.bundle" and .name=="'"$BUNDLE_NAME"'"))' $GRAPH)"
if [[ -n "$BUNDLE" ]]; then
  echo "Bundle '$BUNDLE_NAME' found. Updating image..."
  yq e '(.entries[] | select(.schema=="olm.bundle" and .name=="'"$BUNDLE_NAME"'")).image = "'"$BUNDLE_IMAGE"'"' -i $GRAPH
else
  echo "Bundle '$BUNDLE_NAME' not found. Adding new entry..."
  yq e '.entries += [{"image": "'"$BUNDLE_IMAGE"'", "name": "'"$BUNDLE_NAME"'", "schema": "olm.bundle"}]' -i $GRAPH
fi
