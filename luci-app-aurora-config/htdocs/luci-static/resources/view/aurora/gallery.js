"use strict";
"require view";
"require ui";
"require uci";
"require utils.hub-api as hubApi";
"require utils.asset-upload as assetUpload";

// Theme Store browse + apply page, plus the share panel and "my shares"
// management (Task 8). Every piece of hub-sourced text (name, author,
// palette hex values, layout/typography strings, toolbar urls) is
// untrusted: it is rendered only via E()'s textContent-safe children,
// document.createTextNode, or explicit style property assignment -- never
// through innerHTML.
//
// UX zero-burden rule: all user-facing copy describes results only
// ("Applied", "Restore previous configuration", "This configuration can't
// be applied", "Published", "Updated", "Deleted"). Mechanism words (job,
// schema, token, pending, bad_payload) never surface -- see
// applyErrorMessage/restoreErrorMessage/shareErrorMessage/
// updateErrorMessage/deleteErrorMessage below, which map every backend
// error code to friendly copy instead of echoing it.

const HUB_NICK_KEY = "aurora.hub.nick";

const SWATCH_KEYS = ["bg", "surface", "text", "brand"];

const ASSET_KIND_LABELS = {
  logo_svg: _("Logo"),
  favicon_png: _("Favicon (PNG)"),
  favicon_ico: _("Favicon (ICO)"),
  pwa_icon_192: _("App Icon (192px)"),
  pwa_icon_512: _("App Icon (512px)"),
  login_bg: _("Login Background"),
  font_sans: _("Custom Sans Font"),
  font_mono: _("Custom Mono Font"),
};

const NAV_TYPE_LABELS = {
  "mega-menu": _("Mega Menu"),
  dropdown: _("Dropdown"),
  sidebar: _("Sidebar"),
};

// The list payload only carries a reduced 8-swatch palette; the detail
// payload carries the full 62-key colors dict (light_bg, dark_bg, ...).
// Support both shapes so the same helper serves cards and the modal.
const paletteOf = (item) => {
  if (item && item.palette) return item.palette;
  const colors = (item && item.payload && item.payload.colors) || {};
  const pick = (mode) =>
    SWATCH_KEYS.reduce((acc, key) => {
      acc[key] = colors[mode + "_" + key] || "";
      return acc;
    }, {});
  return { light: pick("light"), dark: pick("dark") };
};

const buildSwatchRow = (mode, palette) =>
  E(
    "div",
    { class: "aurora-hub-swatch-row", style: "display:flex;gap:4px;" },
    SWATCH_KEYS.map((key) => {
      const swatch = E("span", {
        class: "aurora-hub-swatch",
        title: mode + " " + key,
        style:
          "display:inline-block;width:1.3rem;height:1.3rem;" +
          "border-radius:0.3rem;border:1px solid var(--hairline);",
      });
      swatch.style.backgroundColor = palette[key] || "transparent";
      return swatch;
    }),
  );

const buildPaletteBlock = (item) => {
  const palette = paletteOf(item);
  return E("div", { style: "display:flex;flex-direction:column;gap:4px;margin:0.6em 0;" }, [
    buildSwatchRow("light", palette.light || {}),
    buildSwatchRow("dark", palette.dark || {}),
  ]);
};

const formatDownloads = (n) => {
  const count = Number(n) || 0;
  return count === 1
    ? _("1 download")
    : _("%d downloads").format(count);
};

const buildCard = (item, onOpen) => {
  const card = E(
    "div",
    {
      class: "aurora-hub-card",
      click: () => onOpen(item.id),
      style:
        "cursor:pointer;border:1px solid var(--hairline);border-radius:0.6em;" +
        "padding:1em;background:var(--surface);transition:box-shadow 0.15s;",
    },
    [
      buildPaletteBlock(item),
      E("div", { style: "margin-top:0.4em;" }, [
        E(
          "strong",
          { style: "display:block;word-break:break-word;" },
          [document.createTextNode(item.name || _("Untitled theme"))],
        ),
        E(
          "div",
          {
            style:
              "color:var(--text-muted);font-size:0.85em;margin-top:0.2em;" +
              "display:flex;justify-content:space-between;gap:0.5em;",
          },
          [
            E("span", {}, [
              document.createTextNode(item.author || _("Anonymous")),
            ]),
            E("span", {}, [
              document.createTextNode(formatDownloads(item.downloads)),
            ]),
          ],
        ),
      ]),
    ],
  );
  return card;
};

