const normalizeInline = (value) => (value || "")
  .replace(/\u00a0/g, " ")
  .replace(/\s+/g, " ")
  .trim();

const speechText = (root, aggressivelyClean = false) => {
  if (!root) return "";
  const alwaysRemove =
    'script,style,noscript,template,form,button,svg,canvas,[aria-hidden="true"]';
  const fallbackFurniture =
    'nav,header,footer,aside,.advertisement,.advert,.ad,.promo,.newsletter,.share,.social';
  root.querySelectorAll(
    aggressivelyClean ? `${alwaysRemove},${fallbackFurniture}` : alwaysRemove
  ).forEach(element => element.remove());

  const boundaries = new Set([
    'ADDRESS', 'ARTICLE', 'BLOCKQUOTE', 'DD', 'DIV', 'DL', 'DT', 'FIGCAPTION',
    'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HR', 'LI', 'MAIN', 'OL', 'P',
    'PRE', 'SECTION', 'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD', 'TR', 'UL'
  ]);
  const paragraphs = [];
  let current = "";

  const flush = () => {
    const paragraph = normalizeInline(current);
    if (paragraph) paragraphs.push(paragraph);
    current = "";
  };

  const walk = (node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      current += node.nodeValue || "";
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node.tagName === 'BR') {
      flush();
      return;
    }
    const isBoundary = boundaries.has(node.tagName);
    if (isBoundary) flush();
    for (const child of node.childNodes) walk(child);
    if (isBoundary) flush();
  };

  walk(root);
  flush();
  return paragraphs.join("\n\n").trim();
};

const challenged =
  document.title === "Vercel Security Checkpoint" ||
  !!document.querySelector('script[src*="vercel/security/static/challenge"]') ||
  (document.getElementById("header-text")?.innerText || "")
    .toLowerCase().includes("verifying your browser");

let parsed = null;
try {
  if (typeof Readability === 'function') {
    parsed = new Readability(document.cloneNode(true), {
      charThreshold: minimumReadableCharacterCount,
      keepClasses: false,
      maxElemsToParse: readabilityMaximumElements,
      nbTopCandidates: readabilityTopCandidates
    }).parse();
  }
} catch (_) {
  parsed = null;
}

let text = "";
let method = "semantic-fallback";
if (parsed?.content) {
  const articleRoot = document.createElement('div');
  articleRoot.innerHTML = parsed.content;
  const readableText = speechText(articleRoot);
  if (readableText.length >= minimumReadableCharacterCount) {
    text = readableText;
    method = "mozilla-readability";
  }
}

if (text.length < minimumReadableCharacterCount) {
  const candidates = [
    ...document.querySelectorAll('article,[itemprop="articleBody"],main,[role="main"]')
  ];
  for (const candidate of candidates) {
    const candidateText = speechText(candidate.cloneNode(true), true);
    if (candidateText.length > text.length) text = candidateText;
  }
  if (text.length < minimumReadableCharacterCount && document.body) {
    text = speechText(document.body.cloneNode(true), true);
  }
}

const fallbackTitle =
  document.querySelector('meta[property="og:title"]')?.content ||
  document.querySelector('article h1, main h1, h1')?.innerText ||
  document.title || "";

return JSON.stringify({
  title: normalizeInline(parsed?.title || fallbackTitle),
  text,
  resolvedURL: location.href,
  ready: document.readyState === "complete",
  challenged,
  method
});
