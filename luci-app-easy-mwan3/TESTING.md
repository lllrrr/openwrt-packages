# Testing Guide

## Automated Testing

Run the test script to verify your installation:

```bash
/usr/bin/easy_mwan3_test.sh
```

### Test Coverage

The test script checks:

1. **Configuration**
   - Config file existence and format
   - Required sections and options

2. **Dependencies**
   - mwan3 package installation
   - Required tools (ip, iptables)

3. **Firewall Compatibility**
   - fw3/fw4 detection
   - Compatibility warnings

4. **Scripts**
   - All utility scripts existence
   - Script permissions

5. **Interfaces**
   - Interface existence
   - Interface status (online/offline)

6. **MWAN3 Service**
   - Service status
   - Service enabled

## Manual Testing

### 1. Configuration Validation

Validate your configuration:

```bash
/usr/bin/easy_mwan3_validate.sh config
```

### 2. Status Check

Check interface status:

```bash
/usr/bin/easy_mwan3_status.sh json
```

Check service status:

```bash
/usr/bin/easy_mwan3_status.sh service
```

### 3. Apply Configuration

Apply configuration manually:

```bash
/usr/bin/easy_mwan3_apply.sh
```

### 4. View Logs

View Easy MWAN3 logs:

```bash
logread | grep easy_mwan3
```

View MWAN3 logs:

```bash
logread | grep mwan3
```

## Common Issues

### 1. Configuration Not Applied

**Symptoms**: Settings changed but not effective

**Solution**:
```bash
# Apply configuration
/usr/bin/easy_mwan3_apply.sh

# Restart MWAN3
/etc/init.d/mwan3 restart
```

### 2. Interfaces Not Detected

**Symptoms**: Interfaces show as "not found"

**Solution**:
```bash
# Check interface status
ubus call network.interface.wan status

# Verify interface is configured
uci show network.wan
```

### 3. fw4 Incompatibility

**Symptoms**: MWAN3 doesn't work on OpenWrt 22.03+

**Solution**:
- Use Policy Based Routing (pbr) instead
- Or downgrade to fw3

## Integration Testing

### Test Load Balancing

1. Configure two WAN interfaces
2. Set mode to "balance"
3. Apply configuration
4. Test with multiple downloads:

```bash
# Test on WAN1
curl --interface eth0 http://speedtest.example.com/test.bin

# Test on WAN2
curl --interface eth1 http://speedtest.example.com/test.bin
```

### Test Failover

1. Configure two WAN interfaces
2. Set mode to "failover"
3. Apply configuration
4. Disconnect primary WAN
5. Verify traffic switches to backup

### Test Device Policies

1. Configure device-specific policy
2. Apply configuration
3. Test from specific device:

```bash
# Ping test
ping -I 192.168.1.100 8.8.8.8

# Check routing
ip route get 8.8.8.8 from 192.168.1.100
```

## Performance Testing

### Load Test

Test with multiple concurrent connections:

```bash
# Install iperf3
opkg install iperf3

# Run server on remote host
iperf3 -s

# Run client test
iperf3 -c <server_ip> -P 10 -t 60
```

### Latency Test

Test latency over different interfaces:

```bash
# Test WAN1
ping -I eth0 -c 100 8.8.8.8

# Test WAN2
ping -I eth1 -c 100 8.8.8.8
```

## Debug Mode

Enable debug logging:

```bash
# Enable debug
uci set easy_mwan3.global.debug=1
uci commit easy_mwan3

# View debug logs
logread -f | grep easy_mwan3

# Disable debug
uci set easy_mwan3.global.debug=0
uci commit easy_mwan3
```