const buildDetailRow = (label, value) =>
  E("div", { class: "cbi-value", style: "margin:0;" }, [
    E("label", { class: "cbi-value-title" }, label),
    E("div", { class: "cbi-value-field" }, [document.createTextNode(value || "-")]),
  ]);

const buildAssetList = (item) => {
  const assets = (item && item.assets) || (item && item.payload && item.payload.assets) || [];
  if (!assets.length)
    return E("p", { style: "color:var(--text-muted);" }, _("No custom assets included."));
  return E(
    "ul",
    { style: "margin:0.25em 0 0;padding-left:1.2em;" },
    assets.map((asset) =>
      E("li", {}, [
        document.createTextNode(
          ASSET_KIND_LABELS[asset.kind] || asset.kind || _("Unknown asset"),
        ),
      ]),
    ),
  );
};

const buildDetailBody = (item) => {
  const payload = item.payload || {};
  const layout = payload.layout || {};
  const typography = payload.typography || {};

  return E("div", {}, [
    E("h3", { style: "margin:0 0 0.4em;word-break:break-word;" }, [
      document.createTextNode(item.name || _("Untitled theme")),
    ]),
    buildPaletteBlock(item),
    E("h4", { style: "margin:1em 0 0.4em;" }, _("Layout")),
    buildDetailRow(_("Navigation"), NAV_TYPE_LABELS[layout.nav_type] || layout.nav_type),
    buildDetailRow(_("Spacing"), layout.struct_spacing),
    buildDetailRow(_("Corner Radius"), layout.struct_radius_base),
    buildDetailRow(_("Content Width"), layout.struct_content_width_centered),
    buildDetailRow(
      _("Toolbar"),
      layout.toolbar_enabled === "1" ? _("Enabled") : _("Disabled"),
    ),
    E("h4", { style: "margin:1em 0 0.4em;" }, _("Typography")),
    buildDetailRow(_("Sans Font"), typography.font_sans),
    buildDetailRow(_("Mono Font"), typography.font_mono),
    E("h4", { style: "margin:1em 0 0.4em;" }, _("Included Assets")),
    buildAssetList(item),
  ]);
};

// Toolbar entries that point off-box are the one part of a config that can
// surprise a user after the fact (an admin panel bookmark, a vendor link).
// Anything else in the payload is inert data, so only these need a plaintext
// callout before applying.
const externalToolbarUrls = (payload) => {
  const toolbar = (payload && Array.isArray(payload.toolbar)) ? payload.toolbar : [];
  return toolbar
    .filter(
      (entry) =>
        entry &&
        typeof entry.url === "string" &&
        (entry.url.startsWith("http://") || entry.url.startsWith("https://")),
    )
    .map((entry) => entry.url);
};

// Every code the backend can hand back for hub_apply / get_hub_status,
// mapped to result-only copy. Anything not listed here (including codes
// added to the backend later) falls back to the generic "can't be applied"
// message rather than ever leaking a raw code like "bad_payload" or "job".
const APPLY_ERROR_COPY = {
  invalid_id: _("This theme is no longer available."),
  hub_unreachable: _("Couldn't reach the theme store. Please try again."),
  bad_payload: _("This configuration can't be applied."),
  job_not_found: _("Applying timed out. Please try again."),
};

const applyErrorMessage = (code) =>
  APPLY_ERROR_COPY[code] || _("This configuration can't be applied.");

const RESTORE_ERROR_COPY = {
  no_backup: _("There's nothing to restore yet."),
};

const restoreErrorMessage = (code) =>
  RESTORE_ERROR_COPY[code] ||
  _("Unable to restore the previous configuration.");

// hub_share / hub_update return these codes; unlisted codes (including any
// added to the backend later) fall back to a single generic line rather
// than leaking mechanism words like "bad_payload" or "hub_bad_response".
const SHARE_ERROR_COPY = {
  invalid_name: _("Please enter a name."),
  invalid_author: _("That nickname is too long."),
  invalid_description: _("That description is too long."),
  config_unavailable: _("Your current configuration can't be shared right now."),
  payload_build_failed: _("Your current configuration can't be shared right now."),
  hub_unreachable: _("Couldn't reach the theme store. Please try again."),
};

const shareErrorMessage = (code) =>
  SHARE_ERROR_COPY[code] || _("Unable to share this configuration right now.");

const UPDATE_ERROR_COPY = {
  invalid_id: _("This share is no longer available."),
  config_unavailable: _("Your current configuration can't be shared right now."),
  payload_build_failed: _("Your current configuration can't be shared right now."),
  hub_unreachable: _("Couldn't reach the theme store. Please try again."),
};

