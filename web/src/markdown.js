// Markdown 解析：markdown-it + 常见扩展 + 针对 AI 输出的格式识别。
// 输出按顶层块切开的 HTML，方便预览按块增量更新。

import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import { tex } from '@mdit/plugin-tex';
import { tasklist } from '@mdit/plugin-tasklist';
import { mark } from '@mdit/plugin-mark';
import katex from 'katex';
import hljs from 'highlight.js/lib/common';

// 只保留本次渲染用到的结果，代码高亮和公式不必每次重算。
class RenderCache {
  constructor() {
    this.prev = new Map();
    this.next = new Map();
  }
  get(key, make) {
    let value = this.next.get(key);
    if (value !== undefined) return value;
    value = this.prev.get(key);
    if (value === undefined) value = make();
    this.next.set(key, value);
    return value;
  }
  rotate() {
    this.prev = this.next;
    this.next = new Map();
  }
}

const cache = new RenderCache();

const escapeHtml = (s) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const LANG_ALIASES = {
  sh: 'bash', zsh: 'bash', shell: 'bash', console: 'bash', terminal: 'bash',
  js: 'javascript', jsx: 'javascript', mjs: 'javascript', cjs: 'javascript',
  ts: 'typescript', tsx: 'typescript', py: 'python', rb: 'ruby', rs: 'rust',
  yml: 'yaml', md: 'markdown', objc: 'objectivec', 'objective-c': 'objectivec',
  kt: 'kotlin', cs: 'csharp', 'c#': 'csharp', 'c++': 'cpp', golang: 'go',
  html: 'xml', vue: 'xml', svg: 'xml', plist: 'xml', jsonc: 'json', json5: 'json',
  dockerfile: 'dockerfile', docker: 'dockerfile', toml: 'ini', env: 'bash',
};

