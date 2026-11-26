// Cloudflare Worker: a tiny relay to Twelve Data for networks that block api.twelvedata.com.
// Deploy: dash.cloudflare.com > Workers & Pages > Create > Hello World > paste this > Deploy.
// Then paste the worker URL (https://NAME.SUBDOMAIN.workers.dev) into the "proxy URL" box in the app header.
const cors = { 'access-control-allow-origin': '*' };
export default {
  async fetch(req) {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
    const u = new URL(req.url);
    if (!/^\/(time_series|price|api_usage)$/.test(u.pathname)) return new Response('not allowed', { status: 404, headers: cors });
    const r = await fetch('https://api.twelvedata.com' + u.pathname + u.search);
    return new Response(r.body, { status: r.status, headers: { ...cors, 'content-type': 'application/json' } });
  }
};
