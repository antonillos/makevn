#!/usr/bin/env bash
#
# coverage/changes.sh - Incremental coverage analysis for changed production Java files.
#
# Requires JaCoCo aggregate HTML report already generated.
#
# Usage:
#   libexec/makevn/coverage/changes.sh <jacoco_base_dir> <base_ref> <min_coverage_pct>
#
# Environment Variables:
#   BASE_PATH - Base directory for Java modules (default: code)
#
# Examples:
#   libexec/makevn/coverage/changes.sh code/jacoco-report-aggregate/target/site/jacoco-aggregate origin/develop...HEAD 90
#


set -euo pipefail

# Accept BASE_PATH from environment or use default
BASE_PATH="${BASE_PATH:-code}"
if [ "$BASE_PATH" = "." ]; then
  BASE_PATH_PREFIX=""
  BASE_PATH_TEST_GLOB="**/src/test/java/*.java"
else
  BASE_PATH_PREFIX="$BASE_PATH/"
  BASE_PATH_TEST_GLOB="$BASE_PATH/**/src/test/java/*.java"
fi

JACOCO_BASE="${1:-}"
BASE_REF="${2:-}"
MIN_COVERAGE_PCT="${3:-90}"
MIN_OVERALL_COVERAGE_PCT="${4:-90}"
COVERAGE_VERBOSE="${COVERAGE_VERBOSE:-false}"
MIN_COVERAGE_DISPLAY="$(printf '%s' "$MIN_COVERAGE_PCT" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//; s/%$//; s/^[[:space:]]+|[[:space:]]+$//g')"

if [ -z "$JACOCO_BASE" ] || [ ! -d "$JACOCO_BASE" ]; then
  echo "✗ Error: JaCoCo base directory not found or invalid: $JACOCO_BASE" 1>&2
  exit 1
fi

if [ ! -f "$JACOCO_BASE/index.html" ]; then
  echo "✗ Error: JaCoCo report not found under: $JACOCO_BASE" 1>&2
  exit 1
fi

if [ -z "$BASE_REF" ]; then
  echo "✗ Error: base ref is required" 1>&2
  exit 1
fi

extract_added_line_numbers() {
  local file="$1"
  local diff_ref="$2"
  local line=""
  local new_line=0
  local hunk_range=""

  git diff "$diff_ref" -- "$file" -U0 | while IFS= read -r line; do
    case "$line" in
      @@\ *)
        hunk_range=$(printf '%s\n' "$line" | sed -E -n 's/^@@ .* \+([0-9]+)(,[0-9]+)? @@.*/\1/p')
        if [ -n "$hunk_range" ]; then
          new_line="$hunk_range"
        else
          new_line=0
        fi
        ;;
      +++\ *)
        ;;
      +*)
        if [ "$new_line" -gt 0 ]; then
          printf '%s\n' "$new_line"
          new_line=$((new_line + 1))
        fi
        ;;
      ---\ *)
        ;;
      -*)
        ;;
      *)
        if [ "$new_line" -gt 0 ]; then
          new_line=$((new_line + 1))
        fi
        ;;
    esac
  done
}

# Detect changed production Java files and deduplicate
# Use the same logic as verify-changes: combine base diff + local modifications
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
if [ "$CURRENT_BRANCH" = "develop" ] || [ "$CURRENT_BRANCH" = "main" ]; then
  if [ "$COVERAGE_VERBOSE" = true ]; then
    echo "ℹ  On base branch, checking for modified files (staged + unstaged, not untracked)..." 1>&2
  fi
  DIFF_NAME_ONLY_LOCAL=$(git diff --name-only HEAD 2>/dev/null || true)
  CHANGED_PROD_FILES=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH_PREFIX}" | grep "/src/main/java/" | grep "\\.java$" | sort -u || true)
  CHANGED_TEST_FILES=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH_PREFIX}" | grep "/src/test/java/" | grep "\\.java$" | sort -u || true)
