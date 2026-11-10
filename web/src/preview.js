// 预览页：按块增量更新 DOM、滚动对照、和原生端通信。

import { anchorBlockIndex, assignHeadingIds, renderBlocks, resetBlocks } from './markdown.js';

const root = document.getElementById('content');
const base = document.getElementById('doc-base');

/** 当前顶层块对应的元素，每个元素带 _html（渲染结果）、_l / _e（源码行范围）。 */
let current = [];
let totalLines = 1;
/** 当前文档全文，原生端只发改动的那一段过来。 */
let text = '';

const post = (message) => window.webkit?.messageHandlers?.silk?.postMessage(message);

// ---------- 渲染与 DOM 增量更新 ----------

function patch(blocks) {
  const old = current;
  const n = blocks.length;
  const o = old.length;

  let pre = 0;
  while (pre < n && pre < o && old[pre]._html === blocks[pre].html) pre++;
  let suf = 0;
  while (suf < n - pre && suf < o - pre && old[o - 1 - suf]._html === blocks[n - 1 - suf].html) suf++;

  // 中间段里内容没变、只是挪了位置的块也复用，图表和公式不用重画。
  const reusable = new Map();
  for (let i = pre; i < o - suf; i++) {
    const el = old[i];
    const list = reusable.get(el._html);
    list ? list.push(el) : reusable.set(el._html, [el]);
  }

  const next = old.slice(0, pre);
  const anchor = suf > 0 ? old[o - suf] : null;
  const created = [];
  for (let i = pre; i < n - suf; i++) {
    const block = blocks[i];
    let el = reusable.get(block.html)?.shift();
    if (!el) {
      el = document.createElement('div');
      // 大标题块上方多留点空（用 class 而不是 :has()，DOM 变动时样式重算便宜得多）。
      el.className = /^<h[123][ >]/.test(block.html) ? 'blk blk-h' : 'blk';
      el._html = block.html;
      el._htmlIds = block.ids; // 原生 HTML 和脚注的锚点，块没内容时靠它定位
      el._live = false;
      created.push(el);
    }
    root.insertBefore(el, anchor);
    next.push(el);
  }
  for (const list of reusable.values()) {
    for (const el of list) {
      el.remove();
      live.delete(el);
    }
  }
  for (let i = o - suf; i < o; i++) next.push(old[i]);

  for (let i = 0; i < n; i++) {
    const el = next[i];
    if (el._l !== blocks[i].start) {
      el._l = blocks[i].start;
      el.dataset.l = String(el._l);
    }
    el._e = blocks[i].end;
  }
  current = next;
  return created;
}

function render(source) {
  text = source;
  const t0 = performance.now();
  const atBottom = window.scrollY > 0 && window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
  const result = renderBlocks(source);
  const t1 = performance.now();
  totalLines = result.totalLines;
  const created = patch(result.blocks);
  updateHeadingIds(result.blocks);
  const t2 = performance.now();
  invalidateAnchors();
  root.classList.toggle('empty', current.length === 0);

  const wasVirtual = virtual;
  virtual = current.length > VIRTUAL_MIN;
  if (virtual) {
    if (live.size === 0) {
      for (const el of created) el.style.height = estimateHeight(el) + 'px';
      updateVirtual();
    } else {
      // 打字时改动的块就在视口附近：旁边的块有内容，就直接填上，不用量位置。
      // 其余的（比如粘贴了一大段）交给下一帧的 updateVirtual，和浏览器本来就要做的排版合在一起。
      const fresh = new Set(created);
      for (let k = 0; k < current.length; k++) {
        if (!fresh.has(current[k])) continue;
        let end = k;
        while (end + 1 < current.length && fresh.has(current[end + 1])) end++;
        const near = current[k - 1]?._live || current[end + 1]?._live;
        for (let m = k; m <= end; m++) {
          if (near) materialize(current[m]);
          else current[m].style.height = estimateHeight(current[m]) + 'px';
        }
        k = end;
      }
      scheduleVirtual();
    }
    timings.virtual = performance.now() - t2;
  } else {
    if (wasVirtual) for (const el of current) materialize(el);
    for (const el of created) materialize(el);
  }
  // AI 正在往文件末尾追加时，跟着滚到底。
  if (atBottom) {
    window.scrollTo(0, document.documentElement.scrollHeight);
    updateVirtual();
    window.scrollTo(0, document.documentElement.scrollHeight);
  }
  timings.parse = t1 - t0;
  timings.patch = t2 - t1;
  return { ms: performance.now() - t0, blocks: current.length };
}