// 代码块信息串可能是 "ts"、"ts title=a.ts"、"ts:src/a.ts"、"src/a.ts" 这几种写法。
function parseInfo(info) {
  const raw = info.trim();
  if (!raw) return { lang: '', label: '' };
  let [first, ...rest] = raw.split(/\s+/);
  let file = '';
  const colon = first.indexOf(':');
  if (colon > 0) {
    file = first.slice(colon + 1);
    first = first.slice(0, colon);
  } else if (/[./]/.test(first) && !hljs.getLanguage(first)) {
    file = first;
    const ext = first.split('.').pop();
    first = ext && ext !== first ? ext : '';
  }
  const title = rest.join(' ').match(/(?:title|file|filename)=["']?([^"'\s]+)/);
  if (title) file = title[1];
  const lang = first.toLowerCase();
  return { lang: LANG_ALIASES[lang] ?? lang, label: file || first };
}

function highlight(code, lang) {
  if (!lang || !hljs.getLanguage(lang)) return escapeHtml(code);
  return cache.get(lang + '\u0000' + code, () => {
    try {
      return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
    } catch {
      return escapeHtml(code);
    }
  });
}

function renderTex(content, displayMode) {
  return cache.get((displayMode ? 'D' : 'I') + content, () =>
    katex.renderToString(content, { displayMode, throwOnError: false, output: 'html', strict: 'ignore' }),
  );
}

// ---------- 提示块：GitHub 的 > [!NOTE] 和 Obsidian 的 > [!tip]- 标题 ----------

const ICONS = {
  note: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
  tip: '<path d="M9 18h6M10 22h4M12 2a7 7 0 0 0-4 12.7c.6.5 1 1.3 1 2.1V17h6v-.2c0-.8.4-1.6 1-2.1A7 7 0 0 0 12 2z"/>',
  important: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/><path d="M12 7v3M12 13h.01"/>',
  warning: '<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>',
  caution: '<path d="M7.86 2h8.28L22 7.86v8.28L16.14 22H7.86L2 16.14V7.86z"/><path d="M12 8v4M12 16h.01"/>',
  success: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
  question: '<circle cx="12" cy="12" r="10"/><path d="M9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3M12 17h.01"/>',
  example: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
  quote: '<path d="M7 7h4v4c0 3-2 5-4 5M15 7h4v4c0 3-2 5-4 5"/>',
};

const CALLOUT_KIND = {
  note: 'note', info: 'note', todo: 'note',
  tip: 'tip', hint: 'tip', abstract: 'tip', summary: 'tip', tldr: 'tip',
  important: 'important',
  warning: 'warning', attention: 'warning',
  caution: 'caution', danger: 'caution', error: 'caution', failure: 'caution', fail: 'caution', missing: 'caution', bug: 'caution',
  success: 'success', check: 'success', done: 'success',
  question: 'question', help: 'question', faq: 'question',
  example: 'example',
  quote: 'quote', cite: 'quote',
};

const CALLOUT_TITLE = {
  note: '说明', tip: '提示', important: '重要', warning: '警告', caution: '危险',
  success: '完成', question: '问题', example: '示例', quote: '引用',
};

const CALLOUT_RE = /^\[!([A-Za-z][\w-]*)\]([+-]?)(?:[ \t]+(.*))?$/;

function calloutPlugin(md) {
  md.core.ruler.after('block', 'callout', (state) => {
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== 'blockquote_open') continue;
      const para = tokens[i + 1];
      const inline = tokens[i + 2];
      if (para?.type !== 'paragraph_open' || inline?.type !== 'inline') continue;
      const nl = inline.content.indexOf('\n');
      const firstLine = (nl === -1 ? inline.content : inline.content.slice(0, nl)).trim();
      const m = CALLOUT_RE.exec(firstLine);
      if (!m) continue;
      const name = m[1].toLowerCase();
      const kind = CALLOUT_KIND[name] ?? 'note';
      const meta = { kind, fold: m[2], title: m[3]?.trim() || CALLOUT_TITLE[kind] };
      tokens[i].meta = meta;
      inline.content = nl === -1 ? '' : inline.content.slice(nl + 1);
      if (!inline.content.trim()) {
        para.hidden = true;
        tokens[i + 3].hidden = true;
      }
      for (let j = i + 1, depth = 1; j < tokens.length; j++) {
        if (tokens[j].type === 'blockquote_open') depth++;
        else if (tokens[j].type === 'blockquote_close' && --depth === 0) {
          tokens[j].meta = meta;
          break;
        }
      }
    }
  });

  const open = md.renderer.rules.blockquote_open ?? ((t, i, o, e, self) => self.renderToken(t, i, o));
  const close = md.renderer.rules.blockquote_close ?? ((t, i, o, e, self) => self.renderToken(t, i, o));

  md.renderer.rules.blockquote_open = (tokens, idx, options, env, self) => {
    const meta = tokens[idx].meta;
    if (!meta) return open(tokens, idx, options, env, self);
    const icon = `<svg class="callout-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[meta.kind]}</svg>`;
    const title = `${icon}<span>${md.renderInline(meta.title, {})}</span>`;
    const attrs = self.renderAttrs(tokens[idx]);
    if (meta.fold) {
      return `<details class="callout callout-${meta.kind}"${attrs}${meta.fold === '+' ? ' open' : ''}><summary class="callout-title">${title}</summary><div class="callout-body">\n`;
    }
    return `<div class="callout callout-${meta.kind}"${attrs}><p class="callout-title">${title}</p><div class="callout-body">\n`;
  };
  md.renderer.rules.blockquote_close = (tokens, idx, options, env, self) => {
    const meta = tokens[idx].meta;
    if (!meta) return close(tokens, idx, options, env, self);
    return meta.fold ? '</div></details>\n' : '</div></div>\n';
  };
}

// ---------- [[双链]] 和 ![[嵌入]] ----------

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|avif|heic|bmp)$/i;

