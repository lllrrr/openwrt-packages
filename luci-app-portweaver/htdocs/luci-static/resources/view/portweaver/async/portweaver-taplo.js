"use strict";

;// CONCATENATED MODULE: ./utils/frp-editor/constants.ts
const MONACO_VERSION = "0.56.0";
const MONACO_ESM_VERSION = "0.56.1";
const MONACO_YAML_VERSION = "5.5.1";
const MONACO_CDN_TIMEOUT = 15000;
const TAPLO_LSP_URL = "https://esm.sh/@taplo/lsp@0.8.0?bundle";
const SCHEMA_COMMIT = "bf8926da67eb09d5508e3403e3d538a90e66e739";
const SCHEMA_URLS = (/* unused pure expression or super */ null && ({
    frpc: "https://raw.githubusercontent.com/LazuliKao/frp-schemas/".concat(SCHEMA_COMMIT, "/frpc-schema.json"),
    frps: "https://raw.githubusercontent.com/LazuliKao/frp-schemas/".concat(SCHEMA_COMMIT, "/frps-schema.json")
}));
const SCHEMA_CANDIDATE_URLS = (/* unused pure expression or super */ null && ({
    frpc: [
        "https://cdn.jsdelivr.net/gh/LazuliKao/frp-schemas@".concat(SCHEMA_COMMIT, "/frpc-schema.json"),
        "https://fastly.jsdelivr.net/gh/LazuliKao/frp-schemas@".concat(SCHEMA_COMMIT, "/frpc-schema.json"),
        "https://raw.githubusercontent.com/LazuliKao/frp-schemas/".concat(SCHEMA_COMMIT, "/frpc-schema.json")
    ],
    frps: [
        "https://cdn.jsdelivr.net/gh/LazuliKao/frp-schemas@".concat(SCHEMA_COMMIT, "/frps-schema.json"),
        "https://fastly.jsdelivr.net/gh/LazuliKao/frp-schemas@".concat(SCHEMA_COMMIT, "/frps-schema.json"),
        "https://raw.githubusercontent.com/LazuliKao/frp-schemas/".concat(SCHEMA_COMMIT, "/frps-schema.json")
    ]
}));

;// CONCATENATED MODULE: ./utils/frp-editor/taplo-worker.ts
var taplo_worker_e;
let taplo_worker_o;

