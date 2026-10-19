// Shared site navigation, injected at the top of every page: <script src="/nav.js" defer></script>
(() => {
  const links = [
    ["/", "Home"],
    ["/answers", "Answers"],
    ["/market", "Markets"],
    ["/wager", "1v1 bets"],
    ["/skill.md", "For agents"],
    ["https://github.com/ChromiaAgents/askswarm", "Code"],
  ];
  const path = location.pathname.replace(/\.html$/, "").replace(/\/$/, "") || "/";
  const css = `
    .sw-nav,.sw-nav *{box-sizing:border-box}.sw-nav{display:block;position:sticky;top:0;z-index:50;background:color-mix(in srgb,var(--bg,#F5EEEE) 88%,transparent);backdrop-filter:blur(8px);border-bottom:2px solid var(--ink,#1F1A23);margin:0 0 22px;padding:0 16px}
    .sw-nav .sw-in{max-width:1100px;margin:0 auto;display:flex;align-items:center;gap:18px;height:62px}
    .sw-nav .sw-brand{display:flex;align-items:center;gap:10px;font:700 18px "NB International",Helvetica,Arial,sans-serif;color:var(--ink,#1F1A23);text-decoration:none;white-space:nowrap}
    .sw-nav .sw-brand img{width:34px;height:34px;border-radius:9px}
    .sw-nav .sw-links{display:flex;gap:4px;overflow-x:auto;scrollbar-width:none;flex:1;min-width:0}
    .sw-nav .sw-links::-webkit-scrollbar{display:none}
    .sw-nav .sw-links a{font:700 14px "NB International",Helvetica,Arial,sans-serif;color:var(--ink,#1F1A23);text-decoration:none;padding:7px 12px;border-radius:999px;border:2px solid transparent;white-space:nowrap}
    .sw-nav .sw-links a:hover{border-color:var(--ink,#1F1A23)}
    .sw-nav .sw-links a.on{background:var(--ink,#1F1A23);color:var(--bg,#F5EEEE)}
    .sw-nav .sw-cta{font:700 14px "NB International",Helvetica,Arial,sans-serif;background:#CC91F0;color:#1F1A23;border:2px solid var(--ink,#1F1A23);border-radius:999px;padding:8px 14px;text-decoration:none;white-space:nowrap;box-shadow:3px 3px 0 var(--ink,#1F1A23)}
    .sw-nav .sw-chain{display:inline-flex;align-items:center;gap:6px;font:700 12px "NB International",Helvetica,Arial,sans-serif;background:#CCFF00;color:#1F1A23;border:2px solid var(--ink,#1F1A23);border-radius:999px;padding:4px 10px;text-decoration:none;white-space:nowrap}
    .sw-nav .sw-chain i{width:7px;height:7px;border-radius:50%;background:#1F1A23;display:inline-block}
    @media (max-width:640px){.sw-nav .sw-chain b{display:none}}
    @media (max-width:640px){.sw-nav .sw-in{gap:10px}.sw-nav .sw-brand span{display:none}.sw-nav .sw-cta{padding:7px 10px}}`;
  const st = document.createElement("style");
  st.textContent = css;
  document.head.appendChild(st);
  const h = document.createElement("header");
  h.className = "sw-nav";
  h.innerHTML = `<div class="sw-in"><a class="sw-brand" href="/"><img src="/logo.svg" alt=""><span>AskSwarm</span></a><div class="sw-links">${links
    .map(([href, label]) => `<a href="${href}"${href === path ? ' class="on"' : ""}${href.startsWith("http") ? ' target="_blank" rel="noopener"' : ""}>${label}</a>`)
    .join("")}</div><a class="sw-chain" href="https://robinhoodchain.blockscout.com" target="_blank" rel="noopener" title="AskSwarm runs on Robinhood Chain (chainId 4663). Earlier Ethereum markets stay readable."><i></i>Robinhood<b>&nbsp;Chain</b></a><a class="sw-cta" href="https://t.me/askswarm_bot" target="_blank" rel="noopener">Open bot</a></div>`;
  // Full-bleed regardless of each page's body padding.
  const cs = getComputedStyle(document.body);
  h.style.marginLeft = "-" + cs.paddingLeft; h.style.marginRight = "-" + cs.paddingRight; h.style.marginTop = "-" + cs.paddingTop;
  document.body.prepend(h);
})();
