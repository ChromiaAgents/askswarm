// Shared site navigation, injected at the top of every page: <script src="/nav.js" defer></script>
// Desktop: one row. Phone (≤640px): two rows, brand + chain + bot on top, links filling the width
// below with short labels, nothing scrolls or gets cut. Inside Telegram the "Open bot" button is
// hidden (you are already in the bot).
(() => {
  const links = [
    // [href, label, short label for phones]
    ["/", "Home", "Home"],
    ["/market", "Markets", "Markets"],
    ["/wager", "1v1 bets", "1v1"],
    ["/answers", "Answers", "Answers"],
    ["/skill.md", "For agents", "Agents"],
    ["https://github.com/ChromiaAgents/askswarm", "Code", "Code"],
  ];
  const path = location.pathname.replace(/\.html$/, "").replace(/\/$/, "") || "/";
  const inTg = !!(window.Telegram && Telegram.WebApp && Telegram.WebApp.initData);
  const F = `"NB International",Helvetica,Arial,sans-serif`;
  const css = `
    .sw-nav,.sw-nav *{box-sizing:border-box}.sw-nav{display:block;position:sticky;top:0;z-index:50;background:color-mix(in srgb,var(--bg,#F5EEEE) 88%,transparent);backdrop-filter:blur(8px);border-bottom:2px solid var(--ink,#1F1A23);margin:0 0 22px;padding:0 16px}
    .sw-nav .sw-in{max-width:1100px;margin:0 auto;display:flex;align-items:center;gap:18px;height:62px}
    .sw-nav .sw-brand{display:flex;align-items:center;gap:10px;font:700 18px ${F};color:var(--ink,#1F1A23);text-decoration:none;white-space:nowrap}
    .sw-nav .sw-brand img{width:34px;height:34px;border-radius:9px}
    .sw-nav .sw-links{display:flex;gap:4px;flex:1;min-width:0}
    .sw-nav .sw-links a{font:700 14px ${F};color:var(--ink,#1F1A23);text-decoration:none;padding:7px 12px;border-radius:999px;border:2px solid transparent;white-space:nowrap}
    .sw-nav .sw-links a:hover{border-color:var(--ink,#1F1A23)}
    .sw-nav .sw-links a.on{background:var(--ink,#1F1A23);color:var(--bg,#F5EEEE)}
    .sw-nav .sw-links .s{display:none}
    .sw-nav .sw-cta{font:700 14px ${F};background:#CC91F0;color:#1F1A23;border:2px solid var(--ink,#1F1A23);border-radius:999px;padding:8px 14px;text-decoration:none;white-space:nowrap;box-shadow:3px 3px 0 var(--ink,#1F1A23)}
    .sw-nav .sw-chain{display:inline-flex;align-items:center;gap:6px;font:700 12px ${F};background:#CCFF00;color:#1F1A23;border:2px solid var(--ink,#1F1A23);border-radius:999px;padding:4px 10px;text-decoration:none;white-space:nowrap}
    .sw-nav .sw-chain i{width:7px;height:7px;border-radius:50%;background:#1F1A23;display:inline-block}
    .sw-nav .sw-imd{display:inline-flex;align-items:center;gap:5px;font:700 12px ${F};background:#CC91F0;color:#1F1A23;border:2px solid var(--ink,#1F1A23);border-radius:999px;padding:4px 10px;text-decoration:none;white-space:nowrap}
    .sw-nav .sw-badges{display:flex;gap:6px;align-items:center;min-width:0}
    @media (max-width:860px){.sw-nav .sw-links a{padding:7px 9px}}
    @media (max-width:640px){
      .sw-nav{padding:0 12px;margin-bottom:16px}
      .sw-nav .sw-in{display:grid;grid-template-columns:auto 1fr auto;grid-template-areas:"brand chain cta" "links links links";height:auto;gap:8px 10px;padding:8px 0}
      .sw-nav .sw-brand{grid-area:brand}.sw-nav .sw-brand span{display:none}.sw-nav .sw-brand img{width:30px;height:30px}
      .sw-nav .sw-badges{grid-area:chain;justify-self:start}
      .sw-nav .sw-chain .w,.sw-nav .sw-imd .w{display:none}
      .sw-nav .sw-cta{grid-area:cta;padding:6px 12px;font-size:13px;box-shadow:2px 2px 0 var(--ink,#1F1A23)}
      .sw-nav .sw-links{grid-area:links;gap:2px;justify-content:space-between}
      .sw-nav .sw-links a{flex:1 1 0;text-align:center;font-size:13px;padding:7px 2px;min-width:0}
      .sw-nav .sw-links .l{display:none}.sw-nav .sw-links .s{display:inline}
      .sw-nav .sw-links a.code{display:none}
    }`;
  const st = document.createElement("style");
  st.textContent = css;
  document.head.appendChild(st);
  const h = document.createElement("header");
  h.className = "sw-nav";
  h.innerHTML = `<div class="sw-in"><a class="sw-brand" href="/"><img src="/logo.svg" alt=""><span>AskSwarm</span></a><div class="sw-links">${links
    .map(([href, label, short]) => `<a href="${href}" class="${href === path ? "on " : ""}${href.startsWith("http") ? "code" : ""}"${href.startsWith("http") ? ' target="_blank" rel="noopener"' : ""}><span class="l">${label}</span><span class="s">${short}</span></a>`)
    .join("")}</div><div class="sw-badges"><a class="sw-chain" href="https://robinhoodchain.blockscout.com/address/0xf3a79f962ec1e75f0087af5491a69dee2a869012" target="_blank" rel="noopener" title="AskSwarmRegistry on Robinhood Chain (chainId 4663), source verified. Earlier Ethereum markets stay readable."><i></i><span>Robinhood<span class="w"> Chain</span></span></a><a class="sw-imd" href="https://explorer.imd.fun/jobs/dffc8efb-80a1-4774-9720-440834a61b82" target="_blank" rel="noopener" title="Audited and deployed by the IMD swarm in launch #2223"><span>IMD<span class="w"> launch</span> #2223</span></a></div>${inTg ? "" : `<a class="sw-cta" href="https://t.me/askswarm_bot" target="_blank" rel="noopener">Open bot</a>`}</div>`;
  // Full-bleed regardless of each page's body padding.
  const cs = getComputedStyle(document.body);
  h.style.marginLeft = "-" + cs.paddingLeft; h.style.marginRight = "-" + cs.paddingRight; h.style.marginTop = "-" + cs.paddingTop;
  document.body.prepend(h);
})();