let taplo_worker_t = new Map(), taplo_worker_a = new Map(), taplo_worker_l = null == (taplo_worker_e = globalThis.fetch) ? void 0 : taplo_worker_e.bind(globalThis);
function taplo_worker_n(e) {
    globalThis.postMessage(e);
}
function s(e) {
    return e.replace(/\\/g, "/").replace(/^file:\/\//, "");
}
async function taplo_worker_i() {
    var e, a;
    let l, i;
    if (taplo_worker_o) return;
    console.log("[Taplo Worker] Importing Taplo LSP from CDN...");
    let c = await Function("url", "return import(url);")(TAPLO_LSP_URL), p = null != (e = c.TaploLsp) ? e : null == (a = c.default) ? void 0 : a.TaploLsp;
    if (!p) throw Error("Taplo LSP export is unavailable.");
    console.log("[Taplo Worker] Initializing Taplo LSP WASM instance..."), taplo_worker_o = await p.initialize((l = async ()=>new Uint8Array(0), i = new TextDecoder(), {
        now: ()=>new Date(),
        envVar: ()=>void 0,
        envVars: ()=>[],
        stdErrAtty: ()=>!1,
        stdin: l,
        stdout: async (e)=>{
            let o = i.decode(e).trim();
            return o && console.log("[Taplo Worker stdout]", o), e.byteLength;
        },
        stderr: async (e)=>{
            let o = i.decode(e).trim();
            return o && console.warn("[Taplo Worker stderr]", o), e.byteLength;
        },
        glob: ()=>[],
        readFile: async (e)=>{
            let o = s(e);
            for (let [r, a] of taplo_worker_t.entries())if (o === r || o.endsWith(r) || r.endsWith(o)) return console.log("[Taplo Worker readFile HIT]", e, "matched key:", r), a;
            return console.warn("[Taplo Worker readFile MISS (fallback to empty JSON)]", e, "known keys:", [
                ...taplo_worker_t.keys()
            ]), new TextEncoder().encode("{}");
        },
        writeFile: async ()=>{},
        urlToFilePath: (e)=>{
            let o;
            try {
                o = new URL(e).pathname || e;
            } catch (r) {
                o = e.replace(/^file:\/\//, "");
            }
            return console.log("[Taplo Worker urlToFilePath]", e, "->", o), o;
        },
        isAbsolute: ()=>!0,
        cwd: ()=>"/",
        findConfigFile: ()=>void 0
    }), {
        onMessage: (e)=>{
            console.log("[Taplo Worker -> Client (onMessage)]", e.method || "reply(".concat(e.id, ")"), e), taplo_worker_n({
                type: "message",
                message: e
            });
        }
    }), console.log("[Taplo Worker] Taplo LSP WASM initialized successfully.");
}
globalThis.fetch = async (e, o)=>{
    let r = "string" == typeof e ? e : e instanceof URL ? e.href : e.url;
    for (let [e, o] of (console.log("[Taplo Worker fetch]", r), taplo_worker_a.entries()))if (r === e || r.endsWith(e) || e.endsWith(r)) {
        console.log("[Taplo Worker fetch HIT (intercepted schema)]:", r);
        let e = new Response(o, {
            status: 200,
            headers: {
                "Content-Type": "application/json"
            }
        });
        return Object.defineProperty(e, "url", {
            value: r,
            writable: !1,
            configurable: !0
        }), e;
    }
    if (taplo_worker_l) {
        console.log("[Taplo Worker fetch MISS (calling network)]:", r);
        try {
            let t = await taplo_worker_l(e, o);
            return console.log("[Taplo Worker fetch network response]:", r, t.status), t.url || Object.defineProperty(t, "url", {
                value: r,
                writable: !1,
                configurable: !0
            }), t;
        } catch (e) {
            throw console.error("[Taplo Worker fetch network error]:", r, e), e;
        }
    }
    throw console.error("[Taplo Worker fetch unavailable]:", r), Error("fetch unavailable for ".concat(r));
}, globalThis.onmessage = (e)=>{
    (async ()=>{
        try {
            switch(e.data.type){
                case "initialize":
                    console.log("[Taplo Worker] Received initialize request"), await taplo_worker_i(), taplo_worker_n({
                        type: "ready"
                    });
                    break;
                case "setSchemas":
                    console.log("[Taplo Worker] Updating schemas, keys:", Object.keys(e.data.schemas)), function(e) {
                        let o = new TextEncoder();
                        for (let [r, l] of Object.entries(e)){
                            let e = JSON.stringify(l), n = o.encode(e);
                            taplo_worker_t.set(r, n), taplo_worker_t.set(s(r), n), taplo_worker_a.set(r, e), taplo_worker_a.set(s(r), e);
                            try {
                                let o = new URL(r);
                                taplo_worker_t.set(o.pathname, n), taplo_worker_a.set(o.pathname, e), taplo_worker_a.set(o.href, e);
                            } catch (e) {}
                        }
                    }(e.data.schemas);
                    break;
                case "send":
                    {
                        if (!taplo_worker_o) throw Error("Taplo has not been initialized.");
                        let r = e.data.message.method || "reply(".concat(e.data.message.id, ")");
                        console.log("[Taplo Worker -> Rust lsp.send]", r, e.data.message);
                        try {
                            taplo_worker_o.send(e.data.message);
                        } catch (e) {
                            throw console.error("[Taplo Worker] lsp.send threw exception:", r, e), e;
                        }
                        break;
                    }
                case "dispose":
                    console.log("[Taplo Worker] Disposing Taplo LSP"), null == taplo_worker_o || taplo_worker_o.dispose(), taplo_worker_o = void 0, taplo_worker_t.clear(), globalThis.close();
            }
        } catch (e) {
            console.error("[Taplo Worker unhandled error]", e), taplo_worker_n({
                type: "error",
                message: e instanceof Error ? e.message : "Unable to start Taplo."
            });
        }
    })();
};

