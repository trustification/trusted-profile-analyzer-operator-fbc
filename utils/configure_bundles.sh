#!/usr/bin/env bash
set -euo pipefail
OCP_VERSION="v4.18"
BUNDLE_IMAGE="registry.redhat.io/rhtpa/rhtpa-operator-bundle@sha256:0df36cba6289fe01f48d7463c2f4190a71879cf505257c12e6d8880fda83eb7b"
BUNDLE_NAME="rhtpa-operator.v1.0.1"
GRAPH="./../${OCP_VERSION}/graph.yaml"

BUNDLE="$(yq e '(.entries[] | select(.schema=="olm.bundle" and .name=="'"$BUNDLE_NAME"'"))' $GRAPH)"
if [[ -n "$BUNDLE" ]]; then
  echo "Bundle '$BUNDLE_NAME' found. Updating image..."
  yq e '(.entries[] | select(.schema=="olm.bundle" and .name=="'"$BUNDLE_NAME"'")).image = "'"$BUNDLE_IMAGE"'"' -i $GRAPH
else
  echo "Bundle '$BUNDLE_NAME' not found. Adding new entry..."
  yq e '.entries += [{"image": "'"$BUNDLE_IMAGE"'", "name": "'"$BUNDLE_NAME"'", "schema": "olm.bundle"}]' -i $GRAPH
fi
