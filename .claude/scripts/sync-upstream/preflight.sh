#!/usr/bin/env bash
# Steps 1-3 of /sync-upstream for both repos in one call. Read-only apart from `git fetch`.
# Reports facts; every decision stays in .claude/commands/sync-upstream.md.
set -uo pipefail

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

repo() {
	local name=$1 dir=$2 branch=$3 fork=$4
	echo
	echo "===== $name  (branch: $branch) ====="
	[ -d "$dir/.git" ] || { echo "SKIP: $dir is not a git repo"; return; }
	cd "$dir" || { echo "SKIP: cannot enter $dir"; return; }

	# -uno on purpose: .claude/ and CLAUDE.md are untracked-not-ignored here and always show as `??`.
	local dirty; dirty=$(git status --porcelain -uno)
	if [ -n "$dirty" ]; then echo "SKIP: dirty tree"; echo "$dirty"; return; fi

	local head; head=$(git symbolic-ref --quiet --short HEAD || echo DETACHED)
	[ "$head" = "$branch" ] || { echo "SKIP: on '$head', expected '$branch'"; return; }

	local o u; o=$(git remote get-url origin 2>/dev/null); u=$(git remote get-url upstream 2>/dev/null)
	echo "origin:   $o"
	echo "upstream: $u"
	case "$o" in *"$fork"*) ;; *) echo "SKIP: origin is not $fork (invariant 1)"; return;; esac
	case "$u" in *PathOfBuildingCommunity*) ;; *) echo "SKIP: upstream is not PathOfBuildingCommunity"; return;; esac
	echo "tree clean, on $branch, remotes OK"

	git fetch upstream "$branch" --quiet || echo "WARN: fetch upstream failed"
	git fetch origin "$branch" --quiet || echo "WARN: fetch origin failed"

	local behind ahead base
	behind=$(git rev-list --count "$branch..upstream/$branch")
	ahead=$(git rev-list --count "upstream/$branch..$branch")
	base=$(git merge-base "$branch" "upstream/$branch")

	echo
	echo "--- upstream ahead by $behind ---"
	[ "$behind" -gt 0 ] && git log --oneline "$branch..upstream/$branch"

	echo "--- fork-only commits ($ahead total, non-merge listed) ---"
	git log --oneline --no-merges "upstream/$branch..$branch"

	# Ground truth for the fork delta (P4), not the commit list.
	git diff --name-only "upstream/$branch...$branch" > "$TMP/fork"
	git diff --name-only "$base" "upstream/$branch" > "$TMP/up"

	echo "--- fork-only files (git diff upstream/$branch...$branch) ---"
	cat "$TMP/fork"

	echo "--- P3 candidates: upstream touched a file the fork patches ---"
	comm -12 <(sort "$TMP/fork") <(sort "$TMP/up") | sed 's/^/  /' || true
	echo "  (empty does NOT mean safe — P5 hides from this check)"

	echo "--- submodule pins in the fork delta (check reachability per Context) ---"
	while read -r f; do
		[ -n "$f" ] || continue
		[ "$(git ls-files --stage -- "$f" | cut -c1-6)" = "160000" ] && echo "  $f"
	done < "$TMP/fork"

	[ "$behind" -eq 0 ] && echo ">>> UP TO DATE — nothing to merge for this repo"
	return 0
}

repo "PoB-PoE2"       "$HOME/Documents/PathOfBuilding-PoE2"        dev    pathanin/PathOfBuilding-PoE2
repo "SimpleGraphic"  "$HOME/Documents/PathOfBuilding-SimpleGraphic" master pathanin/PathOfBuilding-SimpleGraphic
