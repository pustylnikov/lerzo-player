#!/bin/bash
# Prints how many times each release DMG has been downloaded from GitHub Releases,
# plus the repository traffic GitHub keeps for the last 14 days.
#
#   scripts/downloads.sh
#
# The per-asset counter includes Sparkle updates (they fetch the same URL), so it is
# "installs + updates", not unique users; GitHub refreshes it with a few minutes' lag.
# Traffic needs push access to the repository. Requires `gh auth login`.
set -euo pipefail

GITHUB_REPO="pustylnikov/lerzo-player"

echo "Downloads"
gh api "repos/$GITHUB_REPO/releases" --paginate \
    --jq '.[] | "  \(.tag_name)\t\(.published_at[:10])\t" + ([.assets[] | "\(.name): \(.download_count)"] | join(", "))'
total=$(gh api "repos/$GITHUB_REPO/releases" --paginate --jq '[.[].assets[].download_count] | add // 0')
echo "  total: $total"

echo
echo "Traffic (last 14 days: total / unique)"
views=$(gh api "repos/$GITHUB_REPO/traffic/views" --jq '"\(.count) / \(.uniques)"')
clones=$(gh api "repos/$GITHUB_REPO/traffic/clones" --jq '"\(.count) / \(.uniques)"')
echo "  page views: $views"
echo "  clones:     $clones"