function wikiLinkPlugin(md) {
  md.inline.ruler.before('image', 'wikilink', (state, silent) => {
    const src = state.src;
    let pos = state.pos;
    const embed = src.charCodeAt(pos) === 0x21; // !
    if (embed) pos++;
    if (src.charCodeAt(pos) !== 0x5b || src.charCodeAt(pos + 1) !== 0x5b) return false;
    const end = src.indexOf(']]', pos + 2);
    if (end < 0) return false;
    const inner = src.slice(pos + 2, end);
    if (!inner.trim() || /[\n[\]]/.test(inner)) return false;
    if (!silent) {
      const bar = inner.indexOf('|');
      const target = (bar < 0 ? inner : inner.slice(0, bar)).trim();
      const alias = (bar < 0 ? target : inner.slice(bar + 1)).trim();
      const token = state.push('wikilink', '', 0);
      token.meta = { target, alias, embed };
    }
    state.pos = end + 2;
    return true;
  });

  md.renderer.rules.wikilink = (tokens, idx) => {
    const { target, alias, embed } = tokens[idx].meta;
    const [page, hash] = target.split('#');
    if (embed && IMAGE_EXT.test(page)) {
      return `<img src="${escapeHtml(encodeURI(page))}" alt="${escapeHtml(alias)}">`;
    }
    const href = encodeURI(page) + (hash ? '#' + slugify(hash) : '');
    return `<a class="wikilink" href="${escapeHtml(href)}" data-wiki="${escapeHtml(page)}">${escapeHtml(alias)}</a>`;
  };
}

// ---------- 文件头：YAML (---) 和 TOML (+++) ----------

function frontMatterPlugin(md) {
  md.block.ruler.before('table', 'front_matter', (state, startLine, endLine, silent) => {
    // 增量解析时窗口的第 0 行不一定是文档开头，那里的 --- 只是分隔线。
    if (startLine !== 0 || state.blkIndent !== 0 || state.env.atDocStart === false) return false;
    const fence = state.src.slice(state.bMarks[0], state.eMarks[0]).trimEnd();
    if (fence !== '---' && fence !== '+++') return false;
    if (endLine < 2 || state.isEmpty(1)) return false;
    let line = 1;
    for (; line < endLine; line++) {
      const text = state.src.slice(state.bMarks[line], state.eMarks[line]).trimEnd();
      if (text === fence || (fence === '---' && text === '...')) break;
    }
    if (line >= endLine) return false;
    if (silent) return true;
    const token = state.push('front_matter', '', 0);
    token.content = state.src.slice(state.bMarks[1], state.bMarks[line]);
    token.markup = fence;
    token.map = [0, line + 1];
    state.line = line + 1;
    return true;
  });

  md.renderer.rules.front_matter = (tokens, idx) => renderFrontMatter(tokens[idx].content, tokens[idx].markup);
}

function unquote(v) {
  const s = v.trim();
  if (s.length >= 2 && (s[0] === '"' || s[0] === "'") && s.at(-1) === s[0]) return s.slice(1, -1);
  return s;
}

function renderValue(v) {
  const s = v.trim();
  const inlineList = /^\[(.*)\]$/.exec(s);
  const items = inlineList
    ? inlineList[1].split(',').map(unquote).filter(Boolean)
    : s.includes('\n') && s.split('\n').every((l) => l.startsWith('- '))
      ? s.split('\n').map((l) => unquote(l.slice(2)))
      : null;
  if (items) return items.map((x) => `<span class="chip">${escapeHtml(x)}</span>`).join('');
  return escapeHtml(unquote(s)).replace(/\n/g, '<br>');
}

function renderFrontMatter(content, fence) {
  const rows = [];
  const keyRe = fence === '+++' ? /^([\w.-]+)\s*=\s*(.*)$/ : /^([^\s:#-][^:]*):(?:\s+(.*))?$/;
  let ok = true;
  for (const line of content.replace(/\n$/, '').split('\n')) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    const m = keyRe.exec(line);
    if (m) {
      rows.push([m[1].trim(), (m[2] ?? '').trim()]);
    } else if (/^\s+\S/.test(line) && rows.length) {
      const last = rows[rows.length - 1];
      last[1] += (last[1] ? '\n' : '') + line.trim();
    } else {
      ok = false;
      break;
    }
  }
  const lang = fence === '+++' ? 'ini' : 'yaml';
  const body = ok && rows.length
    ? `<table>${rows.map(([k, v]) => `<tr><th>${escapeHtml(k)}</th><td>${renderValue(v)}</td></tr>`).join('')}</table>`
    : `<pre><code class="hljs">${highlight(content, lang)}</code></pre>`;
  return `<details class="front-matter" open><summary>属性</summary>${body}</details>\n`;
}

// ---------- 标题锚点 ----------

function slugify(text) {
  return text
    .trim()
    .toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s+/g, '-');
}

