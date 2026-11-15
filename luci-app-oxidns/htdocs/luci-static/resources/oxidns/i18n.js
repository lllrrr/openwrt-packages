'use strict';
'require baseclass';

/*
 * The rpcd backend reports success and error text in English. Translate the
 * known messages here so the LuCI pages stay localized, and keep the raw text
 * for anything unrecognized (for example validator or init script output).
 */

var built = false;
var messages = {};
var details = {};

function build() {
	if (built)
		return;

	built = true;

	messages = {
		'configuration is valid': _('Configuration is valid.'),
		'configuration saved': _('Configuration saved.'),
		'configuration saved and service restarted': _('Configuration saved. OxiDNS was restarted.'),
		'configuration file not found': _('Configuration file not found.'),
		'configuration content is required': _('Configuration content is required.'),
		'no configuration content or file available': _('No configuration content or file is available.'),
		'configuration file changed since it was loaded': _('The configuration file changed since it was loaded. Reload it and try again.'),
		'configuration saved, but init script was not found': _('Configuration saved, but the init script was not found.'),
		'log path saved': _('Log path saved.'),
		'log path saved and service restarted': _('Log path saved. OxiDNS was restarted.'),
		'log path saved, but init script was not found': _('Log path saved, but the init script was not found.'),
		'log directory is required': _('Log directory is required.'),
		'log directory must be an absolute OxiDNS-related directory path': _('The log directory must be an absolute OxiDNS-related directory path.'),
		'OxiDNS configuration file was not found': _('The OxiDNS configuration file was not found.'),
		'unable to create the log directory': _('Unable to create the log directory.'),
		'the log directory is not writable': _('The log directory is not writable.'),
		'unable to update the configuration file': _('Unable to update the configuration file.'),
		'failed to prepare core operation lock directory': _('Failed to prepare the core operation lock directory.'),
		'another OxiDNS core operation is already running': _('Another OxiDNS core operation is already running.'),
		'Install the OxiDNS core before using service controls': _('Install the OxiDNS core before using service controls.'),
		'service action failed': _('Service action failed.'),
		'core_repository must use owner/repo format': _('The core repository must use the owner/repo format.'),
		'core_repository contains unsupported characters': _('The core repository contains unsupported characters.'),
		'core bundle must be one of full, standard, minimal': _('The core bundle must be one of full, standard, or minimal.'),
		'config_path must be an absolute OxiDNS-related file path': _('The config path must be an absolute OxiDNS-related file path.'),
		'working_dir must be an absolute OxiDNS-related directory path': _('The working directory must be an absolute OxiDNS-related directory path.'),
		'github_token must be a single-line value': _('The GitHub token must be a single-line value.'),
		'failed to commit oxidns settings': _('Failed to save the OxiDNS settings.'),
		'log_syslog must be 0 or 1': _('The system log setting must be 0 or 1.'),
		'settings values must be single-line strings': _('Settings values must be single-line strings.'),
		'uci command not found': _('The uci command was not found.'),
		'current CPU architecture does not match a published OxiDNS Linux musl release': _('The current CPU architecture does not match a published OxiDNS Linux musl release.'),
		'selected OxiDNS release does not contain the required archive': _('The selected OxiDNS release does not contain the required archive.'),
		'failed to fetch OxiDNS release metadata': _('Failed to fetch OxiDNS release metadata.'),
		'selected OxiDNS release asset does not include a valid SHA256 digest': _('The selected OxiDNS release asset does not include a valid SHA256 digest.'),
		'failed to download OxiDNS core archive': _('Failed to download the OxiDNS core archive.'),
		'OxiDNS core archive SHA256 does not match the release digest': _('The OxiDNS core archive SHA256 does not match the release digest.'),
		'OxiDNS core archive contains unsafe paths or links': _('The OxiDNS core archive contains unsafe paths or links.'),
		'failed to unpack OxiDNS core archive': _('Failed to unpack the OxiDNS core archive.'),
		'OxiDNS core archive does not contain an oxidns binary': _('The OxiDNS core archive does not contain an oxidns binary.'),
		'OxiDNS core archive does not contain config.yaml': _('The OxiDNS core archive does not contain config.yaml.'),
		'release config.yaml cannot be adapted for OpenWrt defaults': _('The release config.yaml cannot be adapted for OpenWrt defaults.'),
		'failed to stage OxiDNS WebUI files': _('Failed to stage the OxiDNS WebUI files.'),
		'OxiDNS release archive does not contain WebUI files': _('The OxiDNS release archive does not contain WebUI files.'),
		'core was not replaced because the service could not be stopped': _('The core was not replaced because the service could not be stopped.'),
		'failed to install OxiDNS core files; the existing installation was left unchanged': _('Failed to install the OxiDNS core files; the existing installation was left unchanged.'),
		'core installed, but service restart failed': _('The core was installed, but the service restart failed.'),
		'download_proxy is configured, but curl is not installed; install curl or clear download_proxy': _('A download proxy is configured, but curl is not installed. Install curl or clear the download proxy.'),
		'uploaded file must be a readable /tmp/oxidns-core-upload-* file': _('The uploaded file must be a readable /tmp/oxidns-core-upload-* file.'),
		'OxiDNS core is already installed; use repair reinstall instead': _('The OxiDNS core is already installed. Use Repair Reinstall instead.'),
		'OxiDNS core is not installed or cannot report its version': _('The OxiDNS core is not installed or cannot report its version.'),
		'refusing to delete unsafe configuration path': _('Refusing to delete an unsafe configuration path.'),
		'refusing to delete unsafe working directory': _('Refusing to delete an unsafe working directory.'),
		'failed to preserve configuration before removing working directory': _('Failed to preserve the configuration before removing the working directory.'),
		'uploaded archive contains unsafe paths or links': _('The uploaded archive contains unsafe paths or links.'),
		'uploaded archive does not contain an oxidns binary': _('The uploaded archive does not contain an oxidns binary.'),
		'uploaded oxidns binary cannot report build-info': _('The uploaded oxidns binary cannot report build information.'),
		'uploaded config.yaml cannot be adapted for OpenWrt defaults': _('The uploaded config.yaml cannot be adapted for OpenWrt defaults.'),
		'uploaded core does not contain WebUI files': _('The uploaded core does not contain WebUI files.'),
		'failed to install uploaded core files; the existing installation was left unchanged': _('Failed to install the uploaded core files; the existing installation was left unchanged.'),
		'failed to unpack uploaded OxiDNS archive': _('Failed to unpack the uploaded OxiDNS archive.'),
		'dnsmasq is not available': _('dnsmasq is not available.'),
		'start OxiDNS before enabling system DNS integration': _('Start OxiDNS before enabling system DNS integration.'),
		'Cannot determine the OxiDNS DNS listen address.': _('Cannot determine the OxiDNS DNS listen address.'),
		'OxiDNS must expose an IPv4 DNS listen address.': _('OxiDNS must expose an IPv4 DNS listen address.'),
		'OxiDNS has multiple UDP DNS listen addresses.': _('OxiDNS has multiple UDP DNS listen addresses.'),
		'OxiDNS has multiple TCP DNS listen addresses.': _('OxiDNS has multiple TCP DNS listen addresses.'),
		'OxiDNS must listen for both UDP and TCP DNS.': _('OxiDNS must listen for both UDP and TCP DNS.'),
		'OxiDNS UDP and TCP DNS listeners must use the same port.': _('OxiDNS UDP and TCP DNS listeners must use the same port.'),
		'OxiDNS UDP and TCP DNS listeners do not share a reachable IPv4 address.': _('OxiDNS UDP and TCP DNS listeners do not share a reachable IPv4 address.'),
		'OxiDNS is not listening on the configured DNS port. Restart OxiDNS and try again.': _('OxiDNS is not listening on the configured DNS port. Restart OxiDNS and try again.'),
		'the saved dnsmasq forwarding entry is missing': _('The saved dnsmasq forwarding entry is missing.'),
		'the OxiDNS DNS listen address changed; disable and enable system DNS integration again': _('The OxiDNS DNS listen address changed. Disable and enable system DNS integration again.'),
		'dnsmasq noresolv is no longer set': _('dnsmasq noresolv is no longer set.'),
		'dnsmasq is not running': _('dnsmasq is not running.'),
		'system DNS integration is already enabled': _('System DNS integration is already enabled.'),
		'system DNS integration is not enabled': _('System DNS integration is not enabled.'),
		'failed to save DNS integration state': _('Failed to save the DNS integration state.'),
		'failed to update dnsmasq configuration': _('Failed to update the dnsmasq configuration.'),
		'the saved DNS integration state is invalid': _('The saved DNS integration state is invalid.'),
		'another system DNS integration operation is already running': _('Another system DNS integration operation is already running.'),
		'failed to prepare the DNS integration lock directory': _('Failed to prepare the DNS integration lock directory.'),
		'DNS integration was disabled, but the saved state could not be cleared. Try disabling again.': _('DNS integration was disabled, but the saved state could not be cleared. Try disabling again.'),
		'dnsmasq could not be reloaded; the settings will apply the next time dnsmasq starts': _('dnsmasq could not be reloaded. The settings will apply the next time dnsmasq starts.'),
		'dnsmasq is not running; the settings will apply when dnsmasq starts': _('dnsmasq is not running. The settings will apply when dnsmasq starts.')
	};

	details = {
		'service stop failed': _('Service stop failed.'),
		'service restart failed': _('Service restart failed.'),
		'tar extraction failed': _('Tar extraction failed.'),
		'none of curl, uclient-fetch, or wget is installed': _('None of curl, uclient-fetch, or wget is installed.'),
		'failed to resolve the latest release tag from github.com': _('Failed to resolve the latest release tag from github.com.'),
		'failed to fetch release assets from github.com': _('Failed to fetch release assets from github.com.'),
		'unknown download error': _('Unknown download error.'),
		'expected file: oxidns': _('The archive must contain a file named oxidns.'),
		'the uploaded binary either is not executable for this target or build-info failed': _('The uploaded binary is not executable for this target, or build-info failed.'),
		'download_proxy only works with curl on OpenWrt': _('A download proxy only works with curl on OpenWrt.'),
		'install_directory_failed': _('Failed to create the install directory.'),
		'binary_write_failed': _('Failed to write the oxidns binary.'),
		'binary_replace_failed': _('Failed to replace the oxidns binary.'),
		'webui_replace_failed': _('Failed to replace the WebUI files.'),
		'cannot wait for OxiDNS to stop: ubus and jsonfilter are required': _('Cannot wait for OxiDNS to stop: ubus and jsonfilter are required.'),
		'failed to query OxiDNS service state while stopping': _('Failed to query the OxiDNS service state while stopping.'),
		'invalid OxiDNS service state while stopping': _('The OxiDNS service state is invalid while stopping.'),
		'invalid OxiDNS service instance state while stopping': _('The OxiDNS service instance state is invalid while stopping.'),
		'timed out waiting for the old OxiDNS service instance to be removed': _('Timed out waiting for the old OxiDNS service instance to be removed.'),
		'unknown': _('Unknown')
	};
}