const updateErrorMessage = (code) =>
  UPDATE_ERROR_COPY[code] || _("Unable to update this share right now.");

const DELETE_ERROR_COPY = {
  invalid_id: _("This share is no longer available."),
  hub_unreachable: _("Couldn't reach the theme store. Please try again."),
};

const deleteErrorMessage = (code) =>
  DELETE_ERROR_COPY[code] || _("Unable to delete this share right now.");

const buildConfirmActions = (onConfirm, confirmLabel) =>
  E("div", { class: "right", style: "margin-top:1em;" }, [
    E("button", { class: "btn", click: ui.hideModal }, _("Cancel")),
    " ",
    E(
      "button",
      { class: "btn cbi-button-action important", click: onConfirm },
      confirmLabel,
    ),
  ]);

const buildSimpleApplyConfirm = (onConfirm) => [
  E(
    "p",
    {},
    _(
      "Apply this configuration now? Your current settings are backed up first.",
    ),
  ),
  buildConfirmActions(onConfirm, _("Apply")),
];

const buildExternalUrlConfirm = (urls, onConfirm) => [
  E("p", {}, _("This configuration links to these external sites:")),
  E(
    "ul",
    { style: "margin:0.25em 0 0.75em;padding-left:1.2em;word-break:break-all;" },
    urls.map((url) => E("li", {}, [document.createTextNode(url)])),
  ),
  E(
    "p",
    {},
    _("Apply it anyway? Your current settings are backed up first."),
  ),
  buildConfirmActions(onConfirm, _("Apply")),
];

