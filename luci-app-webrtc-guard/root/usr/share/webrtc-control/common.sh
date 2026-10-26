#!/bin/sh

VERSION=1.2.3
STATE_DIR=/tmp/webrtc-control
ERROR_FILE="$STATE_DIR/last-error"

setting() {
    local value
    value=$(uci -q get "webrtc-control.global.$1")
    printf '%s\n' "${value:-$2}"
}

config_hash() {
    uci -q export webrtc-control | sha256sum | awk '{print $1}'
}

offload_enabled() {
    [ "$(uci -q get 'firewall.@defaults[0].flow_offloading')" = 1 ] ||
        [ "$(uci -q get 'firewall.@defaults[0].flow_offloading_hw')" = 1 ]
}
