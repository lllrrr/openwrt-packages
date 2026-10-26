// SPDX-License-Identifier: Apache-2.0
import { access, open, popen, readfile, rename, stat, unlink } from 'fs';
import { cursor } from 'uci';
import { entityencode } from 'html';

function shellquote(value) {
	return "'" + replace(value, "'", "'\\''") + "'";
}

function fail(http, code, message, translated) {
	// Keep the HTTP reason phrase ASCII; localize only the response body.
	http.status(code, message);
	http.prepare_content('text/plain; charset=UTF-8');
	http.write(translated ?? message);
}

function execute(command) {
	let pipe = popen(command + ' 2>/dev/null', 'r');
	if (!pipe)
		return null;
	let output = pipe.read('all');
	return pipe.close() == 0 ? output : null;
}

function certificate(path) {
	if (access(path))
		return true;

	// Never generate a shared private key while building the firmware image.
	// Serialize the first-use generation and publish the PEM atomically.
	if (path != '/etc/shellinabox/certificate.pem')
		return false;
	let lock = open('/var/lock/luci-shellinabox-cert.lock', 'w', 0600);
	if (!lock || !lock.lock('x')) {
		lock?.close();
		return false;
	}
	let ok = access(path);
	let key = path + '.key.tmp', cert = path + '.crt.tmp', pem = path + '.tmp';
	try {
		if (!ok) {
			let version = execute('/usr/bin/openssl version');
			let traditional = match(version ?? '', /^OpenSSL 3\./) ? ' -traditional' : '';
			let generated = execute('umask 077; /usr/bin/openssl genrsa' + traditional +
				' -out ' + shellquote(key) + ' 2048 && /usr/bin/openssl req -new -x509 -sha256' +
				' -key ' + shellquote(key) + ' -out ' + shellquote(cert) +
				' -days 3650 -subj /CN=ShellInABox');
			if (generated != null) {
				let contents = readfile(key) + readfile(cert);
				let file = open(pem, 'w', 0600);
				ok = file && file.write(contents) == length(contents);
				if (file && !file.close())
					ok = false;
				ok = ok && rename(pem, path);
			}
		}
	}
	catch (e) {
		ok = false;
	}
	unlink(key);
	unlink(cert);
	unlink(pem);
	lock.close();
	return ok;
}

