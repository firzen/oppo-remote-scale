#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary=$(mktemp /tmp/oppo-todo-tests.XXXXXX)
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library Sources/Todo/DingTalkClient.swift Tests/DingTalkClientTests.swift -o "$binary"
"$binary"
