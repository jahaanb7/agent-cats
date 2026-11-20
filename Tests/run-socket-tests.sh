#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BINARY=$(mktemp /tmp/agentcats-socket-tests.XXXXXX)
trap 'rm -f "$TEST_BINARY"' EXIT
swiftc -swift-version 5 -o "$TEST_BINARY" Sources/Shared/ApprovalProtocol.swift Sources/Core/Approvals.swift Sources/Core/EventServer.swift Sources/Core/Summary.swift Sources/Core/Parsers.swift Sources/Core/Models.swift Sources/Shared/ProcInfo.swift Tests/Socket/main.swift
"$TEST_BINARY"
