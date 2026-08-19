#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$DIR/.build"
# Swift requires top-level executable code to be in a file named main.swift.
# Symlink the test harness under that name so swiftc accepts it.
MAIN="$DIR/.build/main.swift"
ln -sf "$DIR/Tests/QuestionParserTests.swift" "$MAIN"
swiftc "$DIR/Sources/QuestionParser.swift" "$MAIN" -o "$DIR/.build/parsertests"
"$DIR/.build/parsertests"
