(() => {
  const options = (() => {
    try {
      if (typeof globalThis !== "undefined" && globalThis.__silmarilSnapshotOptions) {
        return globalThis.__silmarilSnapshotOptions || {};
      }
    } finally {
      try {
        if (typeof globalThis !== "undefined") {
          delete globalThis.__silmarilSnapshotOptions;
        }
      } catch (_) {}
    }

    return {};
  })();

  const clean = (value) => String(value || "").replace(/\s+/g, " ").trim();
  const viewportWidth = Math.max(window.innerWidth || 0, document.documentElement.clientWidth || 0);
  const viewportHeight = Math.max(window.innerHeight || 0, document.documentElement.clientHeight || 0);
  const coverageMode = String(options.coverage || "viewport").toLowerCase() === "content" ? "content" : "viewport";
  const interactiveSelector = [
    "a[href]",
    "button",
    "input",
    "textarea",
    "select",
    "[role=\"button\"]",
    "[role=\"link\"]",
    "[role=\"textbox\"]",
    "[role=\"checkbox\"]",
    "[role=\"radio\"]",
    "[role=\"combobox\"]",
    "[tabindex]"
  ].join(",");
  const maxRefs = coverageMode === "content" ? 180 : 120;
  const contentWindowTop = -Math.max(120, Math.round(viewportHeight * 0.25));
  const contentWindowBottom = Math.max(Math.round(viewportHeight * 3), viewportHeight + 900);

  const cssEscape = (value) => {
    if (window.CSS && typeof window.CSS.escape === "function") {
      return window.CSS.escape(String(value));
    }

    return String(value).replace(/([ !"#$%&'()*+,./:;<=>?@[\\\]^`{|}~])/g, "\\$1");
  };

  const isVisible = (el) => {
    if (!el || !(el instanceof Element)) return false;
    const style = window.getComputedStyle(el);
    if (!style) return false;
    if (style.display === "none") return false;
    if (style.visibility === "hidden" || style.visibility === "collapse") return false;
    if (parseFloat(style.opacity || "1") === 0) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  const isInViewport = (el) => {
    if (!isVisible(el)) return false;
    const rect = el.getBoundingClientRect();
    return rect.bottom >= 0 && rect.right >= 0 && rect.top <= viewportHeight && rect.left <= viewportWidth;
  };

  const isInContentWindow = (el) => {
    if (!isVisible(el)) return false;
    const rect = el.getBoundingClientRect();
    return rect.bottom >= contentWindowTop && rect.right >= 0 && rect.top <= contentWindowBottom && rect.left <= viewportWidth;
  };

  const isWithinCoverage = (el) => {
    return coverageMode === "content" ? isInContentWindow(el) : isInViewport(el);
  };

  const getRole = (el) => {
    if (!el) return "";
    const explicitRole = clean(el.getAttribute && el.getAttribute("role"));
    if (explicitRole) return explicitRole.toLowerCase();
    const tag = (el.tagName || "").toLowerCase();
    if (tag === "a" && el.hasAttribute("href")) return "link";
    if (tag === "button") return "button";
    if (tag === "input") {
      const type = clean(el.getAttribute("type") || "text").toLowerCase();
      if (type === "button" || type === "submit" || type === "reset") return "button";
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      return "textbox";
    }
    if (tag === "textarea") return "textbox";
    if (tag === "select") return "combobox";
    if (/^h[1-6]$/.test(tag)) return "heading";
    if (tag === "main") return "main";
    if (tag === "nav") return "navigation";
    if (tag === "header") return "banner";
    if (tag === "footer") return "contentinfo";
    if (tag === "aside") return "complementary";
    if (tag === "form") return "form";
    if (tag === "dialog") return "dialog";
    return "";
  };

  const getLabel = (el) => {
    if (!el) return "";
    const ariaLabel = clean(el.getAttribute && el.getAttribute("aria-label"));
    if (ariaLabel) return ariaLabel;
    const labelledBy = clean(el.getAttribute && el.getAttribute("aria-labelledby"));
    if (labelledBy) {
      const parts = labelledBy
        .split(/\s+/)
        .map((id) => {
          const ref = document.getElementById(id);
          return clean(ref ? (ref.innerText || ref.textContent) : "");
        })
        .filter(Boolean);
      if (parts.length > 0) return clean(parts.join(" "));
    }
    if (typeof el.labels !== "undefined" && el.labels && el.labels.length > 0) {
      const labelParts = Array.from(el.labels)
        .map((labelEl) => clean(labelEl.innerText || labelEl.textContent))
        .filter(Boolean);
      if (labelParts.length > 0) return clean(labelParts.join(" "));
    }
    const alt = clean(el.getAttribute && el.getAttribute("alt"));
    if (alt) return alt;
    const placeholder = clean(el.getAttribute && el.getAttribute("placeholder"));
    if (placeholder) return placeholder;
    const title = clean(el.getAttribute && el.getAttribute("title"));
    if (title) return title;
    if (el.tagName && /^H[1-6]$/.test(el.tagName)) {
      return clean(el.innerText || el.textContent);
    }
    const inner = clean(typeof el.innerText === "string" ? el.innerText : el.textContent);
    return inner;
  };

  const isInteractive = (el) => {
    if (!el || !(el instanceof Element)) return false;
    if (el.matches(interactiveSelector)) {
      const tabIndex = clean(el.getAttribute("tabindex"));
      return !tabIndex || tabIndex !== "-1" || /^(a|button|input|textarea|select)$/i.test(el.tagName);
    }
    if (typeof el.onclick === "function") return true;
    return false;
  };

  const isHeading = (el) => {
    if (!el || !(el instanceof Element)) return false;
    if (el.tagName && /^H[1-6]$/.test(el.tagName)) return true;
    return getRole(el) === "heading";
  };

  const isLandmark = (el) => {
    if (!el || !(el instanceof Element)) return false;
    return ["main", "navigation", "banner", "contentinfo", "complementary", "form", "dialog"].includes(getRole(el));
  };

  const isFixedOrSticky = (el) => {
    if (!el || !(el instanceof Element)) return false;
    const style = window.getComputedStyle(el);
    if (!style) return false;
    return style.position === "fixed" || style.position === "sticky";
  };

  const getUniqueSelector = (el) => {
    if (!el || !(el instanceof Element)) return "";

    if (el.id) {
      const idSelector = `#${cssEscape(el.id)}`;
      try {
        if (document.querySelectorAll(idSelector).length === 1) return idSelector;
      } catch (_) {}
    }

    const tag = (el.tagName || "").toLowerCase();
    const attrCandidates = [
      "data-testid",
      "data-test",
      "data-qa",
      "name",
      "aria-label",
      "placeholder",
      "title",
      "role",
      "type",
      "for"
    ];

    for (const attrName of attrCandidates) {
      const attrValue = clean(el.getAttribute && el.getAttribute(attrName));
      if (!attrValue) continue;
      const selector = `${tag}[${attrName}="${cssEscape(attrValue)}"]`;
      try {
        if (document.querySelectorAll(selector).length === 1) return selector;
      } catch (_) {}
    }

    if (tag === "a") {
      const href = clean(el.getAttribute("href"));
      if (href) {
        const selector = `a[href="${cssEscape(href)}"]`;
        try {
          if (document.querySelectorAll(selector).length === 1) return selector;
        } catch (_) {}
      }
    }

    const parts = [];
    let current = el;
    while (current && current.nodeType === 1 && current !== document.documentElement) {
      const currentTag = (current.tagName || "").toLowerCase();
      if (!currentTag) break;

      let part = currentTag;
      if (current.id) {
        const idSelector = `#${cssEscape(current.id)}`;
        try {
          if (document.querySelectorAll(idSelector).length === 1) {
            parts.unshift(idSelector);
            break;
          }
        } catch (_) {}
      }

      let usedAttribute = false;
      for (const attrName of ["data-testid", "data-test", "name", "aria-label", "title"]) {
        const attrValue = clean(current.getAttribute && current.getAttribute(attrName));
        if (!attrValue) continue;
        const candidate = `${currentTag}[${attrName}="${cssEscape(attrValue)}"]`;
        try {
          if (document.querySelectorAll(candidate).length === 1) {
            part = candidate;
            usedAttribute = true;
            break;
          }
        } catch (_) {}
      }

      if (!usedAttribute) {
        const parent = current.parentElement;
        if (parent) {
          const sameTagSiblings = Array.from(parent.children).filter(
            (child) => (child.tagName || "").toLowerCase() === currentTag
          );
          if (sameTagSiblings.length > 1) {
            const index = sameTagSiblings.indexOf(current) + 1;
            part = `${currentTag}:nth-of-type(${index})`;
          }
        }
      }

      parts.unshift(part);
      const selector = parts.join(" > ");
      try {
        if (document.querySelectorAll(selector).length === 1) return selector;
      } catch (_) {}

      current = current.parentElement;
    }

    return parts.join(" > ");
  };

  const extractSupportText = (el, primaryLabel) => {
    if (!el || !el.children || el.children.length === 0) return "";
    const texts = [];
    for (const child of Array.from(el.children).slice(0, 8)) {
      if (!isVisible(child)) continue;
      if (isInteractive(child)) continue;
      if (child.querySelector(interactiveSelector) && child.children.length > 1) continue;
      const text = clean(child.innerText || child.textContent);
      if (!text) continue;
      if (primaryLabel && text === primaryLabel) continue;
      if (text.length < 6 || text.length > 180) continue;
      if (!texts.includes(text)) texts.push(text);
      if (texts.length >= 2) break;
    }
    return clean(texts.join(" / "));
  };

  const getGroupLabel = (el) => {
    const heading = Array.from(el.querySelectorAll("h1,h2,h3,h4,h5,h6,[role='heading']"))
      .find((node) => isVisible(node) && isWithinCoverage(node));
    if (heading) return getLabel(heading);
    const interactive = Array.from(el.querySelectorAll(interactiveSelector))
      .find((node) => isVisible(node) && isWithinCoverage(node));
    if (interactive) return getLabel(interactive);
    return clean(el.innerText || el.textContent);
  };

  const findGroupingAncestor = (el, root) => {
    let current = el.parentElement;
    while (current && current !== root && current !== document.body) {
      if (!isVisible(current) || !isWithinCoverage(current)) {
        current = current.parentElement;
        continue;
      }
      if (isLandmark(current)) return current;
      const tag = (current.tagName || "").toLowerCase();
      if (tag === "article" || tag === "li" || tag === "section" || tag === "form") return current;
      if (tag === "div") {
        const text = clean(current.innerText || current.textContent);
        const interactiveCount = Array.from(current.querySelectorAll(interactiveSelector)).filter((node) => isVisible(node)).length;
        if (interactiveCount > 0 && interactiveCount <= 5 && text.length >= 20 && text.length <= 280) {
          return current;
        }
      }
      current = current.parentElement;
    }
    return root;
  };

  const getTopLevelMatches = (selector, predicate) =>
    Array.from(document.querySelectorAll(selector))
      .filter((el) => isVisible(el) && predicate(el))
      .filter((el, index, arr) => !arr.some((other, otherIndex) => otherIndex !== index && other.contains(el)));

  const getContentDivRoots = () => {
    const topThreshold = Math.min(240, Math.round(viewportHeight * 0.26));
    const minWidth = Math.min(560, Math.round(viewportWidth * 0.55));

    return Array.from(document.querySelectorAll("div"))
      .filter((el) => {
        if (!isVisible(el) || !isInContentWindow(el)) return false;
        if (isFixedOrSticky(el)) return false;

        const rect = el.getBoundingClientRect();
        if (rect.top < topThreshold) return false;
        if (rect.width < minWidth) return false;
        if (rect.height < 220) return false;

        const text = clean(el.innerText || el.textContent);
        if (text.length < 60) return false;

        const interactiveCount = Array.from(el.querySelectorAll(interactiveSelector)).filter((node) => isVisible(node)).length;
        return interactiveCount >= 2;
      })
      .sort((a, b) => {
        const rectA = a.getBoundingClientRect();
        const rectB = b.getBoundingClientRect();
        if (rectA.top !== rectB.top) return rectA.top - rectB.top;
        return rectA.height - rectB.height;
      })
      .filter((el, index, arr) => !arr.some((other, otherIndex) => otherIndex !== index && el.contains(other)));
  };

  const topLevelLandmarks = getTopLevelMatches(
    "main,nav,header,footer,aside,form,dialog,[role='main'],[role='navigation'],[role='banner'],[role='contentinfo'],[role='complementary'],[role='form'],[role='dialog']",
    isWithinCoverage
  );

  const topLevelContentRoots = coverageMode === "content"
    ? getTopLevelMatches(
      "main,article,form,dialog,[role='main'],[role='form'],[role='dialog']",
      isInContentWindow
    )
    : [];
  const fallbackContentDivRoots = coverageMode === "content" ? getContentDivRoots() : [];

  let sectionRoots = [];
  if (coverageMode === "content") {
    sectionRoots = topLevelContentRoots;
    if (sectionRoots.length === 0) {
      sectionRoots = fallbackContentDivRoots;
    }
    if (sectionRoots.length === 0) {
      sectionRoots = topLevelLandmarks.filter((el) => !["banner", "navigation", "contentinfo", "complementary"].includes(getRole(el)));
    }
    if (sectionRoots.length === 0 && topLevelLandmarks.length > 0) {
      sectionRoots = topLevelLandmarks;
    }
  } else {
    sectionRoots = topLevelLandmarks;
  }

  if (sectionRoots.length === 0) {
    sectionRoots = [document.body];
  }

  const relevant = new Set(sectionRoots);
  const sectionRootSet = new Set(sectionRoots);

  for (const root of sectionRoots) {
    const visibleHeadings = Array.from(root.querySelectorAll("h1,h2,h3,h4,h5,h6,[role='heading']"))
      .filter((el) => isVisible(el) && isWithinCoverage(el));
    visibleHeadings.slice(0, 20).forEach((el) => relevant.add(el));

    const visibleInteractive = Array.from(root.querySelectorAll(interactiveSelector))
      .filter((el) => isVisible(el) && isWithinCoverage(el));
    visibleInteractive.slice(0, maxRefs).forEach((el) => {
      relevant.add(el);
      const groupingAncestor = findGroupingAncestor(el, root);
      if (groupingAncestor && groupingAncestor !== root) relevant.add(groupingAncestor);
    });
  }

  const ordered = Array.from(relevant)
    .filter((el) => el && el !== document.documentElement && el !== document.head)
    .sort((a, b) => {
      if (a === b) return 0;
      const pos = a.compareDocumentPosition(b);
      if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
      if (pos & Node.DOCUMENT_POSITION_PRECEDING) return 1;
      return 0;
    });

  let refCounter = 0;
  const retained = new Map();
  const refs = [];

  for (const el of ordered) {
    if (!isVisible(el)) continue;
    if (!sectionRootSet.has(el) && !isWithinCoverage(el)) continue;

    let kind = "";
    if (isLandmark(el)) {
      kind = "landmark";
    } else if (isInteractive(el)) {
      kind = "control";
    } else if (isHeading(el)) {
      kind = "heading";
    } else {
      kind = "group";
    }

    const role = getRole(el);
    const tag = (el.tagName || "").toLowerCase();
    const label = kind === "group" ? getGroupLabel(el) : getLabel(el);
    const supportingText = extractSupportText(el, label);
    const selector = getUniqueSelector(el);
    if (!selector) continue;

    refCounter += 1;
    const refId = `e${refCounter}`;
    const node = {
      id: refId,
      kind: kind === "control" ? (role || tag || "control") : kind,
      role,
      tag,
      label,
      supportingText,
      selector,
      interactive: isInteractive(el),
      children: []
    };

    retained.set(el, node);
    refs.push({
      id: refId,
      selector,
      label,
      kind: node.kind,
      role,
      tag
    });

    if (refCounter >= maxRefs) break;
  }

  const roots = [];
  for (const [el, node] of retained.entries()) {
    let parent = el.parentElement;
    let attached = false;
    while (parent) {
      if (retained.has(parent)) {
        retained.get(parent).children.push(node);
        attached = true;
        break;
      }
      parent = parent.parentElement;
    }
    if (!attached) roots.push(node);
  }

  const renderLine = (node) => {
    const labelPart = node.label ? ` "${node.label}"` : "";
    return `${node.id} ${node.kind}${labelPart}`.trim();
  };

  const lines = [];
  const walk = (nodes, depth) => {
    for (const node of nodes) {
      const indent = "  ".repeat(depth);
      lines.push(`${indent}${renderLine(node)}`);
      if (node.supportingText) {
        lines.push(`${indent}  text "${node.supportingText}"`);
      }
      if (node.children && node.children.length > 0) {
        walk(node.children, depth + 1);
      }
    }
  };
  walk(roots, 0);

  return {
    snapshotToken: `snapshot-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    coverage: coverageMode,
    viewportOnly: coverageMode === "viewport",
    refCount: refs.length,
    refs,
    nodes: roots,
    lines
  };
})();