else
  if [ "$COVERAGE_VERBOSE" = true ]; then
    echo "ℹ  On feature branch, checking changes vs $BASE_REF + local modifications..." 1>&2
  fi
  DIFF_NAME_ONLY_BASE=$(git diff --name-only "$BASE_REF" 2>/dev/null || true)
  DIFF_NAME_ONLY_LOCAL=$(git diff --name-only HEAD 2>/dev/null || true)

  CHANGED_PROD_FILES_BASE=$(echo "$DIFF_NAME_ONLY_BASE" | grep "^${BASE_PATH_PREFIX}" | grep "/src/main/java/" | grep "\\.java$" || true)
  CHANGED_PROD_FILES_LOCAL=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH_PREFIX}" | grep "/src/main/java/" | grep "\\.java$" || true)
  CHANGED_PROD_FILES=$( (echo "$CHANGED_PROD_FILES_BASE"; echo "$CHANGED_PROD_FILES_LOCAL") | sort -u | grep -v '^$' || true)

  CHANGED_TEST_FILES_BASE=$(echo "$DIFF_NAME_ONLY_BASE" | grep "^${BASE_PATH_PREFIX}" | grep "/src/test/java/" | grep "\\.java$" || true)
  CHANGED_TEST_FILES_LOCAL=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH_PREFIX}" | grep "/src/test/java/" | grep "\\.java$" || true)
  CHANGED_TEST_FILES=$( (echo "$CHANGED_TEST_FILES_BASE"; echo "$CHANGED_TEST_FILES_LOCAL") | sort -u | grep -v '^$' || true)
fi

# If no changes detected, check recent commits for test additions
# But ONLY if we're comparing against a base branch (not on develop/main)
if [ -z "$CHANGED_PROD_FILES" ] && [ -z "$CHANGED_TEST_FILES" ]; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "develop")

  # Only look for recent commits if we're on a feature branch
  if [ "$CURRENT_BRANCH" != "develop" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "HEAD" ]; then
    echo "ℹ  No uncommitted changes detected. Checking recent commits for test additions..." 1>&2
    # Look for test files added in recent commits ONLY if they're ahead of parent branch
    # This ensures we only detect actual new tests in this branch
    RECENT_TEST_FILES=$(git log --oneline "${BASE_REF%...HEAD}"..HEAD --name-only --diff-filter=A -- "$BASE_PATH_TEST_GLOB" 2>/dev/null | grep "/src/test/java/" | sort -u || true)
    if [ -n "$RECENT_TEST_FILES" ]; then
      CHANGED_TEST_FILES="$RECENT_TEST_FILES"
      echo "ℹ  Found recently added test files, analyzing their coverage impact..." 1>&2
    fi
  fi
fi

