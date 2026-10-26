# English message catalog for the trusted command and the CGI wrapper.
#
# Keys are T_<name>.  t() in lib.sh prints T_<name> with printf, so a message
# may contain %s placeholders.  Keep the key set identical in every catalog:
# a missing key falls back to the key name, which shows up as "T_foo" on the
# console.

T_usage="Usage: trusted <command> [argument]

  status                 Show the switch states and the active whitelist
  add <address>...       Add IPv4 addresses or subnets. The change applies immediately
  del <address>...       Delete IPv4 addresses or subnets. The change applies immediately
  deny on|off            Enable or disable \"Block devices that are not in the whitelist\"

Address format: a.b.c.d or a.b.c.d/nn. Example: 10.3.2.5 or 10.3.2.0/24."

T_err_no_lib="Cannot find %s. Address validation is not available."
T_err_bad_lib="%s is damaged. Address validation is not available."

T_err_add_noarg="The add command needs one address. Example: trusted add 10.3.2.5"
T_err_del_noarg="The del command needs one address. Example: trusted del 10.3.2.5"
T_err_deny_arg="The deny command needs on or off."
T_err_unknown="Unknown command: %s"

T_err_reject="Rejected '%s'. Use an IPv4 address or a subnet, for example 10.3.2.5 or 10.3.2.0/24."
T_err_write="Cannot write '%s' to the configuration."
T_err_del_fail="Cannot delete '%s'."
T_err_commit="The uci commit command failed."
T_err_set="Cannot write the setting."
T_err_no_active="The configuration is saved, but the plugin did not build an active whitelist. Run logread -e trusted."

T_info_exists="'%s' is already in the whitelist."
T_info_notin="'%s' is not in the whitelist."

T_ok_added="Whitelist updated. Entries added: %s"
T_ok_deleted="Whitelist updated. Entries deleted: %s"
T_ok_active="Active whitelist: %s"
T_ok_deny="deny_others=%s"
T_note_disabled="Note: the plugin is disabled. The whitelist has no effect."

T_warn_deny_short="WARNING: this option blocks other devices, but the active whitelist contains 127.0.0.1 only."
T_warn_no_page="No device on the LAN can open the web page. Run trusted add <address> to correct this."
T_warn_empty="WARNING: the whitelist is empty and this option is on. The web page will be inaccessible."
T_hint_undo="Run trusted deny off to disable the option. Or run trusted add <address> to add your address again."
T_warn_lose="WARNING: the whitelist contains 127.0.0.1 only. All devices on the LAN will lose access to the web page."
T_hint_add="Run trusted add <address> to add your own address."

T_lbl_plugin="plugin"
T_lbl_term="web terminal"
T_lbl_ssh="ssh"
T_lbl_deny="block others"
T_lbl_cfg="in config"
T_lbl_active="active"
T_empty="<empty>"

T_http_403="Trusted blocked this request. This device is not in the whitelist."
T_http_500="Error: the LuCI CGI file is missing. Install the package again."