// 重名标题的 -1、-2 后缀在预览里统一补（见 preview.js），这样每块的 HTML 不依赖全篇，能增量复用。
function headingIdPlugin(md) {
  md.core.ruler.push('heading_ids', (state) => {
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== 'heading_open') continue;
      const text = tokens[i + 1].children
        .filter((t) => t.type === 'text' || t.type === 'code_inline')
        .map((t) => t.content)
        .join('');
      // 不直接写 id：最终 id 要按全篇去重（见 assignHeadingIds），由预览写到 DOM 上。
      // 用 data-slug 标出这是 Markdown 标题，原生 HTML 里作者自己写的 <h2 id="…"> 不受影响。
      tokens[i].attrSet('data-slug', slugify(text) || 'section');
    }
  });
}

// ---------- 代码块：语言标签、文件名、复制按钮；mermaid 留给预览层 ----------

function fencePlugin(md) {
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const { lang, label } = parseInfo(token.info);
    const attrs = self.renderAttrs(token);
    if (lang === 'mermaid') {
      return `<div class="mermaid-block"${attrs}><pre class="mermaid-src">${escapeHtml(token.content)}</pre></div>\n`;
    }
    const code = highlight(token.content, lang);
    const head = `<div class="code-head"><span class="code-lang">${escapeHtml(label)}</span><button class="copy-btn" type="button">复制</button></div>`;
    return `<div class="code-block"${attrs}>${head}<pre><code class="hljs${lang ? ' language-' + escapeHtml(lang) : ''}">${code}</code></pre></div>\n`;
  };
}

// breaks: true —— 回车一次就换行（和 Obsidian、GitHub 评论一样），空一行才分段。
// 标准 Markdown 会把单个换行并成一段、中间加个空格：边写边看时左右对不上，中文句子里还会多出空格。
const md = new MarkdownIt({ html: true, linkify: true, breaks: true })
  .use(frontMatterPlugin)
  .use(footnote)
  .use(tasklist, { disabled: true, label: false })
  .use(mark)
  .use(tex, { delimiters: 'all', mathFence: true, render: renderTex })
  .use(calloutPlugin)
  .use(wikiLinkPlugin)
  .use(headingIdPlugin)
  .use(fencePlugin);

// 链接里的本地路径（含中文、空格）不要被 markdown-it 拒掉。
md.validateLink = (url) => !/^(javascript|vbscript):/i.test(url.trim());

// 表格单元格、列表项等嵌套块也带上相对行号，滚动对照能对得更细。
const NESTED_TAGS = new Set([
  'paragraph_open', 'heading_open', 'list_item_open', 'blockquote_open', 'tr_open',
  'fence', 'code_block', 'html_block', 'hr', 'math_block', 'table_open', 'bullet_list_open', 'ordered_list_open',
]);

const VOID_TAGS = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
const TAG_RE = /<(\/?)([a-zA-Z][\w-]*)\b[^>]*?(\/?)>/g;

// HTML 块里没闭合的标签数，比如 <details> 开头、</details> 在几段之后。
function htmlDepth(html) {
  let depth = 0;
  for (const m of html.matchAll(TAG_RE)) {
    const tag = m[2].toLowerCase();
    if (VOID_TAGS.has(tag) || m[3]) continue;
    depth += m[1] ? -1 : 1;
  }
  return depth;
}

