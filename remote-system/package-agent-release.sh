#!/bin/zsh

set -euo pipefail

readonly ROOT="${0:A:h}"
readonly AGENT_DIR="${ROOT}/agent"
readonly OUTPUT="${1:-${ROOT}/releases/unified-task-agent-windows.zip}"
readonly STAGING="$(/usr/bin/mktemp -d /tmp/unified-task-agent-release.XXXXXX)"
readonly PACKAGE="${STAGING}/unified-task-agent"

cleanup() { /bin/rm -R "${STAGING}"; }
trap cleanup EXIT

/bin/mkdir -p "${PACKAGE}" "${OUTPUT:h}"
for source in \
    agent.py \
    load_test.py \
    submission_locks.py \
    processor_adapter.py \
    supabase_client.py \
    mock_processor.py \
    requirements.txt \
    run_agent.bat \
    check_agent.bat \
    install_startup.ps1 \
    uninstall_startup.ps1
do
    /bin/cp "${AGENT_DIR}/${source}" "${PACKAGE}/${source}"
done
/bin/cp "${ROOT}/README.md" "${PACKAGE}/README.md"
/bin/cp "${ROOT}/.env.example" "${PACKAGE}/.env.example"

readonly ARCHIVE="${STAGING}/unified-task-agent-windows.zip"
(
    cd "${STAGING}"
    /usr/bin/zip -qr "${ARCHIVE}" unified-task-agent
)
/bin/mv "${ARCHIVE}" "${OUTPUT}"
print "Built Agent release: ${OUTPUT}"
