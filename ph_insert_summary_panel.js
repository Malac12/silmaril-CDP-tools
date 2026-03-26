(() => {
  const items = [
    {
      rank: 1,
      name: "Agentplace AI Agents",
      ph: "Create specialized AI agents for real tasks and workflows. Product Hunt page adds that teams can build, test, deploy, and iteratively improve agents for real work.",
      feedback: "367 upvotes, 60 comments, 2 visible reviews. Review sentiment is strongly positive: users call it intuitive, easy to adapt, and impressive for website and agent building.",
      site: "Agentplace presents itself as an agent workspace: build agents fast, switch into a ChatGPT-style work environment, improve agents over time, connect tools/MCPs, and start on a free tier before scaling."
    },
    {
      rank: 2,
      name: "Auto Mode by Claude Code",
      ph: "Homepage launch copy says it lets Claude make permission decisions on your behalf. The linked Product Hunt page resolves to the broader Claude by Anthropic product page rather than an Auto Mode-specific landing page.",
      feedback: "264 upvotes, 5 comments on the launch. The Claude product page shows 693 reviews overall, with visible reviews praising long-context reasoning, code quality, and lower hallucination rates; downsides mentioned include usage limits and occasional over-abstraction.",
      site: "The outbound page is Claude's general product overview, not an Auto Mode page. It positions Claude as AI for problem solvers, highlights writing/learning/coding use cases, cross-app availability, Claude Code, and memory import from other AI providers."
    },
    {
      rank: 3,
      name: "Pendium",
      ph: "Pendium says it helps businesses market to AI agents by tracking how agents research a category, what they cite, and how a brand shows up, with either end-to-end workflows or integration into an existing content system.",
      feedback: "193 upvotes, 13 comments. No visible review excerpt was rendered on the Product Hunt product page during this pass.",
      site: "Pendium's website centers on AI visibility: scan what ChatGPT, Claude, Gemini, and other systems say about a business, simulate buyer personas, monitor recommendations, and generate content designed to influence how AI agents recommend a brand."
    },
    {
      rank: 4,
      name: "TurboQuant",
      ph: "Product Hunt describes TurboQuant as a new Google LLM compression algorithm and frames it as a high-efficiency quantization approach for large language models and vector search.",
      feedback: "186 upvotes, 2 comments. No visible review excerpt was rendered on the Product Hunt product page during this pass.",
      site: "The outbound page is a Google Research article. It explains TurboQuant, QJL, and PolarQuant as compression algorithms for KV cache and vector search, claiming major memory reduction with minimal accuracy loss and substantial speedups in benchmarked workloads."
    },
    {
      rank: 5,
      name: "LayerProof Matte",
      ph: "LayerProof Matte promises to repurpose a source URL into unique social content per format, with Product Hunt copy emphasizing traceable claims and no hallucinations.",
      feedback: "158 upvotes, 10 comments. No visible review excerpt was rendered on the Product Hunt product page during this pass.",
      site: "LayerProof's external page pitches a fast campaign generator: paste one URL, get native-ready variants for LinkedIn, X, Instagram, Facebook, and TikTok, with 5-minute turnaround, brand voice consistency, and one-click export."
    }
  ];

  const target = document.querySelector('[data-test="homepage-section-today"]');
  if (!target) {
    return { ok: false, error: "homepage section not found" };
  }

  const heading =
    target.querySelector('[data-test="homepage-tagline"]') ||
    target.querySelector("h1");
  if (!heading) {
    return { ok: false, error: "heading not found" };
  }

  const existing = document.getElementById("codex-ph-summary-panel");
  if (existing) {
    existing.remove();
  }

  const panel = document.createElement("section");
  panel.id = "codex-ph-summary-panel";
  panel.setAttribute("data-codex-panel", "product-hunt-summary");
  panel.style.cssText = [
    "margin:0 0 20px 0",
    "padding:16px",
    "border:1px solid rgba(15,23,42,0.12)",
    "border-radius:16px",
    "background:linear-gradient(180deg,#fffaf5 0%,#ffffff 100%)",
    "box-shadow:0 12px 30px rgba(15,23,42,0.06)"
  ].join(";");

  const cards = items
    .map((item) => {
      return `
        <article style="padding:12px 0;border-top:${item.rank === 1 ? "0" : "1px solid rgba(15,23,42,0.08)"};">
          <div style="display:flex;align-items:flex-start;gap:10px;flex-wrap:wrap;">
            <div style="min-width:28px;height:28px;border-radius:999px;background:#111827;color:#ffffff;display:flex;align-items:center;justify-content:center;font:600 13px/1 system-ui;">${item.rank}</div>
            <div style="flex:1;min-width:240px;">
              <div style="font:700 15px/1.4 system-ui;color:#111827;margin:0 0 6px 0;">${item.name}</div>
              <div style="font:600 12px/1.5 system-ui;color:#9a3412;text-transform:uppercase;letter-spacing:0.04em;">Product Hunt</div>
              <p style="margin:2px 0 8px 0;font:400 13px/1.55 system-ui;color:#334155;">${item.ph}</p>
              <div style="font:600 12px/1.5 system-ui;color:#9a3412;text-transform:uppercase;letter-spacing:0.04em;">Visible Feedback</div>
              <p style="margin:2px 0 8px 0;font:400 13px/1.55 system-ui;color:#334155;">${item.feedback}</p>
              <div style="font:600 12px/1.5 system-ui;color:#9a3412;text-transform:uppercase;letter-spacing:0.04em;">Website</div>
              <p style="margin:2px 0 0 0;font:400 13px/1.55 system-ui;color:#334155;">${item.site}</p>
            </div>
          </div>
        </article>
      `;
    })
    .join("");

  panel.innerHTML = `
    <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:12px;flex-wrap:wrap;">
      <div>
        <div style="font:700 16px/1.4 system-ui;color:#111827;">Codex Summary Panel</div>
        <p style="margin:4px 0 0 0;font:400 13px/1.55 system-ui;color:#475569;max-width:780px;">
          Top 5 launches reviewed across Product Hunt and each product's outbound site. Inserted without replacing existing page content.
        </p>
      </div>
      <div style="font:600 12px/1.4 system-ui;color:#9a3412;background:#ffedd5;border:1px solid #fdba74;border-radius:999px;padding:6px 10px;">
        Sources: homepage, product pages, outbound sites
      </div>
    </div>
    <div style="margin-top:12px;">
      ${cards}
    </div>
  `;

  heading.insertAdjacentElement("afterend", panel);

  return {
    ok: true,
    insertedAfter: heading.textContent.trim(),
    itemCount: items.length
  };
})()