/** 最近一次渲染各步骤的耗时，调试用。 */
const timings = {};

// ---------- 大文档虚拟化 ----------
// 块太多时，离视口远的块只留一个等高的空占位，滚到附近再填内容。
// 页面里的节点从几十万降到几千，打字、滚动时浏览器重排都很快。

const VIRTUAL_MIN = 600;
const NEAR = 2000; // 视口上下这么远以内的块要有内容
const FAR = 6000; // 超出这么远的块清空成占位
let virtual = false;
/** 有内容的块。 */
const live = new Set();

function estimateHeight(el) {
  return el._h ?? Math.max(24, (el._e - el._l) * 27);
}

function materialize(el) {
  if (el._live) return;
  el.style.height = '';
  el.innerHTML = el._html;
  el._live = true;
  live.add(el);
  applyHeadingIds(el);
  renderMermaid([el]);
  watchImages([el]);
}

function dematerialize(el, height) {
  el._h = height;
  el.style.height = height + 'px';
  el.textContent = '';
  el._live = false;
  live.delete(el);
  if (highlighted && !highlighted.isConnected) highlighted = null;
}

/** 填上视口附近的块、清掉远处的块。填内容时保持视口里第一块不动，画面不跳。 */
function updateVirtual() {
  if (!virtual || !current.length) return;
  const y = window.scrollY;
  const h = window.innerHeight;
  const from = Math.max(0, blockIndexForY(y - NEAR));
  const to = blockIndexForY(y + h + NEAR);
  const show = [];
  for (let k = from; k <= to; k++) if (!current[k]._live) show.push(current[k]);
  const hide = [];
  for (const el of live) {
    const r = el.getBoundingClientRect();
    if (r.bottom < -FAR || r.top > h + FAR) hide.push([el, r.height]);
  }
  if (!show.length && !hide.length) return;

  const anchor = current[Math.max(0, blockIndexForY(y))];
  const before = anchor.getBoundingClientRect().top;
  for (const [el, height] of hide) dematerialize(el, height);
  for (const el of show) materialize(el);
  invalidateAnchors();
  const shift = anchor.getBoundingClientRect().top - before;
  if (Math.abs(shift) > 0.5) {
    suppressScrollUntil = performance.now() + 50;
    window.scrollBy(0, shift);
  }
}

let virtualFrame = 0;
const scheduleVirtual = () => {
  if (!virtual || virtualFrame) return;
  virtualFrame = requestAnimationFrame(() => {
    virtualFrame = 0;
    updateVirtual();
  });
};
window.addEventListener('scroll', scheduleVirtual, { passive: true });
window.addEventListener('resize', scheduleVirtual);

/** 打印前把所有块都填上内容。 */
function materializeAll() {
  for (const el of current) materialize(el);
  invalidateAnchors();
}
window.addEventListener('beforeprint', materializeAll);

/** 跳到页内锚点：块还没内容时先按渲染结果找到它所在的块。 */
function scrollToId(id) {
  // 和浏览器一样：先找 id，再找 <a name>。
  const find = () => document.getElementById(id) ?? document.querySelector(`a[name="${CSS.escape(id)}"]`);
  let target = find();
  if (!target && virtual) {
    const k = anchorBlockIndex(current.map((b) => ({ ids: b._htmlIds })), current.map((b) => b._ids), id);
    const el = current[k];
    if (el) {
      window.scrollTo(0, docTop(el));
      updateVirtual();
      target = find();
    }
  }
  if (!target) return;
  target.scrollIntoView({ block: 'start' });
  if (virtual) {
    // 周围的占位填上内容后高度会变，再对齐一次；下一帧滚动触发的更新之后也再对一次。
    updateVirtual();
    target.scrollIntoView({ block: 'start' });
    requestAnimationFrame(() => {
      updateVirtual();
      if (target.isConnected) target.scrollIntoView({ block: 'start' });
    });
  }
}

// ---------- 标题 id ----------
// 每块记着自己标题的最终 id（_ids），块有内容时写到 DOM 上。

// 只管 Markdown 生成的标题；原生 HTML 里作者自己写 id 的标题原样保留。
const HEADINGS = '[data-slug]';

function updateHeadingIds(blocks) {
  const ids = assignHeadingIds(blocks);
  for (let k = 0; k < current.length; k++) {
    const el = current[k];
    const next = ids[k];
    if (el._ids && el._ids.length === next.length && el._ids.every((id, i) => id === next[i])) continue;
    el._ids = next;
    if (el._live) applyHeadingIds(el);
  }
}

