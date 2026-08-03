"use strict";
"require baseclass";
"require rpc";

const CACHE_KEY = "aurora.hub.list";
const CACHE_TTL = 300000;

return baseclass.extend({
  listCache: {
    get() {
      try {
        const cached = localStorage.getItem(CACHE_KEY);
        if (!cached) return null;
        const { timestamp, value } = JSON.parse(cached);
        if (Date.now() - timestamp > CACHE_TTL) {
          this.clear();
          return null;
        }
        return value;
      } catch (e) {
        return null;
      }
    },

    getStale() {
      try {
        const cached = localStorage.getItem(CACHE_KEY);
        if (!cached) return null;
        return JSON.parse(cached).value ?? null;
      } catch (e) {
        return null;
      }
    },

    set(value) {
      try {
        localStorage.setItem(
          CACHE_KEY,
          JSON.stringify({ timestamp: Date.now(), value }),
        );
      } catch (e) {
        console.error("Failed to cache hub list data:", e);
      }
    },

    clear() {
      localStorage.removeItem(CACHE_KEY);
    },
  },

  callHubList: rpc.declare({
    object: "luci.aurora",
    method: "hub_list",
    params: ["sort", "page"],
  }),

  callHubGet: rpc.declare({
    object: "luci.aurora",
    method: "hub_get",
    params: ["id"],
  }),

  callHubApply: rpc.declare({
    object: "luci.aurora",
    method: "hub_apply",
    params: ["id"],
  }),

  callGetHubStatus: rpc.declare({
    object: "luci.aurora",
    method: "get_hub_status",
    params: ["job_id"],
  }),

  callHubRestore: rpc.declare({
    object: "luci.aurora",
    method: "hub_restore_backup",
  }),

  callHubShare: rpc.declare({
    object: "luci.aurora",
    method: "hub_share",
    params: ["name", "description", "author"],
  }),

  callHubMyShares: rpc.declare({
    object: "luci.aurora",
    method: "hub_my_shares",
  }),

  callHubUpdate: rpc.declare({
    object: "luci.aurora",
    method: "hub_update",
    params: ["id", "name", "author", "description"],
  }),

  callHubDelete: rpc.declare({
    object: "luci.aurora",
    method: "hub_delete",
    params: ["id"],
  }),
});