// Markdown 标题的 slug，顺序和预览里 querySelectorAll('[data-slug]') 一致。
const SLUG_RE = /\sdata-slug="([^"]*)"/g;
// 块里原生 HTML（和脚注）已经占用的锚点：任何标签的 id，以及 <a name>。
// 先找标签再看属性：渲染结果里正文和代码里的 < 都已转义，不会被当成标签。
// 属性名不分大小写，值可以带双引号、单引号或不带引号，= 两边可以有空格。
const OPEN_TAG_RE = /<([a-zA-Z][\w:-]*)(\s[^<>]*)?\/?>/g;
const ANCHOR_ATTR_RE = /(?:^|\s)(id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi;
const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", '#39': "'" };
const decodeAttr = (v) => v.replace(/&(amp|lt|gt|quot|apos|#39);/g, (_, e) => ENTITIES[e]);

function htmlAnchors(html) {
  const anchors = [];
  for (const tag of html.matchAll(OPEN_TAG_RE)) {
    if (!tag[2]) continue;
    const isLink = tag[1].toLowerCase() === 'a';
    for (const attr of tag[2].matchAll(ANCHOR_ATTR_RE)) {
      if (attr[1].toLowerCase() === 'name' && !isLink) continue;
      const value = decodeAttr(attr[2] ?? attr[3] ?? attr[4]);
      // 自动标题的 id 由预览写上，渲染结果里只有 data-slug，这里只会拿到原生 HTML 和脚注的。
      if (value) anchors.push(value);
    }
  }
  return anchors;
}

function parseBlocks(src, env, lineCount) {
  const tokens = md.parse(src, env);
  const blocks = [];
  let chunkStart = 0;
  let depth = 0;
  let htmlOpen = 0;
  let lastEnd = 0;

  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const start = tokens[chunkStart].map?.[0] ?? lastEnd;
    if (i > chunkStart && token.map && NESTED_TAGS.has(token.type)) {
      token.attrSet('data-r', String(token.map[0] - start));
    }
    depth += token.nesting;
    if (depth === 0 && token.type === 'html_block') htmlOpen = Math.max(0, htmlOpen + htmlDepth(token.content));
    if (depth !== 0 || (htmlOpen > 0 && i < tokens.length - 1)) continue;
    const chunk = tokens.slice(chunkStart, i + 1);
    const end = token.map?.[1] ?? tokens[chunkStart].map?.[1] ?? lineCount;
    // 任务列表插件给复选框编了全篇递增的 id，去掉，块的 HTML 才不依赖它在全篇的位置。
    const html = md.renderer.render(chunk, md.options, env).replace(/ id="task-item-\d+"/g, '');
    const slugs = Array.from(html.matchAll(SLUG_RE), (m) => m[1]);
    const ids = htmlAnchors(html);
    blocks.push({ html, start, end: Math.max(end, lastEnd), slugs, ids });
    lastEnd = end;
    chunkStart = i + 1;
  }
  return blocks;
}

// 上一次渲染的结果，供增量解析使用。
let previous = null;

// 脚注、引用式链接定义是全篇共享的，有它们就整篇重新解析。
// 链接定义可以写在引用块、列表里，用正则认不全，以 markdown-it 的解析结果（env.references / env.footnotes）为准；
// 正则只用来认还没有定义的脚注引用 [^1]（它不会出现在 env 里，但补上定义后就会变）。
const FOOTNOTE_REF = /\[\^[^\]\n]+\]/;
const hasGlobal = (env) => !!env.references || !!env.footnotes;

// 小文档整篇解析也只要几毫秒，增量只用在大文档上。
const INCREMENTAL_MIN = 60_000;

/**
 * 只重新解析改动附近的几个块，其余块原样复用。做不到时返回 null，交给整篇解析。
 */
function renderIncremental(src, lines) {
  const prev = previous;
  // 上一版有脚注或引用定义也要整篇重来：删掉定义后，用到它的那些块也得变。
  if (!prev || prev.global || src.length < INCREMENTAL_MIN || prev.blocks.length < 3) return null;
  const old = prev.lines;
  const limit = Math.min(old.length, lines.length);
  let p = 0;
  while (p < limit && old[p] === lines[p]) p++;
  if (p === old.length && p === lines.length) return { blocks: prev.blocks, totalLines: lines.length };
  let q = 0;
  while (q < limit - p && old[old.length - 1 - q] === lines[lines.length - 1 - q]) q++;
  const oldChangedEnd = old.length - q;
  const delta = lines.length - old.length;

  const blocks = prev.blocks;
  // 改动所在的块，再往前多带一块（改动可能让它和前一块连起来）。
  let i = blocks.findIndex((b) => b.end > p);
  if (i < 0) i = blocks.length - 1;
  i = Math.max(0, i - 1);
  // 改动结束处所在的块，再往后多带一块。
  let j = i;
  while (j < blocks.length - 1 && blocks[j + 1].start < oldChangedEnd) j++;
  j = Math.min(blocks.length - 1, j + 1);

  const startLine = blocks[i].start;
  const oldEnd = j === blocks.length - 1 ? old.length : blocks[j].end;
  const newEnd = oldEnd + delta;
  if (newEnd < lines.length - q || newEnd < startLine) return null;

  const windowText = lines.slice(startLine, newEnd).join('\n');
  if (FOOTNOTE_REF.test(windowText)) return null;
  const windowEnv = { atDocStart: startLine === 0 };
  const fresh = parseBlocks(windowText, windowEnv, newEnd - startLine);
  // 改动里新写了链接定义或脚注：可能影响窗口外用到它的地方。
  if (hasGlobal(windowEnv)) return null;
  // 窗口最后一块是改动后面原样没动的那块。重新解析出来和原来一模一样，说明解析已经收敛，
  // 后面的块都能直接复用；不一样（比如新写了一个没闭合的代码块，把后面吞了）就整篇重来。
  if (j < blocks.length - 1) {
    const last = fresh.at(-1);
    const was = blocks[j];
    // 只比内容和起点：块末尾的空行可能被窗口边界截掉（比如列表），结束行以原来的为准。
    if (!last || last.html !== was.html || last.start + startLine !== was.start + delta) return null;
    last.end = was.end + delta - startLine;
  }
  for (const b of fresh) {
    b.start += startLine;
    b.end += startLine;
  }
  const tail = blocks.slice(j + 1).map((b) => (delta ? { ...b, start: b.start + delta, end: b.end + delta } : b));
  return { blocks: blocks.slice(0, i).concat(fresh, tail), totalLines: lines.length, incremental: true };
}

/**
 * 把 Markdown 渲染成顶层块数组。
 * 每块：html（不含绝对行号，内容不变 html 就不变，可以复用 DOM）、start / end（0 起的源码行号）。
 */
export function renderBlocks(src) {
  const lines = src.split('\n');
  let result = FOOTNOTE_REF.test(src) ? null : renderIncremental(src, lines);
  let global = false;
  if (!result) {
    const env = {};
    result = { blocks: parseBlocks(src, env, lines.length), totalLines: lines.length };
    global = hasGlobal(env) || FOOTNOTE_REF.test(src);
    // 增量解析时缓存只进不出，整篇解析后再清掉用不到的。
    cache.rotate();
  }
  previous = { lines, blocks: result.blocks, global };
  return result;
}

/**
 * 全篇的标题 id，返回每块的 id 列表。
 * 和 GitHub 一样：重名的依次加 -1、-2；生成的 id 如果已经被占用（另一个叫「a-1」的标题、作者手写的 id），继续往后加。
 * 按全篇的块算，不看页面上哪些块有内容，所以删标题、滚动都不会让编号乱掉。
 */
export function assignHeadingIds(blocks) {
  const used = new Set();
  for (const block of blocks) for (const id of block.ids) used.add(id);
  const counts = new Map();
  return blocks.map((block) =>
    block.slugs.map((slug) => {
      let n = counts.get(slug) ?? 0;
      let id = n ? `${slug}-${n}` : slug;
      while (used.has(id)) id = `${slug}-${++n}`;
      counts.set(slug, n + 1);
      used.add(id);
      return id;
    }),
  );
}

/**
 * 锚点在第几块：Markdown 标题看最终 id（headingIds 是 assignHeadingIds 的结果），原生 HTML 和脚注看 block.ids。
 * 大文档里没显示出来的块，DOM 里还找不到这个锚点，要靠它先定位到块。找不到返回 -1。
 */
export function anchorBlockIndex(blocks, headingIds, id) {
  for (let k = 0; k < blocks.length; k++) {
    if (headingIds[k]?.includes(id) || blocks[k].ids.includes(id)) return k;
  }
  return -1;
}

/** 换文档时调用，避免拿上一个文档做增量。 */
export function resetBlocks() {
  previous = null;
}