function applyHeadingIds(el) {
  if (!el._ids?.length) return;
  const headings = el.querySelectorAll(HEADINGS);
  for (let i = 0; i < headings.length && i < el._ids.length; i++) {
    if (headings[i].id !== el._ids[i]) headings[i].id = el._ids[i];
  }
}

// ---------- Mermaid：文档里有图才加载 ----------

let mermaidPromise = null;
let mermaidSeq = 0;
const mermaidCache = new Map();
const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');

function loadMermaid() {
  mermaidPromise ??= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'silk://app/mermaid.min.js';
    script.onload = () => resolve(window.mermaid);
    script.onerror = reject;
    document.head.append(script);
  }).then((mermaid) => {
    initMermaid(mermaid);
    return mermaid;
  });
  return mermaidPromise;
}

function initMermaid(mermaid) {
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: darkQuery.matches ? 'dark' : 'default',
    fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif',
  });
}

// 图表滚到屏幕附近才画，几百张图的文档也不会一打开就卡住。
const mermaidObserver = new IntersectionObserver(
  (entries) => {
    const visible = entries.filter((e) => e.isIntersecting).map((e) => e.target);
    for (const block of visible) mermaidObserver.unobserve(block);
    if (visible.length) drawMermaid(visible);
  },
  { rootMargin: '1200px 0px' },
);

function renderMermaid(elements, force = false) {
  for (const el of elements) {
    for (const block of el.querySelectorAll('.mermaid-block')) {
      if (block._svgDone && !force) continue;
      block._src ??= block.textContent;
      block._svgDone = false;
      mermaidObserver.observe(block);
    }
  }
}

let mermaidQueue = Promise.resolve();

function drawMermaid(targets) {
  mermaidQueue = mermaidQueue.then(() => drawMermaidNow(targets));
}