function translateCurlReason(reason) {
	switch (reason) {
	case 'Error':
		return _('error');
	case 'Connection refused':
		return _('connection refused');
	case 'Network is unreachable':
		return _('network is unreachable');
	case 'No route to host':
		return _('no route to host');
	case 'Connection timed out':
		return _('connection timed out');
	default:
		return reason;
	}
}

function translateCurlMessage(message) {
	var match;

	match = message.match(/^Failed to connect to ([\s\S]*?) after (\d+) ms: ([\s\S]+)$/);
	if (match)
		return _('could not connect to %s after %s ms: %s').format(match[1], match[2], translateCurlReason(match[3]));

	match = message.match(/^Could not resolve host: ([\s\S]+)$/);
	if (match)
		return _('could not resolve host %s').format(match[1]);

	match = message.match(/^Connection timed out after (\d+) milliseconds$/);
	if (match)
		return _('connection timed out after %s ms').format(match[1]);

	match = message.match(/^Operation timed out after (\d+) milliseconds with (\d+) bytes received$/);
	if (match)
		return _('operation timed out after %s ms with %s bytes received').format(match[1], match[2]);

	match = message.match(/^The requested URL returned error: (\d+)$/);
	if (match)
		return _('the requested URL returned error %s').format(match[1]);

	if (message === 'SSL connect error')
		return _('SSL connection error');

	return '';
}

