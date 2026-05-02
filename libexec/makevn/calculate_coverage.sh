#!/usr/bin/env bash
# Script to calculate coverage metrics from JaCoCo CSV report
# Usage: calculate_coverage.sh <path_to_jacoco_csv> [min_threshold]
# Returns: exit code 0 if coverage >= threshold, 1 if < threshold

set -e
JACOCO_CSV="${1:?Error: JaCoCo CSV path is required}"
MIN_THRESHOLD="${2:-90}"
if [ ! -f "$JACOCO_CSV" ]; then
    echo "✗ Error: JaCoCo CSV file not found at $JACOCO_CSV"
    exit 1
fi
# Calculate coverage metrics from CSV
# CSV Format: GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
awk -F',' -v min_threshold="$MIN_THRESHOLD" -v green="${GREEN:-\033[0;32m}" -v nc="${NC:-\033[0m}" '
    NR>1 && NF>0 {
        if ($4 != "" && $5 != "") {
            inst_missed+=$4;
            inst_covered+=$5;
        }
        if ($6 != "" && $7 != "") {
            branch_missed+=$6;
            branch_covered+=$7;
        }
    }
    END {
        total_inst=inst_missed+inst_covered;
        total_branch=branch_missed+branch_covered;
        inst_pct=(total_inst>0)?(inst_covered*100/total_inst):0;
        branch_pct=(total_branch>0)?(branch_covered*100/total_branch):0;
        coverage_primary=inst_pct;

        printf "Notice: | Missed Instructions: %d of %d | Coverage: %.2f %% | Missed Branches: %d of %d | Coverage Branches: %.2f %% |\n",
               inst_missed, total_inst, inst_pct, branch_missed, total_branch, branch_pct;

        if (coverage_primary >= min_threshold) {
            printf "%s✓ Quality gate conditions met: current coverage=%.2f, minimum %.2f%s\n", green, coverage_primary, min_threshold, nc;
            exit 0;
        } else {
            printf "✗ Quality gate conditions not met: current coverage=%.2f, minimum %.2f\n", coverage_primary, min_threshold;
            exit 1;
        }
    }
' "$JACOCO_CSV"
