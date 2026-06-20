#!/usr/bin/env bash
set -euo pipefail

# Validate DocLang output against official XSD + Schematron schemas.
# Requires: doclang Python package and pandoc on PATH.

VENV="${1:-/tmp/doclang-venv}"
source "$VENV/bin/activate"

PANDOC="${PANDOC:-stack exec pandoc --}"

FAILED=0
TOTAL=0

validate() {
    local label="$1"
    local file="$2"
    TOTAL=$((TOTAL + 1))
    if doclang validate "$file" 2>&1 | grep -q "VALIDATION SUCCESSFUL"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label"
        doclang validate "$file" 2>&1 | grep -E "error:|FAIL" | tail -3
        FAILED=$((FAILED + 1))
    fi
}

echo "=== Validating pandoc testsuite output ==="
$PANDOC -f native -t doclang -s test/testsuite.native > /tmp/ts.dclg.xml
validate "testsuite (native -> doclang)" /tmp/ts.dclg.xml

echo "=== Validating writer test outputs (standalone) ==="
for native in test/doclang/*.native; do
    base=$(basename "$native" .native)
    $PANDOC -f native -t doclang -s "$native" > /tmp/"$base.dclg.xml"
    validate "$base (native -> doclang)" /tmp/"$base.dclg.xml"
done

echo "=== Validating reader test input ==="
validate "reader-test.doclang" test/doclang/reader-test.doclang

echo "=== Validating reader round-trip ==="
$PANDOC -f doclang -t doclang -s test/doclang/reader-test.doclang > /tmp/rt-reader.dclg.xml
validate "reader-test round-trip" /tmp/rt-reader.dclg.xml

echo "=== Validating -Werror build ==="
if stack build --fast --ghc-options='-Werror' 2>&1 | tail -1 | grep -q "Completed"; then
    echo "  PASS: -Werror build"
else
    echo "  FAIL: -Werror build"
    FAILED=$((FAILED + 1))
fi

echo ""
echo "--- Results: $TOTAL validation checks, $FAILED failures ---"
exit $FAILED