// LuCI injects runtime.env as the function scope, not as an argument.
function launch() {
	http.header('Cache-Control', 'no-store');
	http.header('Referrer-Policy', 'no-referrer');
	http.header('X-Frame-Options', 'SAMEORIGIN');

	// The dispatcher checks both the LuCI session and the launch ACL.
	if (!ctx.authsession || !ctx.authtoken) {
		fail(http, 403, 'Forbidden', _('Forbidden'));
		return;
	}

	if (http.getenv('REQUEST_METHOD') == 'GET') {
		// Keep the ttyd-style iframe, but start processes only through a
		// CSRF-protected POST. Reconnecting reloads this same launch page.
		http.prepare_content('text/html');
		http.write('<!DOCTYPE html><html><body><form method="post">' +
			'<input type="hidden" name="launch" value="1">' +
			'<input type="hidden" name="token" value="' + entityencode(ctx.authtoken) + '">' +
			'<noscript><button type="submit">' + entityencode(_('Start terminal')) + '</button></noscript></form>' +
			'<script>document.forms[0].submit();</script></body></html>');
		return;
	}

	if (http.getenv('REQUEST_METHOD') != 'POST' || http.formvalue('launch') != '1' ||
	    http.formvalue('token') != ctx.authtoken) {
		fail(http, 403, 'Forbidden', _('Forbidden'));
		return;
	}

	let uci = cursor();
	if (uci.get('shellinabox', 'main', 'enable') != '1') {
		fail(http, 403, 'ShellInABox is disabled', _('ShellInABox is disabled'));
		return;
	}

	let min = uci.get('shellinabox', 'main', 'port_min') ?? '4200';
	let max = uci.get('shellinabox', 'main', 'port_max') ?? '4210';
	let uid = uci.get('shellinabox', 'main', 'uid') ?? '0';
	let gid = uci.get('shellinabox', 'main', 'gid') ?? '0';
	let cwd = uci.get('shellinabox', 'main', 'cwd') ?? '/root';
	let command = uci.get('shellinabox', 'main', 'command') ?? '/bin/login';
	let ssl = uci.get('shellinabox', 'main', 'ssl') == '1';
	let cert = uci.get('shellinabox', 'main', 'ssl_cert') ?? '/etc/shellinabox/certificate.pem';
	let css = uci.get('shellinabox', 'main', 'css') ?? '/etc/shellinabox/white-on-black.css';

	if (!match(min, /^[0-9]{1,5}$/) || !match(max, /^[0-9]{1,5}$/) ||
	    int(min) < 1024 || int(max) > 65535 || int(max) < int(min) ||
	    !match(uid, /^[0-9]{1,9}$/) || !match(gid, /^[0-9]{1,9}$/) ||
	    !match(cwd, /^\/[^:\r\n]*$/) || !length(command) || match(command, /[\r\n]/) ||
	    !match(cert, /^\/[^\r\n]*$/) ||
	    (css != 'default' && !match(css, /^\/[^\r\n]+\.css$/))) {
		fail(http, 400, 'Invalid ShellInABox configuration', _('Invalid ShellInABox configuration'));
		return;
	}

	if (css != 'default' && (stat(css)?.type != 'file' || !access(css, 'r'))) {
		fail(http, 400, 'Unable to read the CSS style file', _('Unable to read the CSS style file'));
		return;
	}

	if (!ssl && http.getenv('HTTPS') == 'on') {
		fail(http, 400, 'Enable ShellInABox SSL before using the terminal through HTTPS LuCI',
			_('Enable ShellInABox SSL before using the terminal through HTTPS LuCI'));
		return;
	}

	if (ssl && !certificate(cert)) {
		fail(http, 500, 'Unable to prepare ShellInABox certificate', _('Unable to prepare ShellInABox certificate'));
		return;
	}

	// Only trusted UCI settings supply command arguments. No arbitrary
	// commands, identities, ports or certificate paths come from the URL.
	let args = [ '/usr/sbin/shellinaboxd', '--cgi=' + int(min) + '-' + int(max),
		'--disable-ssl-menu', '-s', '/:' + uid + ':' + gid + ':' + cwd + ':' + command ];
	if (css != 'default')
		push(args, '--css=' + css);
	if (uci.get('shellinabox', 'main', 'no_beep') == '1')
		push(args, '--no-beep');
	if (ssl)
		push(args, '--cert-fd=3');
	else
		push(args, '--disable-ssl');

	let cmdline = join(' ', map(args, shellquote));
	if (ssl)
		cmdline += ' 3<' + shellquote(cert);
	let output = execute(cmdline);
	// CGI writes headers and its frame page, then closes stdout while the
	// per-session daemon continues independently until its idle timeout.
	let parts = split(output ?? '', '\r\n\r\n', 2);
	if (length(parts) != 2 || !match(parts[0], /X-ShellInABox-Port: [0-9]+/)) {
		fail(http, 503, 'Unable to start ShellInABox; check the port range and certificate',
			_('Unable to start ShellInABox; check the port range and certificate'));
		return;
	}

	http.prepare_content('text/html');
	// Match the backend transport, even if the LuCI page used HTTP.
	let page = replace(parts[1], 'document.location.protocol', ssl ? "'https:'" : "'http:'");
	// Fill the ttyd-sized outer iframe without the CGI frame's default borders.
	page = replace(page, '<frameset cols="*">',
		'<frameset cols="*" border="0" frameborder="0" framespacing="0">');
	page = replace(page, '<frame src="',
		'<frame frameborder="0" marginwidth="0" marginheight="0" src="');
	http.write(page);
}

return { launch };
