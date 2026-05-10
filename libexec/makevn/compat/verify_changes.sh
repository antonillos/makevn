#!/usr/bin/env bash
#
# Verify Changes Script
# Runs tests only for changed modules compared to parent branch
#

set -euo pipefail

# Arguments
BASE_PATH="${1:-code}"
LOCAL_TEST="${2:-TRUE}"
PARENT_BRANCH="${3:-origin/develop...HEAD}"
JACOCO_MODULE="${4:-jacoco-report-aggregate}"

info() {
    echo -e "${BLUE}ℹ  $1${NC:-}"
}

success() {
    echo -e "${GREEN:-}✓ $1${NC:-}"
}

warning() {
    echo -e "${YELLOW}⊘  $1${NC:-}"
}

error() {
    echo -e "${RED}✗ $1${NC:-}"
}

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "develop" ] || [ "$CURRENT_BRANCH" = "main" ] || [ "$PARENT_BRANCH" = "HEAD" ]; then
    info "On base branch, checking for modified files (staged + unstaged, not untracked)..."
    DIFF_NAME_ONLY_LOCAL=$(git diff --name-only HEAD || true)
    CHANGED_JAVA_SRC=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH}/" | grep "/src/main/java/" | grep "\.java$" || true)
    CHANGED_JAVA_TEST=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH}/" | grep "/src/test/java/" | grep "\.java$" || true)
