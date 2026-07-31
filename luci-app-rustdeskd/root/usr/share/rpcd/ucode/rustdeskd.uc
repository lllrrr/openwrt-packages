#!/usr/bin/env ucode
'use strict';

import { popen, access, readfile, unlink } from 'fs';
import { process_list, init_enabled, init_action } from 'luci.sys';

const BIN_DIR = '/usr/bin';
const KEY_DIR = '/etc/rustdesk';

/*
 * Helper functions to reduce code duplication
 */

// Shell escape a string to prevent command injection
function shellquote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

// Get PID of a process by name using luci.sys.process_list()
function getProcessPid(process_name) {
	for (let proc in process_list()) {
		if (index(proc.COMMAND, process_name) >= 0) {
			return proc.PID;
		}
	}
	return null;
}

// Execute a command and return trimmed output (for version queries only)
function execCommand(bin, args) {
	let result = null;
	let cmd = shellquote(bin) + ' ' + args;
	let pp = popen(cmd, 'r');
	if (pp) {
		let output = pp.read('all');
		pp.close();
		if (output) {
			result = trim(output);
		}
	}
	return result;
}

// Check if a file exists
function fileExists(path) {
	return !!access(path);
}

// Read file content and trim
function readFileContent(path) {
	let content = readfile(path);
	return content ? trim(content) : null;
}

// Safe file deletion
function safeUnlink(path) {
	return unlink(path) || false;
}

