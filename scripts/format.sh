#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--check" ]; then
    xcrun swift-format lint --strict --recursive Sources Tests scripts Package.swift
else
    xcrun swift-format format --in-place --recursive Sources Tests scripts Package.swift
fi