# Combine production files with inferred production classes from test files
CHANGED_FILES="$CHANGED_PROD_FILES"
if [ -n "$CHANGED_TEST_FILES" ]; then
  # Infer production class names from test file names
  INFERRED_PROD_CLASSES=""
  while IFS= read -r TEST_FILE; do
    [ -z "$TEST_FILE" ] && continue

    # Extract class name from test file (remove Test suffix and path)
    TEST_CLASS_NAME=$(basename "$TEST_FILE" .java)
    # Remove "Test" suffix if present
    PROD_CLASS_NAME=$(echo "$TEST_CLASS_NAME" | sed 's/Test$//' | sed 's/TestIT$//' | sed 's/IT$//')

    # Find the actual production file
    PROD_FILE=$(find . -name "${PROD_CLASS_NAME}.java" -path "*/src/main/java/*" 2>/dev/null | head -1 || true)
    if [ -n "$PROD_FILE" ]; then
      # Add relative path from project root
      REL_PROD_FILE=$(echo "$PROD_FILE" | sed 's|^\./||')
      INFERRED_PROD_CLASSES="${INFERRED_PROD_CLASSES:+$INFERRED_PROD_CLASSES$'\n'}$REL_PROD_FILE"
    fi
  done < <(printf '%s\n' "$CHANGED_TEST_FILES")

  # Combine production files with inferred ones, but only if they have actual coverage
  if [ -n "$INFERRED_PROD_CLASSES" ]; then
    VALID_INFERRED_CLASSES=""
    while IFS= read -r PROD_FILE; do
      [ -z "$PROD_FILE" ] && continue

      CLASS_NAME=$(basename "$PROD_FILE" .java)
      # Check if this class has a JaCoCo HTML file (meaning it has coverage)
      PACKAGE_PATH=$(dirname "$PROD_FILE" | sed 's|.*/src/main/java/||')
      PACKAGE_DOTS=$(echo "$PACKAGE_PATH" | tr '/' '.')

      HTML_FILE=$(find "$JACOCO_BASE" -path "*/$PACKAGE_DOTS/$CLASS_NAME.java.html" 2>/dev/null | head -1 || true)
      if [ -z "$HTML_FILE" ]; then
        HTML_FILE=$(find "$JACOCO_BASE" -name "$CLASS_NAME.java.html" 2>/dev/null | head -1 || true)
      fi
      if [ -z "$HTML_FILE" ]; then
        HTML_FILE=$(find "$JACOCO_BASE" -name "${CLASS_NAME}Impl.java.html" 2>/dev/null | head -1 || true)
      fi

      if [ -n "$HTML_FILE" ] && [ -f "$HTML_FILE" ]; then
        VALID_INFERRED_CLASSES="${VALID_INFERRED_CLASSES:+$VALID_INFERRED_CLASSES$'\n'}$PROD_FILE"
      fi
    done < <(printf '%s\n' "$INFERRED_PROD_CLASSES")

    CHANGED_FILES=$(printf '%s\n%s\n' "$CHANGED_PROD_FILES" "${VALID_INFERRED_CLASSES:-}" | sort -u)
  fi
fi

if [ -z "$CHANGED_FILES" ]; then
  # Check if we found test files but no valid production classes with coverage
  if [ -n "$CHANGED_TEST_FILES" ] && [ -n "${VALID_INFERRED_CLASSES:-}" ]; then
    # If we have test files and inferred production classes with coverage, analyze them
    CHANGED_FILES="${VALID_INFERRED_CLASSES:-}"
    if [ "$COVERAGE_VERBOSE" = true ]; then
      echo "ℹ  Found test files with corresponding production classes. Analyzing coverage..." 1>&2
    fi
  elif [ -n "$CHANGED_TEST_FILES" ]; then
    TEST_COUNT=$(echo "$CHANGED_TEST_FILES" | wc -l | xargs)
    echo "ℹ  Found $TEST_COUNT recently added test file(s), but no corresponding production classes with coverage data." 1>&2
    echo "◆ This means the tests may not be executing the production code, or coverage wasn't generated for those classes." 1>&2
    echo "◆ Try running the tests to ensure they execute the code: make test T=YourTestClass" 1>&2
    exit 0
  else
    echo "ℹ  No modified production Java files or recently added tests detected." 1>&2
    echo "◆ Try running 'make coverage-details CLASS=YourClassName' to see coverage for specific classes." 1>&2
    exit 0
  fi
fi

if [ "$COVERAGE_VERBOSE" = true ]; then
  echo "🔍 Analyzing incremental coverage for changed production files and classes tested by modified tests:" 1>&2
fi

# Best-effort: do not fail the whole command because one class has no html file.
EXIT_CODE=0
TOTAL_NEW_LINES=0
TOTAL_COVERED_LINES=0
TOTAL_MISSED_LINES=0
RESULTS_FILE=$(mktemp)

