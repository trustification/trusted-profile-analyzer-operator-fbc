# RHTPA Operator FBC

File-Based Catalog for Red Hat Trusted Profile Analyzer Operator

## How to update

Update config.yaml with a new bundle digest, order doesn't matter. Use utils to generate and verify the new catalog, then commit and push back to this repo, don't use a fork.

```
$ utils/generate.sh
$ utils/verify-catalog.sh
```

Then open a pull request to `main` branch, and confirm the status of the checks that are run against the PR. If you're satisfied, you can get the index image coordinates through:

```
$ util/get-fbc-images-for-pr.sh rhbk/rhbk-fbc PR_NUMBER_GOES_HERE
```

The PR cannot be merged until all the new images contained in the new bundle, and the new bundle itself, are tested and published.
