#!/bin/sh
# Stub eter-storage for orchestrator unit tests. Emits logMsg-style JSON on
# stderr, honours ETER_STORAGE_JSON on stdout, and fails/hangs on demand:
#   FAKE_FAIL=1  -> exit 1 after a stderr line
#   FAKE_SLEEP=N -> sleep N seconds before finishing (cancel tests)
echo '{"comp":"storage","msg":"fake started"}' >&2
[ -n "$FAKE_SLEEP" ] && sleep "$FAKE_SLEEP"
if [ "$FAKE_FAIL" = "1" ]; then
  echo '{"comp":"storage","msg":"fake exploding"}' >&2
  echo "boom: simulated failure" >&2
  exit 1
fi
case "$1" in
  snapshot) [ "$ETER_STORAGE_JSON" = "1" ] && echo '{"snapshot":"base-fake"}' || echo base-fake ;;
  cycle)    [ "$ETER_STORAGE_JSON" = "1" ] && echo '{"took_backup":false,"archived_lsn":""}' ;;
  *)        [ "$ETER_STORAGE_JSON" = "1" ] && echo '{"rows":5,"snapshot":"base-fake"}' || echo "done" ;;
esac
exit 0