while IFS= read -r FILE; do
  [ -z "$FILE" ] && continue

  CLASS_NAME=$(basename "$FILE" .java)

  # Extract package path relative to src/main/java
  PACKAGE_PATH=$(dirname "$FILE" | sed 's|.*/src/main/java/||')
  # Convert to Jacoco's dot notation
  PACKAGE_DOTS=$(echo "$PACKAGE_PATH" | tr '/' '.')

  # Resolve JaCoCo HTML file using package and class name
  HTML_FILE=$(find "$JACOCO_BASE" -path "*/$PACKAGE_DOTS/$CLASS_NAME.java.html" 2>/dev/null | head -1 || true)
  if [ -z "$HTML_FILE" ]; then
    # Fallback: search by class name only
    HTML_FILE=$(find "$JACOCO_BASE" -name "$CLASS_NAME.java.html" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$HTML_FILE" ]; then
    # Fallback: search for MapStruct Impl version
    HTML_FILE=$(find "$JACOCO_BASE" -name "${CLASS_NAME}Impl.java.html" 2>/dev/null | head -1 || true)
  fi

  if [ -z "$HTML_FILE" ] || [ ! -f "$HTML_FILE" ]; then
    if [ "$COVERAGE_VERBOSE" = true ]; then
      echo "⊘  $CLASS_NAME: No coverage html found" 1>&2
    fi
    continue
  fi

  # Get diff information for the file
  HAS_LOCAL_CHANGES=$(git diff HEAD -- "$FILE" | head -1 || true)
  IS_INFERRED_CLASS=false
  if printf '%s\n' "${VALID_INFERRED_CLASSES:-}" | grep -q "^$FILE$"; then
    IS_INFERRED_CLASS=true
  fi

  if [ "$IS_INFERRED_CLASS" = true ]; then
    # For inferred classes (from test files), analyze all coverage, not just changed lines
    if [ "$COVERAGE_VERBOSE" = true ]; then
      echo "ℹ  $CLASS_NAME: Analyzing full class coverage (inferred from test)" 1>&2
    fi
    # Extract all line numbers that have coverage data
    ALL_LINE_NUMBERS=$(grep 'id="L[0-9]*"' "$HTML_FILE" | sed 's/.*id="L\([0-9]*\)".*/\1/' | sort -n | uniq || true)
    COVERED=0
    MISSED=0
    for LINE in $ALL_LINE_NUMBERS; do
      LINE_CLASS=$(grep "id=\"L$LINE\"" "$HTML_FILE" | grep -o 'class="[^"]*"' | cut -d'"' -f2 || echo "")
      if echo "$LINE_CLASS" | grep -q "fc"; then
        COVERED=$((COVERED + 1))
      elif echo "$LINE_CLASS" | grep -q "nc\|pc"; then
        MISSED=$((MISSED + 1))
      fi
    done
    TOTAL=$((COVERED + MISSED))
    if [ $TOTAL -gt 0 ]; then
      PERCENTAGE=$((COVERED * 100 / TOTAL))
      if [ $PERCENTAGE -ge $MIN_COVERAGE_PCT ]; then
        echo -e "${GREEN:-}✓ $CLASS_NAME: $PERCENTAGE% ($COVERED/$TOTAL lines)${NC:-}" >> "$RESULTS_FILE"
      elif [ $PERCENTAGE -ge 80 ]; then
        echo "⊘  $CLASS_NAME: $PERCENTAGE% ($COVERED/$TOTAL lines)" >> "$RESULTS_FILE"
      else
        echo "✗ $CLASS_NAME: $PERCENTAGE% ($COVERED/$TOTAL lines)" >> "$RESULTS_FILE"
      fi
      TOTAL_NEW_LINES=$((TOTAL_NEW_LINES + TOTAL))
      TOTAL_COVERED_LINES=$((TOTAL_COVERED_LINES + COVERED))
      TOTAL_MISSED_LINES=$((TOTAL_MISSED_LINES + MISSED))
    fi
    continue
  fi

  if [ -n "$HAS_LOCAL_CHANGES" ]; then
    DIFF_OUTPUT=$(git diff HEAD -- "$FILE" | grep "^+" | grep -v "^+++" | wc -l | xargs)
    CHANGED_LINES=$(extract_added_line_numbers "$FILE" HEAD || true)
  elif [ "$BASE_REF" != "HEAD" ]; then
    DIFF_OUTPUT=$(git diff "$BASE_REF" -- "$FILE" | grep "^+" | grep -v "^+++" | wc -l | xargs)
    CHANGED_LINES=$(extract_added_line_numbers "$FILE" "$BASE_REF" || true)
  else
    continue
  fi

  if [ "$DIFF_OUTPUT" = "0" ]; then continue; fi

  if [ -z "$CHANGED_LINES" ]; then
    echo "⊘  $CLASS_NAME: No added executable lines found in diff" >> "$RESULTS_FILE"
    continue
  fi

  COVERED=0
  MISSED=0
  for LINE in $CHANGED_LINES; do
    LINE_COVERAGE=$(grep -o "id=\"L$LINE\"" "$HTML_FILE" 2>/dev/null || true)
    if [ -n "$LINE_COVERAGE" ]; then
      LINE_CLASS=$(grep "id=\"L$LINE\"" "$HTML_FILE" | grep -o 'class="[^"]*"' | cut -d'"' -f2 || echo "")
      if echo "$LINE_CLASS" | grep -q "fc"; then
        COVERED=$((COVERED + 1))
      elif echo "$LINE_CLASS" | grep -q "nc\|pc"; then
        MISSED=$((MISSED + 1))
      fi
    fi
  done

  TOTAL=$((COVERED + MISSED))
  if [ $TOTAL -gt 0 ]; then
    PERCENTAGE=$((COVERED * 100 / TOTAL))
    if [ $PERCENTAGE -ge $MIN_COVERAGE_PCT ]; then
      echo -e "${GREEN:-}✓ $CLASS_NAME: $PERCENTAGE% ($COVERED/$TOTAL lines)${NC:-}" >> "$RESULTS_FILE"
    elif [ $PERCENTAGE -ge 80 ]; then
      echo "⊘  $CLASS_NAME: $PERCENTAGE% ($COVERED/$TOTAL lines)" >> "$RESULTS_FILE"
    else
      echo "✗ $CLASS_NAME: $PERCENTAGE% ($COVERED/$TOTAL lines)" >> "$RESULTS_FILE"
    fi
    TOTAL_NEW_LINES=$((TOTAL_NEW_LINES + TOTAL))
    TOTAL_COVERED_LINES=$((TOTAL_COVERED_LINES + COVERED))
    TOTAL_MISSED_LINES=$((TOTAL_MISSED_LINES + MISSED))
  else
    echo "⊘  $CLASS_NAME: No executable JaCoCo lines found in added diff lines" >> "$RESULTS_FILE"
  fi
done < <(printf '%s\n' "$CHANGED_FILES")

echo ""
echo "┌  Coverage summary"
echo "│"
echo "│  compare against  $BASE_REF"
echo "│  report           $JACOCO_BASE"
echo "│  threshold        $(printf '%.2f' "$MIN_COVERAGE_DISPLAY")%"
echo "│"
echo "├  Incremental lines"
echo "│"
if [ "$COVERAGE_VERBOSE" = true ]; then
  cat "$RESULTS_FILE"
  echo "│"
fi
if [ $TOTAL_NEW_LINES -gt 0 ]; then
  TOTAL_PERCENTAGE=$((TOTAL_COVERED_LINES * 100 / TOTAL_NEW_LINES))
  if [ $TOTAL_PERCENTAGE -ge $MIN_COVERAGE_PCT ]; then
    echo "✓  changed lines    $TOTAL_PERCENTAGE.00%  $TOTAL_COVERED_LINES/$TOTAL_NEW_LINES"
  elif [ $TOTAL_PERCENTAGE -ge 50 ]; then
    echo "⊘  changed lines    $TOTAL_PERCENTAGE.00%  $TOTAL_COVERED_LINES/$TOTAL_NEW_LINES"
  else
    echo "✗  changed lines    $TOTAL_PERCENTAGE.00%  $TOTAL_COVERED_LINES/$TOTAL_NEW_LINES"
    EXIT_CODE=1
  fi
  echo "│  missed lines     $TOTAL_MISSED_LINES"
else
  # Check if we found test files but no valid production classes with coverage
  if [ -n "$CHANGED_TEST_FILES" ]; then
    TEST_COUNT=$(echo "$CHANGED_TEST_FILES" | wc -l | xargs)
    echo "⊘  changed lines    no covered production classes inferred from $TEST_COUNT changed test file(s)"
  else
    echo "⊘  changed lines    no testable lines in changes"
  fi
fi

if [ -f "$JACOCO_BASE/jacoco.csv" ]; then
  CHANGED_CLASSES_FILE=$(mktemp)
  printf '%s\n' "$CHANGED_FILES" > "$CHANGED_CLASSES_FILE"
  set +e
  python3 - "$CHANGED_CLASSES_FILE" "$JACOCO_BASE/jacoco.csv" "$MIN_COVERAGE_PCT" <<'PY'
import csv
import os
import sys
from collections import defaultdict
from pathlib import Path

changed_files_path = Path(sys.argv[1])
jacoco_csv_path = Path(sys.argv[2])
min_threshold = float(sys.argv[3])
verbose = os.environ.get("COVERAGE_VERBOSE") == "true"


def parse_changed_file(file_path):
    marker = "/src/main/java/"
    if marker not in file_path:
        return None
    package_and_class = file_path.split(marker, 1)[1]
    package_path, class_name = package_and_class.rsplit("/", 1)
    return package_path.replace("/", "."), class_name.removesuffix(".java")


def pct(covered, missed):
    total = covered + missed
    return 100.0 if total == 0 else covered * 100.0 / total


changed_targets = {}
for raw_line in changed_files_path.read_text().splitlines():
    file_path = raw_line.strip()
    if not file_path:
        continue
    parsed = parse_changed_file(file_path)
    if parsed is not None:
        changed_targets[parsed] = file_path

if not changed_targets:
    sys.exit(0)

rows_by_fqcn = {}
with jacoco_csv_path.open(newline="") as csv_file:
    reader = csv.DictReader(csv_file)
    for row in reader:
        rows_by_fqcn[(row["PACKAGE"], row["CLASS"])] = row

matched_rows = []
missing_targets = []
for fqcn, file_path in changed_targets.items():
    row = rows_by_fqcn.get(fqcn)
    if row is None:
        missing_targets.append((fqcn, file_path))
    else:
        matched_rows.append((fqcn, file_path, row))

if not matched_rows:
    print("│")
    print("├  Changed modules")
    print("│")
    print("⊘ No changed production classes were found in jacoco.csv.")
    sys.exit(0)

module_totals = defaultdict(lambda: {
    "inst_covered": 0,
    "inst_missed": 0,
    "branch_covered": 0,
    "branch_missed": 0,
    "classes": [],
})
overall = {"inst_covered": 0, "inst_missed": 0, "branch_covered": 0, "branch_missed": 0}
all_changed_classes = []

for fqcn, file_path, row in matched_rows:
    group = row["GROUP"]
    module = group.rsplit("/", 1)[-1] if "/" in group else group
    inst_missed = int(row["INSTRUCTION_MISSED"])
    inst_covered = int(row["INSTRUCTION_COVERED"])
    branch_missed = int(row["BRANCH_MISSED"])
    branch_covered = int(row["BRANCH_COVERED"])
    line_missed = int(row["LINE_MISSED"])
    line_covered = int(row["LINE_COVERED"])
    class_info = {
        "fqcn": ".".join(fqcn),
        "file_path": file_path,
        "module": module,
        "inst_pct": pct(inst_covered, inst_missed),
        "branch_pct": pct(branch_covered, branch_missed),
        "line_covered": line_covered,
        "line_total": line_covered + line_missed,
    }

    module_totals[module]["inst_covered"] += inst_covered
    module_totals[module]["inst_missed"] += inst_missed
    module_totals[module]["branch_covered"] += branch_covered
    module_totals[module]["branch_missed"] += branch_missed
    module_totals[module]["classes"].append(class_info)
    all_changed_classes.append(class_info)
    overall["inst_covered"] += inst_covered
    overall["inst_missed"] += inst_missed
    overall["branch_covered"] += branch_covered
    overall["branch_missed"] += branch_missed

print("│")
print("├  Changed modules")
print("│")
overall_inst_pct = pct(overall["inst_covered"], overall["inst_missed"])
overall_branch_pct = pct(overall["branch_covered"], overall["branch_missed"])
print(
    f"│  changed classes  {len(matched_rows)}"
    f"  aggregate {overall_inst_pct:.2f}% instructions"
    f"  {overall['inst_covered']}/{overall['inst_covered'] + overall['inst_missed']}"
)

failing_modules = []
for module in sorted(module_totals):
    totals = module_totals[module]
    inst_pct = pct(totals["inst_covered"], totals["inst_missed"])
    branch_pct = pct(totals["branch_covered"], totals["branch_missed"])
    icon = "✓" if inst_pct >= min_threshold else "✗"
    if inst_pct < min_threshold:
        failing_modules.append((module, inst_pct))
    print(
        f"{icon}  {module:<24} {inst_pct:7.2f}%  "
        f"instructions {totals['inst_covered']}/{totals['inst_covered'] + totals['inst_missed']}  "
        f"branches {totals['branch_covered']}/{totals['branch_covered'] + totals['branch_missed']}  "
        f"classes {len(totals['classes'])}"
    )
    if verbose:
        for class_info in sorted(totals["classes"], key=lambda item: item["inst_pct"]):
            class_icon = "✓" if class_info["inst_pct"] >= min_threshold else "⊘"
            line_fragment = (
                f", lines {class_info['line_covered']}/{class_info['line_total']}"
                if class_info["line_total"] > 0
                else ""
            )
            print(
                f"│  {class_icon} {class_info['fqcn']}: "
                f"instructions {class_info['inst_pct']:.2f}%, "
                f"branches {class_info['branch_pct']:.2f}%{line_fragment}"
            )
    if verbose:
        print("│")

if missing_targets:
    print("│")
    print("├  Ignored")
    print("│")
    print(f"⊘  {len(missing_targets)} changed production classes not found in jacoco.csv")
    if verbose:
        for fqcn, file_path in missing_targets:
            print(f"│  {'.'.join(fqcn)} ({file_path})")
    else:
        print("│  run with --verbose to list ignored classes")

below_threshold_classes = sorted(
    (class_info for class_info in all_changed_classes if class_info["inst_pct"] < min_threshold),
    key=lambda item: (item["inst_pct"], item["fqcn"]),
)

if below_threshold_classes:
    print("│")
    print("├  Top offenders")
    print("│")
    for class_info in below_threshold_classes[:5]:
        print(
            f"✗  {class_info['module']:<24} "
            f"{class_info['fqcn'].rsplit('.', 1)[-1]:<42} "
            f"{class_info['inst_pct']:.2f}% instructions"
        )

if failing_modules:
    failing_summary = ", ".join(f"{module}={coverage:.2f}%" for module, coverage in failing_modules)
    print("│")
    print(
        "✗  changed module coverage gate not met: "
        f"modules below {min_threshold:.2f}% instruction coverage -> {failing_summary}"
    )
    sys.exit(1)

print(
    "✓  changed module coverage gate met: "
    f"all changed modules are >= {min_threshold:.2f}% instruction coverage"
)
PY
  MODULE_EXIT_CODE=$?
  set -e
  rm -f "$CHANGED_CLASSES_FILE"
  if [ $MODULE_EXIT_CODE -ne 0 ] && [ $EXIT_CODE -eq 0 ]; then
    EXIT_CODE=$MODULE_EXIT_CODE
  fi
fi

echo "│"
echo "├  Overall project"
echo "│"
if [ -f "$JACOCO_BASE/jacoco.csv" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  set +e
  bash "$SCRIPT_DIR/calculate.sh" "$JACOCO_BASE/jacoco.csv" "$MIN_OVERALL_COVERAGE_PCT"
  OVERALL_EXIT_CODE=$?
  set -e
  if [ $OVERALL_EXIT_CODE -ne 0 ] && [ $EXIT_CODE -eq 0 ]; then
    EXIT_CODE=$OVERALL_EXIT_CODE
  fi
else
  echo "⊘  jacoco.csv not found. Run 'make verify' to generate it."
fi

rm -f "$RESULTS_FILE"

echo "│"
if [ $EXIT_CODE -eq 0 ]; then
  echo "└  passed"
else
  echo "└  failed"
fi

exit $EXIT_CODE