async function drawMermaidNow(targets) {
  targets = targets.filter((block) => block.isConnected && !block._svgDone);
  if (!targets.length) return;
  let mermaid;
  try {
    mermaid = await loadMermaid();
  } catch {
    return;
  }
  for (const block of targets) {
    const cached = mermaidCache.get(block._src);
    if (cached) {
      block.innerHTML = cached;
      block._svgDone = true;
      continue;
    }
    const id = `mmd-${++mermaidSeq}`;
    try {
      const { svg } = await mermaid.render(id, block._src);
      block.innerHTML = svg;
      block.classList.remove('error');
      if (mermaidCache.size > 200) mermaidCache.clear();
      mermaidCache.set(block._src, svg);
    } catch (error) {
      document.getElementById('d' + id)?.remove();
      block.classList.add('error');
      block.innerHTML = `<pre class="mermaid-src"></pre><p class="mermaid-error"></p>`;
      block.firstChild.textContent = block._src;
      block.lastChild.textContent = String(error?.message ?? error).split('\n')[0];
    }
    block._svgDone = true;
    // 每画一张让出一次主线程，滚动和打字不被堵住。
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  invalidateAnchors();
}

darkQuery.addEventListener('change', () => {
  if (!mermaidPromise) return;
  mermaidCache.clear();
  mermaidPromise.then((mermaid) => {
    initMermaid(mermaid);
    renderMermaid(current, true);
  });
});

function watchImages(elements) {
  for (const el of elements) {
    for (const img of el.querySelectorAll('img')) {
      if (!img.complete) img.addEventListener('load', invalidateAnchors, { once: true });
    }
  }
}

// ---------- 行号 ↔ 位置 ----------
// 不给整篇建位置表（大文档里会逼着浏览器把所有块排一遍），只量用到的那一两块。

let layoutEpoch = 0;

function invalidateAnchors() {
  layoutEpoch++;
}

const docTop = (el) => el.getBoundingClientRect().top + window.scrollY;

/** 行号所在的块：_l 不大于 line 的最后一块。 */
function blockIndexForLine(line) {
  let lo = 0;
  let hi = current.length - 1;
  if (hi < 0) return -1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (current[mid]._l <= line) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/** 位置所在的块：顶部不低于 y 的最后一块。 */
function blockIndexForY(y) {
  let lo = 0;
  let hi = current.length - 1;
  if (hi < 0) return -1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (docTop(current[mid]) <= y) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/** 一块里的锚点（块本身 + 表格行、列表项等），行号和位置都单调递增。按排版版本缓存。 */
function blockAnchors(el) {
  if (el._epoch === layoutEpoch && el._anchors) return el._anchors;
  const list = [{ line: el._l, top: docTop(el), el }];
  for (const sub of el.querySelectorAll('[data-r]')) {
    const r = Number(sub.dataset.r);
    if (r <= 0 || sub.offsetParent === null) continue;
    const a = { line: el._l + r, top: docTop(sub), el: sub };
    const last = list[list.length - 1];
    // 折叠或隐藏的元素会破坏单调性，剔掉。
    if (a.line > last.line && a.top >= last.top) list.push(a);
  }
  el._anchors = list;
  el._epoch = layoutEpoch;
  return list;
}

/** 块 k 之后的下一个锚点：下一块的顶部，或者页面底部。 */
function nextAnchor(k) {
  const next = current[k + 1];
  if (next) return { line: next._l, top: docTop(next) };
  return { line: Math.max(totalLines, current[k]._e), top: document.documentElement.scrollHeight };
}

function lineToY(line) {
  const k = blockIndexForLine(line);
  if (k < 0) return 0;
  const list = blockAnchors(current[k]);
  let i = 0;
  while (i + 1 < list.length && list[i + 1].line <= line) i++;
  const a = list[i];
  const b = list[i + 1] ?? nextAnchor(k);
  if (line <= a.line || b.line <= a.line) return a.top;
  return a.top + Math.min(1, (line - a.line) / (b.line - a.line)) * (b.top - a.top);
}

function yToLine(y) {
  const k = blockIndexForY(y);
  if (k < 0) return 0;
  const list = blockAnchors(current[k]);
  let i = 0;
  while (i + 1 < list.length && list[i + 1].top <= y) i++;
  const a = list[i];
  const b = list[i + 1] ?? nextAnchor(k);
  if (y <= a.top || b.top <= a.top) return a.line;
  return a.line + Math.min(1, (y - a.top) / (b.top - a.top)) * (b.line - a.line);
}

new ResizeObserver(invalidateAnchors).observe(root);
root.addEventListener('toggle', invalidateAnchors, true);

// ---------- 滚动同步 ----------

let suppressScrollUntil = 0;
let scrollFrame = 0;

window.addEventListener(
  'scroll',
  () => {
    if (performance.now() < suppressScrollUntil || scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      post({ type: 'scroll', line: yToLine(window.scrollY) });
    });
  },
  { passive: true },
);

function scrollToLine(line) {
  suppressScrollUntil = performance.now() + 100;
  // 第 0 行就是页面顶部，连同上边距一起显示。
  const go = () => window.scrollTo(0, line <= 0 ? 0 : Math.max(0, lineToY(line)));
  go();
  if (virtual) {
    // 占位的高度是估的，填上内容后再对一次。
    updateVirtual();
    go();
    updateVirtual();
  }
}

// ---------- 光标所在块高亮 ----------

let highlighted = null;

/** 某行对应的元素：所在块，或块里更细的表格行、列表项。落在两个块之间的空行上时为 null。 */
function elementForLine(line) {
  const k = blockIndexForLine(line);
  const blk = current[k];
  if (!blk || line < blk._l || line >= blk._e) return null;
  let target = blk;
  let best = 0;
  const rel = line - blk._l;
  for (const sub of blk.querySelectorAll('[data-r]')) {
    const r = Number(sub.dataset.r);
    if (r > 0 && r <= rel && r >= best && sub.offsetParent !== null) {
      best = r;
      target = sub;
    }
  }
  return target;
}

function highlightLine(line) {
  const target = elementForLine(line);
  if (highlighted === target) return;
  highlighted?.classList.remove('cursor-block');
  target?.classList.add('cursor-block');
  highlighted = target;
}

// ---------- 搜索结果：滚到那一行并闪一下 ----------

function reveal(line) {
  suppressScrollUntil = performance.now() + 150;
  // 命中的那一行放在视口上方四分之一处，上面留点上下文。
  const go = () => window.scrollTo(0, Math.max(0, lineToY(line) - window.innerHeight / 4));
  go();
  if (virtual) {
    updateVirtual();
    go();
    updateVirtual();
  }
  const target = elementForLine(line) ?? current[blockIndexForLine(line)];
  if (!target) return;
  target.classList.remove('search-flash');
  void target.offsetWidth; // 重新开始动画
  target.classList.add('search-flash');
  setTimeout(() => target.classList.remove('search-flash'), 1700);
}

// ---------- 导出：完整的 HTML 正文 ----------

/** 把整篇渲染好（大文档的占位块、还没画的图表都补上），返回干净的正文 HTML。图表一律用浅色主题。 */
async function exportHTML() {
  materializeAll();
  const clone = root.cloneNode(true);
  clone.className = 'markdown-body';

  // 图表：克隆出来的节点没有 _src，按顺序和原来的对上。
  const sources = [...root.querySelectorAll('.mermaid-block')].map((b) => b._src ?? b.textContent);
  const blocks = [...clone.querySelectorAll('.mermaid-block')];
  if (blocks.length) {
    let mermaid = null;
    try {
      mermaid = await loadMermaid();
    } catch {}
    if (mermaid) {
      const job = async () => {
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default', fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif' });
        try {
          for (let i = 0; i < blocks.length; i++) {
            const id = `mmd-x${++mermaidSeq}`;
            try {
              const { svg } = await mermaid.render(id, sources[i]);
              blocks[i].innerHTML = svg;
              blocks[i].classList.remove('error');
            } catch (error) {
              document.getElementById('d' + id)?.remove();
              blocks[i].classList.add('error');
              blocks[i].innerHTML = '<pre class="mermaid-src"></pre>';
              blocks[i].firstChild.textContent = sources[i];
            }
          }
        } finally {
          initMermaid(mermaid);
        }
      };
      const run = mermaidQueue.then(job);
      mermaidQueue = run.catch(() => {});
      await run;
    }
  }

  for (const el of clone.querySelectorAll('.copy-btn')) el.remove();
  // 折叠的内容展开：导出的 PDF 里点不开。
  for (const el of clone.querySelectorAll('details')) el.open = true;
  for (const el of clone.querySelectorAll('.cursor-block, .search-flash')) el.classList.remove('cursor-block', 'search-flash');
  for (const el of clone.querySelectorAll('[data-l]')) el.removeAttribute('data-l');
  for (const el of clone.querySelectorAll('[style]')) if (el.classList.contains('blk')) el.removeAttribute('style');
  // 本地图片换成绝对地址（silk-file:///…），原生端再把它嵌进文件里。
  for (const img of clone.querySelectorAll('img[src]')) img.setAttribute('src', img.src);
  for (const el of clone.querySelectorAll('video[src], source[src]')) el.setAttribute('src', el.src);

  const h1 = clone.querySelector('h1');
  return {
    html: clone.innerHTML,
    title: h1 ? h1.textContent.trim() : '',
    math: !!clone.querySelector('.katex'),
  };
}