return view.extend({
  handleSave: null,
  handleSaveApply: null,
  handleReset: null,

  load() {
    return Promise.all([
      L.resolveDefault(hubApi.callHubList("hot", 1), null),
      L.resolveDefault(hubApi.callHubMyShares(), null),
      uci.load("aurora"),
    ]).then(([listRes, mySharesRes]) => ({
      listRes,
      mySharesRes,
      hubApplied: uci.get("aurora", "theme", "hub_applied") || "",
    }));
  },

  render(loadData) {
    let currentSort = "hot";
    let appliedName = loadData.hubApplied || "";

    const bannerEl = E("div", { id: "aurora-hub-banner" });

    const confirmRestore = () => {
      ui.showModal(_("Restore Previous Configuration"), [
        E(
          "p",
          {},
          _(
            "This replaces your current settings with the ones from just before the last applied configuration.",
          ),
        ),
        buildConfirmActions(() => {
          ui.showModal(_("Restoring"), [
            E("p", { class: "spinning" }, _("Restoring…")),
          ]);
          L.resolveDefault(hubApi.callHubRestore(), null).then((res) => {
            if (res && res.result === 0) {
              window.location.reload();
              return;
            }
            ui.hideModal();
            ui.addNotification(
              null,
              E("p", {}, restoreErrorMessage(res && res.error)),
              "warning",
            );
          });
        }, _("Restore")),
      ]);
    };

    const renderBanner = () => {
      while (bannerEl.firstChild) bannerEl.removeChild(bannerEl.firstChild);
      if (!appliedName) {
        bannerEl.style.display = "none";
        return;
      }
      bannerEl.style.cssText =
        "display:flex;align-items:center;justify-content:space-between;" +
        "gap:1em;flex-wrap:wrap;padding:0.6em 1em;margin-top:1em;" +
        "border-radius:0.4em;background:var(--surface);" +
        "border:1px solid var(--hairline);";
      bannerEl.appendChild(
        E("span", {}, [
          document.createTextNode(_("Applied ")),
          E("strong", {}, [document.createTextNode(appliedName)]),
        ]),
      );
      bannerEl.appendChild(
        E(
          "button",
          { type: "button", class: "cbi-button", click: confirmRestore },
          _("Restore previous configuration"),
        ),
      );
    };

    // "My Shares" section: the user's own configurations already published
    // to the store. Only ever shown when there is at least one -- someone
    // who has never shared anything should see nothing here, not an empty
    // table (UX zero-burden rule).
    const mySharesEl = E("div", { id: "aurora-hub-my-shares" });

    const refreshMyShares = () =>
      L.resolveDefault(hubApi.callHubMyShares(), null).then((res) => {
        renderMyShares(res && res.result === 0 ? res.items : []);
      });

    const confirmUpdateShare = (item) => {
      ui.showModal(_("Update Share"), [
        E(
          "p",
          {},
          _(
            "Replace the shared configuration with your current settings?",
          ),
        ),
        buildConfirmActions(() => {
          ui.showModal(_("Updating"), [
            E("p", { class: "spinning" }, _("Updating…")),
          ]);
          L.resolveDefault(
            hubApi.callHubUpdate(
              item.id,
              item.name,
              item.author || "",
              item.description || "",
            ),
            null,
          ).then((res) => {
            ui.hideModal();
            if (res && res.result === 0) {
              ui.addNotification(null, E("p", {}, _("Updated.")), "info");
              refreshMyShares();
            } else {
              ui.addNotification(
                null,
                E("p", {}, updateErrorMessage(res && res.error)),
                "warning",
              );
            }
          });
        }, _("Update")),
      ]);
    };

    const confirmDeleteShare = (item) => {
      // Static message, deliberately not interpolating item.name: asset-upload's
      // confirmDelete renders opts.message as a bare E() child, which LuCI can
      // route through innerHTML, and the hub config name is attacker-controlled
      // free text (the hub only strips control characters).
      assetUpload
        .confirmDelete({
          title: _("Delete Share"),
          message: _("Delete this shared configuration from the theme store?"),
        })
        .then((confirmed) => {
          if (!confirmed) return;
          return L.resolveDefault(hubApi.callHubDelete(item.id), null).then(
            (res) => {
              if (res && res.result === 0) {
                ui.addNotification(null, E("p", {}, _("Deleted.")), "info");
                refreshMyShares();
              } else {
                ui.addNotification(
                  null,
                  E("p", {}, deleteErrorMessage(res && res.error)),
                  "warning",
                );
              }
            },
          );
        });
    };

    const buildMyShareRow = (item) => {
      const updateBtn = E(
        "button",
        {
          type: "button",
          class: "cbi-button",
          click: () => confirmUpdateShare(item),
        },
        _("Update with current configuration"),
      );
      const deleteBtn = E(
        "button",
        {
          type: "button",
          class: "cbi-button cbi-button-remove",
          click: () => confirmDeleteShare(item),
        },
        _("Delete"),
      );

      return E("tr", { class: "tr" }, [
        E("td", { class: "td", style: "word-break:break-word;" }, [
          document.createTextNode(item.name || _("Untitled theme")),
        ]),
        E(
          "td",
          { class: "td", style: "color:var(--text-muted);" },
          [document.createTextNode(formatDownloads(item.downloads))],
        ),
        E("td", { class: "td center", style: "white-space:nowrap;" }, [
          updateBtn,
          " ",
          deleteBtn,
        ]),
      ]);
    };

    const renderMyShares = (items) => {
      while (mySharesEl.firstChild) mySharesEl.removeChild(mySharesEl.firstChild);
      if (!items || !items.length) {
        mySharesEl.style.display = "none";
        return;
      }
      mySharesEl.style.cssText = "display:block;margin-top:1.5em;";
      mySharesEl.appendChild(E("h3", {}, _("My Shares")));
      mySharesEl.appendChild(
        E("table", { class: "table" }, [
          E("tr", { class: "tr table-titles" }, [
            E("th", { class: "th" }, _("Name")),
            E("th", { class: "th" }, _("Downloads")),
            E("th", { class: "th center" }, ""),
          ]),
          ...items.map((item) => buildMyShareRow(item)),
        ]),
      );
    };

    const openShareModal = () => {
      const nameInput = E("input", {
        type: "text",
        class: "cbi-input-text",
        maxlength: 60,
      });
      const descInput = E("textarea", {
        class: "cbi-input-textarea",
        rows: 3,
        maxlength: 500,
      });
      const authorInput = E("input", {
        type: "text",
        class: "cbi-input-text",
        maxlength: 40,
        value: localStorage.getItem(HUB_NICK_KEY) || "",
      });

      const errEl = E("p", {
        style: "color:var(--danger);font-weight:600;display:none;margin:0 0 0.6em;",
      });

      const showError = (message) => {
        errEl.textContent = message;
        errEl.style.display = "block";
      };

      const submitBtn = E(
        "button",
        { type: "button", class: "btn cbi-button-action important" },
        _("Publish"),
      );

      const doSubmit = () => {
        const name = nameInput.value.trim();
        if (!name) {
          showError(_("Please enter a name."));
          return;
        }
        errEl.style.display = "none";
        submitBtn.disabled = true;
        const author = authorInput.value.trim();
        const description = descInput.value.trim();
        L.resolveDefault(hubApi.callHubShare(name, description, author), null)
          .then((res) => {
            submitBtn.disabled = false;
            if (res && res.result === 0) {
              if (author) localStorage.setItem(HUB_NICK_KEY, author);
              ui.hideModal();
              ui.addNotification(null, E("p", {}, _("Published.")), "info");
              refreshMyShares();
            } else {
              showError(shareErrorMessage(res && res.error));
            }
          });
      };

      submitBtn.addEventListener("click", doSubmit);

      ui.showModal(_("Share My Configuration"), [
        E("div", { class: "cbi-value" }, [
          E("label", { class: "cbi-value-title" }, _("Name")),
          E("div", { class: "cbi-value-field" }, [nameInput]),
        ]),
        E("div", { class: "cbi-value" }, [
          E("label", { class: "cbi-value-title" }, _("Description")),
          E("div", { class: "cbi-value-field" }, [descInput]),
        ]),
        E("div", { class: "cbi-value" }, [
          E("label", { class: "cbi-value-title" }, _("Nickname")),
          E("div", { class: "cbi-value-field" }, [authorInput]),
        ]),
        errEl,
        E("div", { class: "right", style: "margin-top:1em;" }, [
          E("button", { class: "btn", click: ui.hideModal }, _("Cancel")),
          " ",
          submitBtn,
        ]),
      ]);
    };

    const pollApplyStatus = (jobId, remaining, name) => {
      if (remaining <= 0) {
        ui.hideModal();
        ui.addNotification(
          null,
          E("p", {}, _("Applying timed out. Please try again.")),
          "warning",
        );
        return;
      }

      window.setTimeout(() => {
        L.resolveDefault(hubApi.callGetHubStatus(jobId), {}).then((status) => {
          if (status && status.state === "done") {
            ui.hideModal();
            appliedName = name;
            renderBanner();
            ui.addNotification(null, E("p", {}, _("Applied.")), "info");
          } else if (status && status.state === "error") {
            ui.hideModal();
            ui.addNotification(
              null,
              E("p", {}, applyErrorMessage(status.error)),
              "warning",
            );
          } else {
            pollApplyStatus(jobId, remaining - 1, name);
          }
        });
      }, 1500);
    };

    const startApply = (id, name) => {
      ui.showModal(_("Applying"), [
        E("p", { class: "spinning" }, _("Applying this configuration…")),
      ]);
      L.resolveDefault(hubApi.callHubApply(id), null).then((res) => {
        if (!res || res.result !== 0 || !res.job_id) {
          ui.hideModal();
          ui.addNotification(
            null,
            E("p", {}, applyErrorMessage(res && res.error)),
            "warning",
          );
          return;
        }
        pollApplyStatus(res.job_id, 20, name);
      });
    };

    const cardsEl = E("div", {
      id: "hub-cards",
      style:
        "display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));" +
        "gap:1em;margin-top:1em;",
    });

    const statusEl = E("div", { style: "margin-top:1em;" });

    const hotBtn = E(
      "button",
      { type: "button", class: "cbi-button cbi-button-apply" },
      _("Hot"),
    );
    const newBtn = E("button", { type: "button", class: "cbi-button" }, _("New"));

    const setActiveToggle = () => {
      hotBtn.className =
        "cbi-button " + (currentSort === "hot" ? "cbi-button-apply" : "");
      newBtn.className =
        "cbi-button " + (currentSort === "new" ? "cbi-button-apply" : "");
    };

    const openDetail = (id) => {
      ui.showModal(_("Theme Details"), [
        E("p", { class: "spinning" }, _("Loading theme details…")),
      ]);
      L.resolveDefault(hubApi.callHubGet(id), null).then((res) => {
        if (!res || res.result !== 0 || !res.data) {
          ui.showModal(_("Theme Details"), [
            E(
              "p",
              {},
              _("Unable to load this theme right now. Please try again."),
            ),
            E("div", { class: "right" }, [
              E("button", { class: "btn", click: ui.hideModal }, _("Close")),
            ]),
          ]);
          return;
        }

        const item = res.data;
        const payload = item.payload || {};

        const onApplyClick = () => {
          const urls = externalToolbarUrls(payload);
          const onConfirm = () => startApply(id, item.name);
          ui.showModal(
            _("Apply Configuration"),
            urls.length
              ? buildExternalUrlConfirm(urls, onConfirm)
              : buildSimpleApplyConfirm(onConfirm),
          );
        };

        // Modal title is deliberately static (never item.name): ui.showModal
        // titles can be routed through innerHTML by LuCI, and hub config
        // names are attacker-controlled free text (the hub only strips
        // control characters). The name is instead shown inside the body
        // via buildDetailBody's createTextNode heading.
        ui.showModal(_("Theme Details"), [
          buildDetailBody(item),
          E("div", { class: "right", style: "margin-top:1em;" }, [
            E("button", { class: "btn", click: ui.hideModal }, _("Close")),
            " ",
            E(
              "button",
              {
                class: "btn cbi-button-action important",
                click: onApplyClick,
              },
              _("Apply"),
            ),
          ]),
        ]);
      });
    };

    const renderCards = (items) => {
      while (cardsEl.firstChild) cardsEl.removeChild(cardsEl.firstChild);
      items.forEach((item) => cardsEl.appendChild(buildCard(item, openDetail)));
    };

    const renderEmpty = () => {
      while (cardsEl.firstChild) cardsEl.removeChild(cardsEl.firstChild);
      statusEl.textContent = "";
      cardsEl.appendChild(
        E(
          "div",
          {
            style:
              "grid-column:1/-1;text-align:center;color:var(--text-muted);" +
              "padding:2em 1em;",
          },
          _("No configs here yet — go share the first one."),
        ),
      );
    };

    const renderError = (retry) => {
      while (cardsEl.firstChild) cardsEl.removeChild(cardsEl.firstChild);
      cardsEl.appendChild(
        E(
          "div",
          {
            style:
              "grid-column:1/-1;text-align:center;color:var(--text-muted);" +
              "padding:2em 1em;",
          },
          [
            E("p", {}, _("Unable to reach the theme store right now.")),
            E(
              "button",
              { type: "button", class: "cbi-button cbi-button-apply", click: retry },
              _("Retry"),
            ),
          ],
        ),
      );
    };

    const showStaleNotice = () => {
      statusEl.textContent = "";
      statusEl.appendChild(
        E(
          "em",
          { style: "color:var(--text-muted);font-size:0.9em;" },
          _("Showing a saved copy — reconnecting…"),
        ),
      );
    };

    const clearStatus = () => {
      statusEl.textContent = "";
    };

    // Instant paint from whatever is cached (even stale), independent of the
    // in-flight/just-finished network fetch, then reconcile below.
    const cached = hubApi.listCache.getStale();
    if (cached && Array.isArray(cached.items) && cached.items.length)
      renderCards(cached.items);

    const applyResult = (res, sort) => {
      if (res && res.result === 0 && res.data) {
        if (sort === "hot") hubApi.listCache.set(res.data);
        clearStatus();
        const items = Array.isArray(res.data.items) ? res.data.items : [];
        if (items.length) renderCards(items);
        else renderEmpty();
        return;
      }

      const stale = hubApi.listCache.getStale();
      if (stale && Array.isArray(stale.items) && stale.items.length) {
        renderCards(stale.items);
        showStaleNotice();
      } else {
        renderError(() => fetchSort(sort));
      }
    };

    const fetchSort = (sort) => {
      currentSort = sort;
      setActiveToggle();
      clearStatus();
      return L.resolveDefault(hubApi.callHubList(sort, 1), null).then((res) =>
        applyResult(res, sort),
      );
    };

    hotBtn.addEventListener("click", () => fetchSort("hot"));
    newBtn.addEventListener("click", () => fetchSort("new"));

    const shareBtn = E(
      "button",
      {
        type: "button",
        class: "cbi-button cbi-button-add",
        click: openShareModal,
      },
      _("Share My Configuration"),
    );

    setActiveToggle();
    // Reconcile the instant cache paint with the fetch load() already ran.
    applyResult(loadData.listRes, "hot");
    renderBanner();
    renderMyShares(
      loadData.mySharesRes && loadData.mySharesRes.result === 0
        ? loadData.mySharesRes.items
        : [],
    );

    return E("div", { class: "cbi-map" }, [
      E("h2", {}, _("Theme Store")),
      bannerEl,
      E(
        "div",
        { class: "cbi-map-descr" },
        _("Browse configurations shared by the community. Click one to see its details."),
      ),
      E(
        "div",
        {
          style:
            "display:flex;gap:0.5em;align-items:center;flex-wrap:wrap;",
        },
        [hotBtn, newBtn, statusEl, E("span", { style: "flex:1;" }), shareBtn],
      ),
      cardsEl,
      mySharesEl,
    ]);
  },
});
