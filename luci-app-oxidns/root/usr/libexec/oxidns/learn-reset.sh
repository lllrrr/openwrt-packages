#!/bin/sh

# luci-app-oxidns: clear OxiDNS learned dynamic domain sets through the admin API.
#
# learned-cn.txt / learned-proxy.txt are machine-managed by the OxiDNS
# dynamic_domain_set provider (written by the learn_domain executor). Clearing
# them through POST /api/plugins/<tag>/rules/clear updates the in-memory
# snapshot and the persisted file, so no service restart is needed.
#
# Options live in /etc/config/oxidns (section main):
#   learn_reset_cn / learn_reset_proxy - "1" clears the respective set
#   learn_reset_api_url  - admin API base URL  (default http://127.0.0.1:9199)
#   learn_reset_api_user - admin API user      (default admin)
#   learn_reset_api_pass - admin API password  (empty = request without auth)

set -u

UCI_PACKAGE="oxidns"
UCI_SECTION="main"

uci_get() {
	KEY="$1"
	DEFAULT="$2"
	if command -v uci >/dev/null 2>&1; then
		uci -q get "$UCI_PACKAGE.$UCI_SECTION.$KEY" 2>/dev/null || printf '%s' "$DEFAULT"
	else
		printf '%s' "$DEFAULT"
	fi
}

PROVIDERS=""
[ "$(uci_get learn_reset_cn 1)" = "1" ] && PROVIDERS="learned_cn $PROVIDERS"
[ "$(uci_get learn_reset_proxy 1)" = "1" ] && PROVIDERS="learned_proxy $PROVIDERS"
PROVIDERS="${PROVIDERS# }"
PROVIDERS="${PROVIDERS% }"

if [ -z "$PROVIDERS" ]; then
	echo "no learned set selected, nothing to do"
	logger -t oxidns-learn-reset "no learned set selected, nothing to do"
	exit 0
fi

API_URL="$(uci_get learn_reset_api_url "http://127.0.0.1:9199")"
API_USER="$(uci_get learn_reset_api_user "admin")"
API_PASS="$(uci_get learn_reset_api_pass '')"
API_URL="${API_URL%/}"

FAILED=0

for PROVIDER in $PROVIDERS; do
	if [ -n "$API_PASS" ]; then
		OUT="$(curl -fsS -m 10 -u "$API_USER:$API_PASS" -X POST "$API_URL/api/plugins/$PROVIDER/rules/clear" 2>&1)"
	else
		OUT="$(curl -fsS -m 10 -X POST "$API_URL/api/plugins/$PROVIDER/rules/clear" 2>&1)"
	fi
	if [ "$?" = "0" ]; then
		echo "$PROVIDER: cleared"
		logger -t oxidns-learn-reset "$PROVIDER: cleared"
	else
		FAILED=1
		echo "$PROVIDER: failed ($OUT)"
		logger -t oxidns-learn-reset "$PROVIDER: failed ($OUT)"
	fi
done

if [ "$FAILED" = "0" ]; then
	exit 0
fi
exit 1