else
    info "On feature branch, checking changes vs $PARENT_BRANCH + local modifications..."
    DIFF_NAME_ONLY_BASE=$(git diff --name-only "$PARENT_BRANCH" || true)
    DIFF_NAME_ONLY_LOCAL=$(git diff --name-only HEAD || true)
    CHANGED_JAVA_SRC_BASE=$(echo "$DIFF_NAME_ONLY_BASE" | grep "^${BASE_PATH}/" | grep "/src/main/java/" | grep "\.java$" || true)
    CHANGED_JAVA_SRC_LOCAL=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH}/" | grep "/src/main/java/" | grep "\.java$" || true)
    CHANGED_JAVA_SRC=$(echo "$CHANGED_JAVA_SRC_BASE
$CHANGED_JAVA_SRC_LOCAL" | sort -u | grep -v '^$' || true)
    CHANGED_JAVA_TEST_BASE=$(echo "$DIFF_NAME_ONLY_BASE" | grep "^${BASE_PATH}/" | grep "/src/test/java/" | grep "\.java$" || true)
    CHANGED_JAVA_TEST_LOCAL=$(echo "$DIFF_NAME_ONLY_LOCAL" | grep "^${BASE_PATH}/" | grep "/src/test/java/" | grep "\.java$" || true)
    CHANGED_JAVA_TEST=$(echo "$CHANGED_JAVA_TEST_BASE
$CHANGED_JAVA_TEST_LOCAL" | sort -u | grep -v '^$' || true)
fi

if [ -z "$CHANGED_JAVA_SRC" ] && [ -z "$CHANGED_JAVA_TEST" ]; then
    info "No modified Java files detected in ${BASE_PATH}. Skipping verification."
    exit 0
fi

if [ -n "$CHANGED_JAVA_SRC" ]; then
    echo "📝 Modified production files ($(echo "$CHANGED_JAVA_SRC" | wc -l | xargs)):"
    echo "$CHANGED_JAVA_SRC" | head -10 | sed 's|^|   |'
    if [ $(echo "$CHANGED_JAVA_SRC" | wc -l) -gt 10 ]; then
        echo "   ... and $(expr $(echo "$CHANGED_JAVA_SRC" | wc -l) - 10) more files"
    fi
fi

if [ -n "$CHANGED_JAVA_TEST" ]; then
    echo "📝 Modified test files ($(echo "$CHANGED_JAVA_TEST" | wc -l | xargs)):"
    echo "$CHANGED_JAVA_TEST" | head -10 | sed 's|^|   |'
    if [ $(echo "$CHANGED_JAVA_TEST" | wc -l) -gt 10 ]; then
        echo "   ... and $(expr $(echo "$CHANGED_JAVA_TEST" | wc -l) - 10) more files"
    fi
fi

if [ -n "$CHANGED_JAVA_SRC" ]; then
    echo ""
    echo "⊙ Strategy: Production code changed → Running ALL tests of affected modules"
    echo "   (to ensure nothing breaks)"
    MODULES=$(echo "$CHANGED_JAVA_SRC" | \
        sed "s|^${BASE_PATH}/||" | \
        sed 's|/src/.*||' | \
        sort -u | \
        tr '\n' ',' | \
        sed 's/,$//')
    if [ -z "$MODULES" ]; then
        warning "Changes detected but no specific modules identified. Running full verify."
        exit 1  # Let Makefile handle fallback
    else
        echo "◇ Affected modules: $MODULES"
        echo ""
        echo "🧪 Running unit and integration tests to generate complete coverage report..."
        echo "   (Note: This ensures make coverage works correctly)"
        echo ""
        # Run tests (set +e temporarily to capture exit code)
        set +e
        mvn -f "${BASE_PATH}" \
            -DskipTests=false \
            -Dmaven.build.cache.enabled=false \
            -pl "$MODULES,$JACOCO_MODULE" \
            -Djacoco.skip=false \
            verify -nsu
        TEST_EXIT_CODE=$?
        set -e
        if [ $TEST_EXIT_CODE -ne 0 ]; then
            error "Tests failed with exit code $TEST_EXIT_CODE"
            exit $TEST_EXIT_CODE
        fi
        success "Modified modules verified successfully."
        echo "▓ Coverage report generated at: ${BASE_PATH}/${JACOCO_MODULE}/target/site/jacoco-aggregate/index.html"
    fi
elif [ -n "$CHANGED_JAVA_TEST" ]; then
    echo ""
    echo "⊙ Strategy: Only tests changed → Running ONLY modified tests"
    echo "   (faster, production code unchanged)"
    TEST_CLASSES=$(echo "$CHANGED_JAVA_TEST" | \
        sed 's|^.*/src/test/java/||' | \
        sed 's|\.java$||' | \
        sed 's|/|.|g')
    TEST_COUNT=$(echo "$TEST_CLASSES" | wc -l | xargs)
    if [ $TEST_COUNT -gt 5 ]; then
        warning "Warning: $TEST_COUNT tests changed. This might take a while."
        echo "◆ Consider running full verify if you changed many tests: make verify"
    fi
    TEST_LIST=$(echo "$TEST_CLASSES" | tr '\n' ',' | sed 's/,$//')
    echo "🧪 Running $TEST_COUNT test(s): $TEST_LIST"
    echo ""
    set +e  # Temporarily disable exit-on-error to capture exit code
    LOCAL_CONTAINERS=${LOCAL_TEST} mvn -f "${BASE_PATH}" \
        -DskipUTs=false \
        -Dtest="$TEST_LIST" \
        -Dit.test="$TEST_LIST" \
        -Dfailsafe.failIfNoSpecifiedTests=false -Dsurefire.failIfNoSpecifiedTests=false \
        -Dawaitility.defaultPollInterval=200ms -Dawaitility.defaultTimeout=2m \
        -Djacoco.skip=false \
        -Dmaven.build.cache.enabled=false \
        verify -nsu
    TEST_EXIT_CODE=$?
    set -e  # Re-enable exit-on-error
    if [ $TEST_EXIT_CODE -eq 141 ]; then
        TEST_EXIT_CODE=0
    fi
    if [ $TEST_EXIT_CODE -ne 0 ]; then
        error "Tests failed with exit code $TEST_EXIT_CODE"
        exit $TEST_EXIT_CODE
    fi
    success "Modified tests executed successfully."
fi
