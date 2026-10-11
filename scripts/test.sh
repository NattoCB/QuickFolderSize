#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 Sources/Scanner.swift Tests/ScannerTests.swift -o build/scanner-tests
build/scanner-tests