// ---------- 点击：链接、复制、点块跳到源码 ----------

function lineOf(node) {
  const el = node.closest?.('[data-r], .blk');
  if (!el) return null;
  const blk = el.closest('.blk');
  return blk._l + (el === blk ? 0 : Number(el.dataset.r));
}

document.addEventListener('click', (event) => {
  const link = event.target.closest('a[href]');
  if (link) {
    event.preventDefault();
    const raw = link.getAttribute('href');
    if (raw.startsWith('#')) {
      scrollToId(decodeURIComponent(raw.slice(1)));
      return;
    }
    post({ type: 'link', href: link.href, wiki: link.dataset.wiki ?? null });
    return;
  }

  const copy = event.target.closest('.copy-btn');
  if (copy) {
    const code = copy.closest('.code-block')?.querySelector('code')?.textContent ?? '';
    post({ type: 'copy', text: code });
    copy.textContent = '已复制';
    setTimeout(() => (copy.textContent = '复制'), 1200);
    return;
  }

  if (document.body.dataset.mode !== 'split') return;
  if (!window.getSelection().isCollapsed) return;
  if (event.target.closest('summary, input')) return;
  const line = lineOf(event.target);
  if (line !== null) post({ type: 'click', line });
});

// ---------- 给原生端调用的接口 ----------

window.silk = {
  /** 换文件：清空重渲染，滚到指定行。 */
  setDocument(source, baseURL, line) {
    base.href = baseURL;
    for (const el of current) el.remove();
    current = [];
    live.clear();
    highlighted = null;
    resetBlocks();
    const stats = render(source);
    scrollToLine(line ?? 0);
    return stats;
  },
  /** 同一文件内容变了：增量更新，滚动位置不动。 */
  update(source) {
    return render(source);
  },
  /** 只传改动：从 start 起删掉 removed 个 UTF-16 单位，插入 inserted。 */
  edit(start, removed, inserted) {
    return render(text.slice(0, start) + inserted + text.slice(start + removed));
  },
  scrollToLine,
  scrollToId,
  materializeAll,
  timings,
  highlightLine,
  reveal,
  exportHTML,
  topLine() {
    return yToLine(window.scrollY);
  },
  setMode(mode) {
    document.body.dataset.mode = mode;
    if (mode !== 'split') {
      highlighted?.classList.remove('cursor-block');
      highlighted = null;
    }
  },
};

post({ type: 'ready' });