const methods = {
	get_status: {
		call: function() {
			// Check if service is enabled for boot using luci.sys.init_enabled()
			let boot_enabled = init_enabled('rustdeskd');

			return {
				hbbs_pid: getProcessPid('hbbs'),
				hbbr_pid: getProcessPid('hbbr'),
				hbbs_exists: fileExists(BIN_DIR + '/hbbs'),
				hbbr_exists: fileExists(BIN_DIR + '/hbbr'),
				boot_enabled: boot_enabled
			};
		}
	},

	get_public_key: {
		call: function() {
			let key_path = KEY_DIR + '/id_ed25519.pub';
			let key_exists = fileExists(key_path);
			let public_key = null;

			if (key_exists) {
				public_key = readFileContent(key_path);
			}

			return {
				key_exists: key_exists,
				public_key: public_key,
				key_path: key_path
			};
		}
	},

	service_action: {
		args: { action: 'action' },
		call: function(req) {
			let action = '';

			if (req && req.args && req.args.action) {
				action = req.args.action;
			}

			// Validate action - whitelist approach
			const valid_actions = ['start', 'stop', 'restart', 'reload', 'enable', 'disable'];
			if (index(valid_actions, action) < 0) {
				return {
					success: false,
					error: 'Invalid action. Allowed: ' + join(', ', valid_actions)
				};
			}

			// Use luci.sys.init_action() for service control
			let result = init_action('rustdeskd', action);

			return {
				success: (result === 0),
				action: action,
				exit_code: result
			};
		}
	},

	get_version: {
		call: function() {
			return {
				hbbs_version: fileExists(BIN_DIR + '/hbbs') ? execCommand(BIN_DIR + '/hbbs', '--version 2>&1') : null,
				hbbr_version: fileExists(BIN_DIR + '/hbbr') ? execCommand(BIN_DIR + '/hbbr', '--version 2>&1') : null
			};
		}
	},

	regenerate_key: {
		call: function() {
			let key_priv = KEY_DIR + '/id_ed25519';
			let key_pub = KEY_DIR + '/id_ed25519.pub';

			// Step 1: Stop the service first so keys are not in use
			// init_action is synchronous - waits for service to fully stop
			init_action('rustdeskd', 'stop');

			// Step 2: Remove existing keys
			let priv_deleted = safeUnlink(key_priv);
			let pub_deleted = safeUnlink(key_pub);

			// Verify keys are deleted
			let keys_deleted = !fileExists(key_priv) && !fileExists(key_pub);

			// The UI will call restart to regenerate the keys
			// hbbs automatically generates new keys on startup if they don't exist

			return {
				success: keys_deleted,
				keys_deleted: keys_deleted,
				priv_deleted: priv_deleted,
				pub_deleted: pub_deleted,
				key_path: key_pub,
				message: keys_deleted ? 'Keys deleted. Restart service to generate new keys.' : 'Failed to delete keys'
			};
		}
	},

	update_core: {
		call: function() {
			let pp = popen('/usr/libexec/rustdeskd-update.sh', 'r');
			let output = '';
			if (pp) {
				output = pp.read('all');
				let code = pp.close();
				return {
					success: (code === 0),
					output: output,
					exit_code: code
				};
			}
			return {
				success: false,
				output: 'Failed to execute script',
				exit_code: -1
			};
		}
	},

	create_backup: {
		call: function() {
			let tmp_tar = '/tmp/rustdesk_backup.tar.gz';
			safeUnlink(tmp_tar);
			
			// Package /etc/rustdesk and /etc/config/rustdeskd
			// Make sure /etc/rustdesk exists before tar so it doesn't fail
			execCommand('mkdir', '-p /etc/rustdesk');
			let tar_res = execCommand('tar', '-czf ' + tmp_tar + ' -C / etc/rustdesk/ etc/config/rustdeskd');
			
			// Encode to base64
			let b64 = execCommand('base64', tmp_tar);
			safeUnlink(tmp_tar);
			
			return {
				success: (b64 != null),
				data: b64
			};
		}
	},

	restore_backup: {
		args: { data: 'data' },
		call: function(req) {
			if (!req || !req.args || !req.args.data) {
				return { success: false, error: 'No data provided' };
			}
			
			let tmp_b64 = '/tmp/rustdesk_restore.b64';
			let tmp_tar = '/tmp/rustdesk_restore.tar.gz';
			let extract_dir = '/tmp/rustdesk_extract';
			
			let fs = require('fs');
			let f = fs.open(tmp_b64, 'w');
			if (!f) return { success: false, error: 'Failed to create temp file' };
			f.write(req.args.data);
			f.close();
			
			// Decode base64
			execCommand('base64', '-d ' + tmp_b64 + ' > ' + tmp_tar);
			
			let exit_code = 1;
			if (fileExists(tmp_tar)) {
				// Clean and create extract dir
				execCommand('rm', '-rf ' + extract_dir);
				execCommand('mkdir', '-p ' + extract_dir);
				
				// Extract to temp dir, check exit code
				let pp = popen('tar -xzf ' + tmp_tar + ' -C ' + extract_dir, 'r');
				if (pp) {
					pp.read('all');
					exit_code = pp.close();
				}
				
				if (exit_code === 0) {
					// Verify it looks like a rustdesk backup
					if (fileExists(extract_dir + '/etc/rustdesk') || fileExists(extract_dir + '/etc/config/rustdeskd')) {
						// It's valid, move to real location
						init_action('rustdeskd', 'stop');
						if (fileExists(extract_dir + '/etc/rustdesk')) {
							execCommand('rm', '-rf /etc/rustdesk');
							execCommand('mv', extract_dir + '/etc/rustdesk /etc/rustdesk');
						}
						if (fileExists(extract_dir + '/etc/config/rustdeskd')) {
							execCommand('mv', extract_dir + '/etc/config/rustdeskd /etc/config/rustdeskd');
						}
						init_action('rustdeskd', 'start');
					} else {
						exit_code = 2; // Invalid structure
					}
				}
			}
			
			// Cleanup
			safeUnlink(tmp_b64);
			safeUnlink(tmp_tar);
			execCommand('rm', '-rf ' + extract_dir);
			
			if (exit_code === 0) {
				return { success: true };
			} else if (exit_code === 2) {
				return { success: false, error: 'Invalid backup format' };
			}
			
			return { success: false, error: 'Extraction failed or corrupted file' };
		}
	}
};

return { 'luci.rustdeskd': methods };
