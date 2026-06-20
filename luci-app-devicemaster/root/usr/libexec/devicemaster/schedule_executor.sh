#!/bin/sh
# DeviceMaster Schedule Executor
# Executes block/limit rules based on schedule configuration

. /lib/functions.sh

CONFIG="devicemaster"
TRAFFIC_CONTROL="/usr/libexec/devicemaster/traffic_control.sh"

# Get current time and day
CURRENT_HOUR=$(date +%H)
CURRENT_MIN=$(date +%M)
CURRENT_TIME="${CURRENT_HOUR}:${CURRENT_MIN}"
CURRENT_DAY=$(date +%w)  # 0=Sunday, 1=Monday, ...

# Check if current day is in schedule days
is_day_active() {
    local schedule_days="$1"
    for day in $schedule_days; do
        [ "$day" = "$CURRENT_DAY" ] && return 0
    done
    return 1
}

# Parse time HH:MM to minutes since midnight
time_to_minutes() {
    local time_str="$1"
    local hour=$(echo "$time_str" | cut -d':' -f1)
    local min=$(echo "$time_str" | cut -d':' -f2)
    echo $((hour * 60 + min))
}

# Check if current time is between start and end
is_time_in_range() {
    local start_time="$1"
    local end_time="$2"
    
    local current_min=$(time_to_minutes "$CURRENT_TIME")
    local start_min=$(time_to_minutes "$start_time")
    local end_min=$(time_to_minutes "$end_time")
    
    if [ $start_min -le $end_min ]; then
        # Normal range: start < end (e.g., 08:00 - 22:00)
        if [ $current_min -ge $start_min ] && [ $current_min -lt $end_min ]; then
            return 0
        fi
    else
        # Cross midnight: start > end (e.g., 22:00 - 08:00)
        if [ $current_min -ge $start_min ] || [ $current_min -lt $end_min ]; then
            return 0
        fi
    fi
    return 1
}

# Get devices in a group
get_group_devices() {
    local group_name="$1"
    local devices=""
    
    config_load "$CONFIG"
    config_foreach check_device_group device "$group_name"
}

check_device_group() {
    local section="$1"
    local target_group="$2"
    local mac group groups group_name
    
    config_get mac "$section" mac
    config_get group "$section" group
    config_get groups "$section" groups
    [ -z "$mac" ] && return
    
    # Check if device belongs to target group
    if [ "$target_group" = "all" ]; then
        echo "$mac"
    elif [ -n "$group" ] && [ "$group" = "$target_group" ]; then
        # Single group attribute
        echo "$mac"
    elif [ -n "$group" ]; then
        group_name=$(uci -q get "devicemaster.$group.name" 2>/dev/null)
        if [ -n "$group_name" ] && [ "$group_name" = "$target_group" ]; then
            echo "$mac"
        fi
    elif [ -n "$groups" ]; then
        # Legacy: multiple groups (comma-separated)
        local IFS=','
        for g in $groups; do
            g=$(echo "$g" | tr -d ' ')
            if [ "$g" = "$target_group" ]; then
                echo "$mac"
                break
            fi
        done
    fi
}

# Execute block action
execute_block() {
    local mac="$1"
    local action="$2"  # block or unblock
    
    if [ "$action" = "block" ]; then
        # Add to block list (using iptables or traffic_control)
        $TRAFFIC_CONTROL block "$mac" 2>/dev/null
        logger -t devicemaster "Schedule: blocked $mac"
    else
        $TRAFFIC_CONTROL unblock "$mac" 2>/dev/null
        logger -t devicemaster "Schedule: unblocked $mac"
    fi
}

# Execute limit action
execute_limit() {
    local mac="$1"
    local rate="$2"
    local action="$3"  # limit or unlimit
    
    if [ "$action" = "limit" ]; then
        $TRAFFIC_CONTROL limit "$mac" "$rate" 2>/dev/null
        logger -t devicemaster "Schedule: limited $mac to $rate"
    else
        $TRAFFIC_CONTROL unlimit "$mac" 2>/dev/null
        logger -t devicemaster "Schedule: unlimit $mac"
    fi
}

# Process all schedules
process_schedules() {
    config_load "$CONFIG"
    config_foreach process_schedule schedule
}

process_schedule() {
    local section="$1"
    local name action group start_time end_time rate custom_rate days
    
    config_get name "$section" name
    config_get action "$section" action
    config_get group "$section" group
    config_get start_time "$section" start_time "22:00"
    config_get end_time "$section" end_time "08:00"
    config_get rate "$section" rate "1mbit"
    config_get custom_rate "$section" custom_rate ""
    config_get days "$section" days "1 2 3 4 5"
    
    # Use custom_rate if rate is "custom"
    if [ "$rate" = "custom" ] && [ -n "$custom_rate" ]; then
        rate="$custom_rate"
    fi
    
    # Check if today is active
    if ! is_day_active "$days"; then
        # Outside scheduled days - ensure devices are unblocked/unlimited
        local devices=$(get_group_devices "$group")
        for mac in $devices; do
            if [ "$action" = "block" ]; then
                execute_block "$mac" "unblock"
            elif [ "$action" = "limit" ]; then
                execute_limit "$mac" "" "unlimit"
            fi
        done
        return
    fi
    
    # Check if current time is in range
    if is_time_in_range "$start_time" "$end_time"; then
        # In range - apply restriction
        local devices=$(get_group_devices "$group")
        for mac in $devices; do
            if [ "$action" = "block" ]; then
                execute_block "$mac" "block"
            elif [ "$action" = "limit" ]; then
                execute_limit "$mac" "$rate" "limit"
            fi
        done
    else
        # Out of range - remove restriction
        local devices=$(get_group_devices "$group")
        for mac in $devices; do
            if [ "$action" = "block" ]; then
                execute_block "$mac" "unblock"
            elif [ "$action" = "limit" ]; then
                execute_limit "$mac" "" "unlimit"
            fi
        done
    fi
}

# Main
# Show schedule status
show_schedule_status() {
    local section="$1"
    local name action group start_time end_time days
    
    config_get name "$section" name "Unknown"
    config_get action "$section" action "block"
    config_get group "$section" group "all"
    config_get start_time "$section" start_time "22:00"
    config_get end_time "$section" end_time "08:00"
    config_get days "$section" days "1 2 3 4 5"
    
    local active="No"
    if is_day_active "$days"; then
        if is_time_in_range "$start_time" "$end_time"; then
            active="Yes (ACTIVE)"
        else
            active="Yes (inactive time)"
        fi
    fi
    
    echo "  - $name: $action $group [$start_time-$end_time] Days:$days | Active: $active"
}

case "$1" in
    run)
        process_schedules
        ;;
    status)
        # Show current schedule status
        echo "Current time: $CURRENT_TIME, Day: $CURRENT_DAY"
        echo "Schedules:"
        config_load "$CONFIG"
        config_foreach show_schedule_status schedule
        ;;
    *)
        echo "Usage: $0 {run|status}"
        exit 1
        ;;
esac
