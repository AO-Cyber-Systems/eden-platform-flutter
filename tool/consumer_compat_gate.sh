#!/usr/bin/env bash
#
# consumer_compat_gate.sh — enumerate every package that depends on
# eden_platform_flutter, then run each one's analyzer AND test suite, emitting a
# deterministic, machine-diffable before/after state.
#
# Written for AOID objective 50 (50-CONTEXT.md D2, TRD 50-06). D2 requires that
# the riverpod 2 -> 3 alignment's blast radius be enumerated as committed,
# re-runnable DATA and that each affected consumer's SUITE actually runs -- a
# compile check is explicitly not the gate. This script is re-run by 50-25,
# 50-26 and 50-14, so its output must diff cleanly against itself.
#
# ---------------------------------------------------------------------------
# READ THIS BEFORE TRUSTING A GREEN RESULT
# ---------------------------------------------------------------------------
# Consumers pin eden_platform_flutter by **git ref**, e.g.
#
#     eden_platform_flutter:
#       git:
#         url: https://github.com/AO-Cyber-Systems/eden-platform-flutter.git
#         ref: a26fb08099cf71a6b6d5ba0f5c857fce43457787
#
# `flutter pub get` therefore resolves eden from ~/.pub-cache/git/ at THAT REF.
# It does NOT see uncommitted work, and it does NOT see unpushed local branches
# such as obj50/aoid-module. Every result below is the state of the consumer
# against its PINNED eden, not against your working tree.
#
# That is exactly what a BEFORE-state should be, and it is why the pinned ref is
# recorded as a column. But it means a run of this script cannot, on its own,
# prove that a change to eden is safe. 50-26 must re-run it AFTER repointing
# each consumer's ref at the new eden, or it will report a false green.
# (Objective 50 already hit this once: 50-04's portal gate analysed a
# ~/.pub-cache/git/ snapshot and reported "0 new errors" while blind to the
# change under test.)
#
# ---------------------------------------------------------------------------
# READ-ONLY CONTRACT
# ---------------------------------------------------------------------------
# Several consumer repositories hold other people's uncommitted work. This
# script never edits, stages, stashes, cleans or commits in a consumer. The only
# writes `flutter pub get` performs are pubspec.lock and .dart_tool/; this script
# snapshots pubspec.lock beforehand and restores its exact bytes afterwards, and
# it records each package's `git status --porcelain` before and after so that any
# drift is visible in the output rather than silent.
#
# Usage:
#   tool/consumer_compat_gate.sh [options]
#
#   --only <path>        Gate only this package (repeatable). Path may be
#                        absolute or relative to the search root.
#   --skip-tests         Enumerate + pub get + analyze, but do not run suites.
#                        Every package is then labelled test=SKIPPED(--skip-tests).
#   --tests-for <csv>    Run suites ONLY for these packages (substring match on
#                        the package path); all others are labelled
#                        test=SKIPPED(not-in---tests-for). Lets the giant
#                        (eden-biz/flutter, 284 sites) be handled separately
#                        without producing an unlabelled partial run.
#   --root <dir>         Search root. Default ~/dev.
#   --enumerate-only     Stage 1 only.
#   --explain-failures   Stage 3 only: for each package whose `pub get` fails,
#                        print the solver's own explanation and classify the
#                        cause (riverpod vs a pre-existing conflict). Fast --
#                        version solving fails in seconds. Use this instead of
#                        running `flutter pub get` by hand in a consumer: it is
#                        the only form of the check that honours the read-only
#                        contract below. An ad-hoc `pub get` DOES leave
#                        pubspec.lock churn behind in a consumer repo.
#   --timeout <secs>     Per-command timeout. Default 900.
#   -h, --help           This message.
#
# Output: two tab-separated sections, each sorted by package path.
#
#   Stage 1  <package> <eden_platform.dart> <networking.dart> <observability.dart>
#            <declared riverpod> <resolved riverpod> <pinned eden ref>
#   Stage 2  <package> pubget=<ok|fail> analyze=<count|UNRESOLVABLE>
#            test=<passed>/<total>|SKIPPED(reason)|UNRESOLVABLE git=<clean|DIRTY-BEFORE|CHANGED-BY-GATE>
#
# Every failure is tolerated and recorded; the script never aborts on one
# unreachable consumer, because a gate that dies on the first failure produces
# no data at all.

