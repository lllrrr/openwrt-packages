"use strict";
"require view";
"require rpc";
"require ui";
"require fs";
"require uci";

var callReboot = rpc.declare({
  object: "system",
  method: "reboot",
  expect: { result: 0 },
});

return view.extend({
  load: function () {
    return uci.changes();
  },

  render: function (changes) {
    var body = [
      E("h2", {}, _("PowerManager")),
      E("p", {}, [
        _("LuCI plugin that makes OpenWrt poweroff and reboot easy."),
        " ",
        E(
          "a",
          {
            href: "https://867678.xyz/project/luci-app-pm/",
            target: "_blank",
            rel: "noreferrer noopener",
            style: "color: #007bff; text-decoration: none; margin-left: 5px;",
          },
          _("Project Address"),
        ),
      ]),

      E("hr"),
    ];

    for (var config in changes || {}) {
      body.push(
        E(
          "p",
          { class: "alert-message warning" },
          _("Warning: There are unsaved changes that will get lost on reboot!"),
        ),
      );
      break;
    }

    body.push(
      E(
        "div",
        {
          style:
            "display: flex; flex-direction: column; align-items: flex-start; gap: 8px;",
        },
        [
          E(
            "button",
            {
              class: "cbi-button cbi-button-action important",
              style: "min-width: 80px; width: auto; padding: 5px 15px;",
              click: ui.createHandlerFn(this, "handleReboot"),
            },
            _("Reboot"),
          ),

          E(
            "button",
            {
              class: "cbi-button cbi-button-reset important",
              style: "min-width: 80px; width: auto; padding: 5px 15px;",
              click: ui.createHandlerFn(this, "handlePowerOff"),
            },
            _("PowerOff"),
          ),
        ],
      ),
    );

    return E("div", { class: "cbi-map" }, body);
  },

  handleReboot: function (ev) {
    ui.showModal(_("Are you sure?"), [
      E("p", {}, _("Do you want to reboot this system?")),
      E("div", { class: "right" }, [
        E(
          "button",
          {
            class: "btn cbi-button-action important",
            click: function () {
              ui.hideModal();
              callReboot()
                .then(function (res) {
                  ui.showModal(_("Rebooting..."), [
                    E(
                      "p",
                      { class: "spinning" },
                      _("Waiting for device reconnect..."),
                    ),
                  ]);
                  window.setTimeout(function () {
                    ui.showModal(_("Rebooting..."), [
                      E(
                        "p",
                        { class: "spinning alert-message warning" },
                        _("Device unreachable! Still waiting for device..."),
                      ),
                    ]);
                  }, 150000);
                  ui.awaitReconnect();
                })
                .catch(function (e) {
                  ui.addNotification(
                    null,
                    E(
                      "p",
                      _("Reboot failed") + (e.message ? ": " + e.message : ""),
                    ),
                  );
                });
            },
          },
          _("Reboot"),
        ),
        " ",
        E(
          "button",
          {
            class: "btn",
            click: ui.hideModal,
          },
          _("Cancel"),
        ),
      ]),
    ]);
  },

  handlePowerOff: function (ev) {
    ui.showModal(_("Are you sure?"), [
      E(
        "p",
        {},
        _(
          "Do you really want to shutdown the system? Problems may occur on unsupported devices.",
        ),
      ),
      E("div", { class: "right" }, [
        E(
          "button",
          {
            class: "btn cbi-button-reset important",
            click: function () {
              ui.hideModal();
              ui.showModal(_("Shutting down..."), [
                E(
                  "p",
                  { class: "spinning" },
                  _("The device is powering off..."),
                ),
              ]);
              window.setTimeout(function () {
                ui.showModal(_("Shutting down..."), [
                  E(
                    "p",
                    { class: "spinning alert-message warning" },
                    _(
                      "The device seems to have not powered off. It may not support poweroff.",
                    ),
                  ),
                ]);
              }, 60000);
              fs.exec("/sbin/poweroff").catch(function (e) {
                ui.hideModal();
                ui.addNotification(
                  null,
                  E(
                    "p",
                    _("PowerOff failed") + (e.message ? ": " + e.message : ""),
                  ),
                );
              });
            },
          },
          _("PowerOff"),
        ),
        " ",
        E(
          "button",
          {
            class: "btn",
            click: ui.hideModal,
          },
          _("Cancel"),
        ),
      ]),
    ]);
  },

  handleSaveApply: null,
  handleSave: null,
  handleReset: null,
});