function translateDetailValuePart(value) {
	if (value === 'missing')
		return _('missing');
	if (value === 'unknown')
		return _('Unknown');
	return value;
}

function translateCommandError(value) {
	var match = value.match(/^([\w.-]+) exited with code (\d+)(?:: ([\s\S]+))?$/);
	var inner;
	var curl;

	if (!match)
		return '';

	if (!match[3])
		return _('%s exited with code %s').format(match[1], match[2]);

	inner = match[3];
	curl = inner.match(/^curl: \((\d+)\) ([\s\S]+)$/);
	if (curl) {
		var translated = translateCurlMessage(curl[2]);
		inner = translated || curl[2];
	}

	return _('%s exited with code %s: %s').format(match[1], match[2], inner);
}

function translateDetailValue(value) {
	var match;
	var translated;

	if (details[value])
		return details[value];

	translated = translateCommandError(value);
	if (translated)
		return translated;

	match = value.match(/^curl: \(\d+\) ([\s\S]+)$/);
	if (match && translateCurlMessage(match[1]))
		return translateCurlMessage(match[1]);

	match = value.match(/^release tag cannot be used in a github\.com URL: ([\s\S]+)$/);
	if (match)
		return _('The release tag cannot be used in a github.com URL: %s.').format(match[1]);

	match = value.match(/^github\.com release page does not contain a SHA256 digest for ([\s\S]+)$/);
	if (match)
		return _('The github.com release page does not contain a SHA256 digest for %s.').format(match[1]);

	match = value.match(/^jsonfilter is not installed or unavailable; wanted asset=([\s\S]+) repository=([\s\S]+) release=([\s\S]+)$/);
	if (match)
		return _('jsonfilter is not installed or unavailable; wanted asset=%s repository=%s release=%s.').format(match[1], match[2], match[3]);

	match = value.match(/^wanted asset=([\s\S]+) repository=([\s\S]+) release=([\s\S]+)$/);
	if (match)
		return _('Required asset %s from repository %s, release %s.').format(match[1], match[2], match[3]);

	match = value.match(/^asset=([\s\S]*?) digest=([\s\S]*)$/);
	if (match)
		return _('Asset: %s; digest: %s').format(match[1], translateDetailValuePart(match[2]));

	match = value.match(/^asset=([\s\S]*?) url=([\s\S]*?); ([\s\S]+)$/);
	if (match)
		return _('Asset: %s; URL: %s; %s').format(match[1], match[2], translateDetailValue(match[3]));

	match = value.match(/^asset=([\s\S]*?) expected=([\s\S]*?) actual=([\s\S]*)$/);
	if (match)
		return _('Asset: %s; expected: %s; actual: %s').format(match[1], match[2], translateDetailValuePart(match[3]));

	match = value.match(/^asset=([\s\S]*?) bundle=([\s\S]*)$/);
	if (match)
		return _('Asset: %s; bundle: %s').format(match[1], translateDetailValuePart(match[2]));

	match = value.match(/^asset=([\s\S]+)$/);
	if (match)
		return _('Asset: %s').format(match[1]);

	match = value.match(/^bundle=([\s\S]*?); upload an official full or standard \.tar\.gz archive to install the WebUI$/);
	if (match)
		return _('Bundle: %s. Upload an official full or standard .tar.gz archive to install the WebUI.').format(translateDetailValuePart(match[1]));

	match = value.match(/^config=([\s\S]*?) working_dir=([\s\S]*)$/);
	if (match)
		return _('Config: %s; working directory: %s').format(match[1], match[2]);

	match = value.match(/^config=([\s\S]+)$/);
	if (match)
		return _('Config: %s').format(match[1]);

	match = value.match(/^source=([\s\S]+)$/);
	if (match)
		return _('Source: %s').format(match[1]);

	match = value.match(/^archive=([\s\S]+)$/);
	if (match)
		return _('Archive: %s').format(match[1]);

	match = value.match(/^path=([\s\S]+)$/);
	if (match)
		return _('Path: %s').format(match[1]);

	match = value.match(/^working_dir=([\s\S]+)$/);
	if (match)
		return _('Working directory: %s').format(match[1]);

	return value;
}

function translate(text) {
	build();

	if (!text)
		return '';

	var value = String(text);
	var match;

	if (messages[value])
		return messages[value];

	match = value.match(/^init script not found: (.+)$/);
	if (match)
		return _('Init script not found: %s').format(match[1]);

	match = value.match(/^configuration saved, but service restart failed: (.+)$/);
	if (match)
		return _('Configuration saved, but service restart failed: %s').format(match[1]);

	match = value.match(/^log path saved, but service restart failed: (.+)$/);
	if (match)
		return _('Log path saved, but service restart failed: %s').format(match[1]);

	return value;
}

function message(result) {
	return translate(result && (result.message || result.error));
}

function detail(text) {
	build();

	if (!text)
		return '';

	var value = String(text);
	var composite = value.match(/^api=([\s\S]*?); web=([\s\S]*?); repository=([\s\S]*?) release=([\s\S]*)$/);

	if (composite)
		return _('API: %s; website: %s; repository: %s release: %s').format(
			translateDetailValue(composite[1]),
			translateDetailValue(composite[2]),
			composite[3],
			composite[4]);

	return translateDetailValue(value);
}

return baseclass.extend({
	translate: translate,
	message: message,
	detail: detail
});
