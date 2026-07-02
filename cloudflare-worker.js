// ==============================================================
//  IT Fix Toolkit - Cloudflare Worker
//  Created by: Salman | Coaching Depot, Kanpur Central - NCR
// ==============================================================
//  Deploy karne ke baad command:
//  irm https://fix.YOURSUBDOMAIN.workers.dev | iex
// ==============================================================

const SCRIPTS = {
  "toolkit" : "https://raw.githubusercontent.com/unitrix2/it-fix-toolkit/main/toolkit.ps1",
  // Future scripts yahan add karo:
  // "fix2"  : "https://raw.githubusercontent.com/unitrix2/it-fix-toolkit/main/fix2.ps1",
};

export default {
  async fetch(request, env, ctx) {
    const url    = new URL(request.url);
    const path   = url.pathname.replace(/^\/+/, "") || "toolkit";
    const script = SCRIPTS[path] ?? SCRIPTS["toolkit"];

    try {
      const resp = await fetch(script, {
        headers: { "User-Agent": "ITFixToolkit/1.0" },
        cf:      { cacheEverything: false },
      });

      if (!resp.ok) {
        return new Response(
          "GitHub se script load nahi hua. Status: " + resp.status,
          { status: 502, headers: { "Content-Type": "text/plain" } }
        );
      }

      const text = await resp.text();
      return new Response(text, {
        status: 200,
        headers: {
          "Content-Type"  : "text/plain; charset=utf-8",
          "Cache-Control" : "no-store, no-cache, must-revalidate",
        },
      });

    } catch (err) {
      return new Response("Error: " + err.message, {
        status: 500,
        headers: { "Content-Type": "text/plain" },
      });
    }
  },
};
