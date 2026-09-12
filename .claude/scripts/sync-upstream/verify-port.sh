#!/usr/bin/env bash
# P4 + P5 mechanics for /sync-upstream. Run from the repo's dir after the merge:
#   verify-port.sh <PRE-sha> <sync-branch>
# Reports findings only. What to do about each is P2/P3/P5 in the command prompt.
#
# Method: compare the fork delta before and after the merge, both measured against the
# same (new) upstream ref. That is P4's stated ground truth, so it catches dropped
# patches and merge-resolution deltas in one pass.
set -uo pipefail

PRE=${1:?usage: verify-port.sh <PRE-sha> <branch>}
B=${2:?usage: verify-port.sh <PRE-sha> <branch>}
U="upstream/$B"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

adds() { git diff "$1" -- "$2" | grep '^+' | grep -v '^+++' | cut -c2- | sed '/^[[:space:]]*$/d' | sort -u; }

# Three-dot on PRE is essential: PRE predates the merge, so a two-dot diff against the
# moved-ahead upstream tip would report all of upstream's new work as "fork delta".
BEFORE="$U...$PRE"
AFTER="$U..HEAD"
git diff --name-only "$BEFORE" | sort -u > "$TMP/before"
git diff --name-only "$AFTER"  | sort -u > "$TMP/after"

echo "===== P4: fork delta vs $U ====="
echo "fork-patched files before merge: $(wc -l < "$TMP/before")   after: $(wc -l < "$TMP/after")"

echo
echo "--- files that had a fork delta and no longer do (DROPPED PATCH) ---"
comm -23 "$TMP/before" "$TMP/after" | while read -r f; do
	echo "  !! $f"
	# A dropped submodule pin is usually upstream catching up, not a lost fix — answer it here.
	[ "$(git ls-files --stage -- "$f" | cut -c1-6)" = "160000" ] || continue
	o=$(git ls-tree "$PRE" -- "$f" | awk '{print $3}')
	n=$(git ls-tree HEAD  -- "$f" | awk '{print $3}')
	if git -C "$f" merge-base --is-ancestor "$o" "$n" 2>/dev/null; then
		echo "       OK: fork pin $o is an ancestor of $n — upstream caught up, take upstream's"
	else
		echo "       !! fork pin $o is NOT an ancestor of $n — the fork fix may be lost, investigate"
	fi
done

dropped=0; invented=0
while read -r f; do
	[ -n "$f" ] || continue
	adds "$BEFORE" "$f" > "$TMP/a"
	adds "$AFTER"  "$f" > "$TMP/b"
	n=$(comm -23 "$TMP/a" "$TMP/b" | grep -c . || true)
	m=$(comm -13 "$TMP/a" "$TMP/b" | grep -c . || true)
	if [ "$n" -gt 0 ]; then
		dropped=1
		echo
		echo "  !! $f — $n fork line(s) gone (dropped patch, or a stale signature if upstream refactored the region):"
		comm -23 "$TMP/a" "$TMP/b" | head -20 | sed 's/^/       -/'
	fi
	if [ "$m" -gt 0 ]; then
		invented=1
		echo
		echo "  ?? $f — $m fork line(s) that were not there before (merge-resolution delta; P2 bullet 4 — needs its own commit):"
		comm -13 "$TMP/a" "$TMP/b" | head -20 | sed 's/^/       +/'
	fi
done < <(cat "$TMP/before" "$TMP/after" | sort -u)

echo
echo "--- file mode changes on fork-patched files (an exec bit is part of the fix) ---"
while read -r f; do
	[ -n "$f" ] || continue
	o=$(git ls-tree "$PRE" -- "$f" | awk '{print $1}')
	n=$(git ls-tree HEAD  -- "$f" | awk '{print $1}')
	[ -n "$o" ] && [ -n "$n" ] && [ "$o" != "$n" ] && echo "  !! $f  $o -> $n"
done < "$TMP/before"

echo
echo "===== P5: re-versioned vendored port dirs ====="
# Upstream bumps a vendored port by ADDING a sibling dir, so P4 sees no overlap.
vdirs() { grep -oE '(^|.*/)ports/[^/]+/[^/]+/' | sort -u; }
git diff --name-only "$PRE" HEAD | vdirs > "$TMP/newdirs"
vdirs < "$TMP/before" > "$TMP/patcheddirs"
comm -23 "$TMP/newdirs" "$TMP/patcheddirs" | while read -r d; do
	parent=$(dirname "$(dirname "$d/x")")
	if grep -q "^$parent/" "$TMP/patcheddirs"; then
		echo "  !! $d is a new sibling of a fork-patched port dir — P5 applies, forward-port into it"
		grep "^$parent/" "$TMP/patcheddirs" | sed 's/^/       old: /'
	fi
done

echo
[ "$dropped" = 0 ] && [ "$invented" = 0 ] && echo "P4: no dropped or unsignatured fork lines." || echo "P4: findings above — do NOT merge the PR until each is resolved per P2/P3."