set -uo pipefail

ROOT="${HOME}/dev"
SKIP_TESTS=0
ENUMERATE_ONLY=0
EXPLAIN_ONLY=0
TIMEOUT=900
declare -a ONLY=()
TESTS_FOR=""

usage() { sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)           ONLY+=("$2"); shift 2 ;;
    --skip-tests)     SKIP_TESTS=1; shift ;;
    --tests-for)      TESTS_FOR="$2"; shift 2 ;;
    --root)           ROOT="$2"; shift 2 ;;
    --enumerate-only) ENUMERATE_ONLY=1; shift ;;
    --explain-failures) EXPLAIN_ONLY=1; shift ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

EDEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDEN_HEAD="$(git -C "$EDEN_DIR" rev-parse --short HEAD 2>/dev/null || echo UNKNOWN)"
EDEN_BRANCH="$(git -C "$EDEN_DIR" branch --show-current 2>/dev/null || echo UNKNOWN)"

# `timeout` is not present by default on macOS; degrade to running unbounded
# rather than failing every package.
if command -v timeout >/dev/null 2>&1; then
  TO() { timeout "$TIMEOUT" "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  TO() { gtimeout "$TIMEOUT" "$@"; }
else
  TO() { "$@"; }
fi

# ---------------------------------------------------------------------------
# Stage 1 — enumerate
# ---------------------------------------------------------------------------
# The exclusions are NOT optional. An earlier enumeration attempt for this
# objective was polluted by ~15 `recycling-oracle` agent worktrees and produced a
# badly inflated repository list.
find_pubspecs() {
  find "$ROOT" -maxdepth 5 -name pubspec.yaml \
    -not -path "*/.pub-cache/*" \
    -not -path "*/worktrees/*" \
    -not -path "*/.state/*" \
    -not -path "*/build/*" \
    -not -path "*/.dart_tool/*" \
    2>/dev/null \
  | xargs grep -l "eden_platform_flutter" 2>/dev/null \
  | sed 's#/pubspec.yaml$##' \
  | sort -u
}

# Count import SITES (occurrences, not files) of one eden barrel across the
# package's Dart sources.
count_barrel() {
  local pkg="$1" barrel="$2" n=0 d
  for d in lib test integration_test test_driver; do
    [[ -d "$pkg/$d" ]] || continue
    local c
    c=$(grep -rho "package:eden_platform_flutter/${barrel}\.dart" "$pkg/$d" 2>/dev/null | wc -l | tr -d ' ')
    n=$((n + c))
  done
  echo "$n"
}

declared_riverpod() {
  grep -E "^[[:space:]]+flutter_riverpod:" "$1/pubspec.yaml" 2>/dev/null \
    | head -1 | sed -E 's/.*flutter_riverpod:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' \
    | tr -d '"' | sed 's/^$/NONE/'
}

# The RESOLVED version, which is not the declared constraint: AODex declares
# ^3.0.0 and resolves 3.2.1.
resolved_riverpod() {
  local lock="$1/pubspec.lock"
  [[ -f "$lock" ]] || { echo "NO-LOCK"; return; }
  awk '
    /^  flutter_riverpod:/ { inpkg=1; next }
    inpkg && /^  [^ ]/     { inpkg=0 }
    inpkg && /^    version:/ {
      gsub(/^    version:[ ]*/, ""); gsub(/"/, ""); print; exit
    }
  ' "$lock" | sed 's/^$/NO-ENTRY/' | head -1
}

# How the consumer EFFECTIVELY reaches eden.
#
# `dependency_overrides` beats the `dependencies` block for the root package, so
# a consumer can declare a frozen git `ref:` and still resolve eden from the
# local working tree. Reading only the dependencies block gets this wrong: both
# aoid-plans/portal and aoid-household/portal declare `ref: 6200455` while
# overriding eden to an absolute local path. Report the override when present.
#
# This distinction decides whether a row is evidence about the local branch or
# about a frozen upstream commit, so it must be resolved in precedence order.
override_eden_path() {
  awk '
    /^dependency_overrides:/ { ino=1; next }
    /^[a-z_]+:/ && !/^dependency_overrides:/ { ino=0 }
    ino && /^  eden_platform_flutter:/ { inp=1; next }
    ino && inp && /^[[:space:]]*path:/ {
      sub(/^[[:space:]]*path:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      print; exit
    }
    ino && inp && /^  [a-z_]/ { inp=0 }
  ' "$1/pubspec.yaml" 2>/dev/null | head -1
}

pinned_eden_ref() {
  local ov
  ov="$(override_eden_path "$1")"
  if [[ -n "$ov" ]]; then
    echo "override-path:${ov}"
    return
  fi
  local ps="$1/pubspec.yaml"
  local ref
  ref=$(awk '
    /eden_platform_flutter:/ { inpkg=1 }
    inpkg && /^[[:space:]]*ref:/ {
      sub(/^[[:space:]]*ref:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/"/, ""); print; exit
    }
    inpkg && /^[[:space:]]*path:/ {
      sub(/^[[:space:]]*path:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      print "path:" $0; exit
    }
    inpkg && /^  [a-z_]+:/ && !/eden_platform_flutter:/ { inpkg=0 }
  ' "$ps" 2>/dev/null | head -1)
  ref="${ref:-UNPINNED}"
  # Abbreviate git SHAs for readability, but NEVER truncate a `path:` value.
  # A path dependency resolves eden from the LOCAL WORKING TREE, so such a
  # consumer sees uncommitted eden changes immediately, while a git-ref consumer
  # is frozen at its pinned commit. That distinction decides whether a row below
  # is evidence about this branch or about upstream, so it must survive intact.
  if [[ "$ref" =~ ^[0-9a-f]{20,}$ ]]; then
    echo "${ref:0:12}"
  else
    echo "$ref"
  fi
}

selected() {
  local pkg="$1" o
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  for o in "${ONLY[@]}"; do
    [[ "$pkg" == *"$o"* ]] && return 0
  done
  return 1
}

CMDLINE="tool/consumer_compat_gate.sh $*"
echo "# eden_platform_flutter consumer compatibility gate"
echo "# generated:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# command:        ${CMDLINE% }"
echo "# eden HEAD:      ${EDEN_HEAD} (branch ${EDEN_BRANCH})"
echo "# search root:    ${ROOT}"
echo "# flutter:        $(flutter --version 2>/dev/null | head -1)"
echo "#"
echo "# WARNING: consumers pin eden by git ref. These results describe each"
echo "#          consumer against its PINNED eden, NOT against eden HEAD above."
echo "#          Re-run after repointing refs or this is a false green."
echo "#"

PKGS=$(find_pubspecs)

echo "## stage1: package<TAB>eden_platform.dart<TAB>networking.dart<TAB>observability.dart<TAB>declared_riverpod<TAB>resolved_riverpod<TAB>pinned_eden_ref"
{
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    selected "$pkg" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${pkg#$ROOT/}" \
      "$(count_barrel "$pkg" eden_platform)" \
      "$(count_barrel "$pkg" networking)" \
      "$(count_barrel "$pkg" observability)" \
      "$(declared_riverpod "$pkg")" \
      "$(resolved_riverpod "$pkg")" \
      "$(pinned_eden_ref "$pkg")"
  done <<< "$PKGS"
} | sort
echo

[[ $ENUMERATE_ONLY -eq 1 ]] && exit 0

# ---------------------------------------------------------------------------
# Stage 3 — explain pub-get failures (READ-ONLY, fast)
# ---------------------------------------------------------------------------
# Not every failure is the riverpod bump's fault, and planning Stage D as if it
# were would schedule doubly-blocked consumers as simple constraint bumps.
if [[ $EXPLAIN_ONLY -eq 1 ]]; then
  echo "## stage3: package<TAB>cause<TAB>solver explanation"
  {
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      selected "$pkg" || continue
      rel="${pkg#$ROOT/}"

      lock_backup=""
      if [[ -f "$pkg/pubspec.lock" ]]; then
        lock_backup="$(mktemp)"; cp "$pkg/pubspec.lock" "$lock_backup"
      fi

      out="$(TO flutter pub get --directory "$pkg" 2>&1)"
      rc=$?

      # Restore BEFORE classifying -- a failed `pub get` can still rewrite or
      # delete pubspec.lock, and that churn is indistinguishable from a human's
      # uncommitted work once it is left behind.
      if [[ -n "$lock_backup" ]]; then
        cmp -s "$lock_backup" "$pkg/pubspec.lock" 2>/dev/null || cp "$lock_backup" "$pkg/pubspec.lock"
        rm -f "$lock_backup"
      fi

      [[ $rc -eq 0 ]] && continue   # only failures are interesting here

      why="$(printf '%s\n' "$out" | grep -E '^(Because|So,)' | head -2 | tr '\n' ' ' | sed 's/  */ /g')"
      if printf '%s' "$why" | grep -q "flutter_riverpod"; then
        cause="RIVERPOD-caused-by-this-alignment"
      elif printf '%s' "$why" | grep -qE "flutter_secure_storage|sentry_flutter"; then
        cause="PRE-EXISTING-unrelated-conflict"
      else
        cause="OTHER"
      fi
      printf '%s\t%s\t%s\n' "$rel" "$cause" "$why"
    done <<< "$PKGS"
  } | sort
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage 2 — gate (READ-ONLY)
# ---------------------------------------------------------------------------
echo "## stage2: package<TAB>pubget<TAB>analyze<TAB>test<TAB>git"
{
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    selected "$pkg" || continue
    rel="${pkg#$ROOT/}"

    # --- read-only snapshot -------------------------------------------------
    before_status="$(git -C "$pkg" status --porcelain 2>/dev/null || echo NOGIT)"
    lock_backup=""
    if [[ -f "$pkg/pubspec.lock" ]]; then
      lock_backup="$(mktemp)"
      cp "$pkg/pubspec.lock" "$lock_backup"
    fi

    # --- pub get ------------------------------------------------------------
    if TO flutter pub get --directory "$pkg" >/dev/null 2>&1; then
      pubget=ok
    else
      pubget=fail
    fi

    # --- analyze ------------------------------------------------------------
    if [[ "$pubget" == ok ]]; then
      an_out="$(TO flutter analyze --no-pub "$pkg" 2>&1)"
      an_n="$(printf '%s\n' "$an_out" | grep -cE '^[[:space:]]*(error|warning|info|hint) •' || true)"
      analyze="$an_n"
    else
      analyze="UNRESOLVABLE"
    fi

    # --- test ---------------------------------------------------------------
    if [[ $SKIP_TESTS -eq 1 ]]; then
      test_res="SKIPPED(--skip-tests)"
    elif [[ "$pubget" != ok ]]; then
      test_res="UNRESOLVABLE"
    elif [[ ! -d "$pkg/test" ]]; then
      test_res="SKIPPED(no-test-dir)"
    elif [[ -n "$TESTS_FOR" ]] && ! printf '%s' "$TESTS_FOR" | tr ',' '\n' | grep -qF -- "$rel"; then
      test_res="SKIPPED(not-in---tests-for)"
    else
      t_out="$(cd "$pkg" && TO flutter test --reporter json 2>&1)"
      # Count testDone events, ignoring the hidden "loading <file>" pseudo-tests
      # that the Dart JSON reporter emits.
      counts="$(printf '%s\n' "$t_out" \
        | jq -Rc 'fromjson? // empty' 2>/dev/null \
        | jq -s -r '[.[] | select(.type=="testDone" and .hidden==false)]
                    | "\([.[] | select(.result=="success")] | length)/\(length)"' 2>/dev/null)"
      if [[ -z "$counts" || "$counts" == "0/0" ]]; then
        test_res="UNRESOLVABLE(no-json)"
      else
        test_res="$counts"
      fi
    fi

    # --- restore + verify read-only ----------------------------------------
    if [[ -n "$lock_backup" ]]; then
      if ! cmp -s "$lock_backup" "$pkg/pubspec.lock"; then
        cp "$lock_backup" "$pkg/pubspec.lock"   # restore exact prior bytes
      fi
      rm -f "$lock_backup"
    fi
    after_status="$(git -C "$pkg" status --porcelain 2>/dev/null || echo NOGIT)"
    if [[ "$before_status" == "$after_status" ]]; then
      if [[ -z "$before_status" ]]; then gitcol="clean"; else gitcol="DIRTY-BEFORE(unchanged-by-gate)"; fi
    else
      gitcol="CHANGED-BY-GATE"
    fi

    printf '%s\tpubget=%s\tanalyze=%s\ttest=%s\tgit=%s\n' \
      "$rel" "$pubget" "$analyze" "$test_res" "$gitcol"
  done <<< "$PKGS"
} | sort
