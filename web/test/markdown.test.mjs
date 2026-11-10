// 运行：cd web && npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { anchorBlockIndex, assignHeadingIds, renderBlocks, resetBlocks } from '../src/markdown.js';

// 增量解析只用在大文档上，用这段填充把文档撑过阈值。
const filler = Array.from({ length: 3000 }, (_, i) => `段落 ${i} 一些文字，用来让文档超过增量阈值。`).join('\n\n');

const snapshot = (result) => result.blocks.map((b) => [b.html, b.start, b.end]);

/** 先渲染 before，再增量渲染 after，结果必须和整篇解析 after 一模一样。 */
function assertIncrementalMatches(before, after) {
  resetBlocks();
  renderBlocks(before);
  const incremental = renderBlocks(after);
  resetBlocks();
  const full = renderBlocks(after);
  assert.deepEqual(snapshot(incremental), snapshot(full));
  return { full, incremental };
}

test('文末「分隔线、正文、分隔线」改中间那段，不会被当成文件头', () => {
  const doc = filler + '\n\n---\n甲\n\n---\n';
  const { full } = assertIncrementalMatches(doc, doc.replace('\n甲\n', '\n甲改\n'));
  assert.ok(!full.blocks.some((b) => b.html.includes('front-matter')));
});

test('真正的文件头仍然识别', () => {
  const { blocks } = renderBlocks('---\ntitle: 你好\n---\n\n正文');
  assert.match(blocks[0].html, /front-matter/);
});

test('删除引用定义后，用到它的链接变回原文', () => {
  const doc = filler + '\n\n见 [苹果][a]。\n\n' + filler + '\n\n[a]: https://apple.com\n';
  const { full } = assertIncrementalMatches(doc, doc.replace('[a]: https://apple.com\n', ''));
  assert.ok(full.blocks.some((b) => b.html.includes('[苹果][a]')));
});

test('删除脚注定义后，脚注引用变回原文', () => {
  const doc = filler + '\n\n正文[^1]。\n\n' + filler + '\n\n[^1]: 脚注\n';
  assertIncrementalMatches(doc, doc.replace('[^1]: 脚注\n', ''));
});

test('各种结构变化下，增量结果和整篇解析一致', () => {
  const base = readFileSync(new URL('../../fixtures/showcase.md', import.meta.url), 'utf8')
    .replace(/\[\^1\]:.*\n/, '')
    .replace('[^1]', '');
  const big = base.slice(base.indexOf('# Silk')).repeat(400);
  const at = (k) => Math.floor(big.length * k);
  const edits = [
    (s) => s.replace('完。', '完。改'),
    (s) => s.slice(0, at(0.05)) + '\n```js\n' + s.slice(at(0.05)),
    (s) => s.replace('\n```js\n', '\n```js\n```\n'),
    (s) => s.slice(0, at(0.3)) + '\n\n# 新标题\n\n' + s.slice(at(0.3)),
    (s) => s.slice(0, at(0.5)) + s.slice(at(0.5) + 500),
    (s) => s.replace('| 阅读 | ⌘1 | ✅ |', '| 阅读 | ⌘1 | ✅ |\n| 新行 | x | y |'),
    (s) => s.replace('- [ ] Quick Look 插件\n', '- [ ] Quick Look 插件\n\n- 新项\n'),
    (s) => s.slice(0, at(0.7)) + '\n\n<details>\n\n' + s.slice(at(0.7)),
    (s) => s.slice(0, at(0.8)) + '\n\n$$\n' + s.slice(at(0.8)),
    (s) => s + '\n\n最后一行',
    (s) => '---\ntitle: x\n---\n' + s,
    (s) => s.replace('> 普通引用块。', '> [!NOTE]\n> 普通引用块。'),
  ];
  let doc = big;
  for (const edit of edits) {
    const next = edit(doc);
    assertIncrementalMatches(doc, next);
    doc = next;
  }
});

test('普通打字走增量解析（不退回整篇），包括改动紧挨着列表的情况', () => {
  const base = readFileSync(new URL('../../fixtures/showcase.md', import.meta.url), 'utf8')
    .replace(/\[\^1\]:.*\n/, '')
    .replace('[^1]', '');
  const big = base.slice(base.indexOf('# Silk')).repeat(400);
  for (const at of [10, 300, 420, Math.floor(big.length / 2), big.length - 5]) {
    const { incremental } = assertIncrementalMatches(big, big.slice(0, at) + '字' + big.slice(at));
    assert.equal(incremental.incremental, true, `在第 ${at} 个字处打字退回了整篇解析`);
  }
});

test('重名标题按全篇编号，删掉前面的标题后重新编号', () => {
  const ids = (src) => assignHeadingIds(renderBlocks(src).blocks).flat();
  resetBlocks();
  assert.deepEqual(ids('# 概述\n\n## 概述\n\n## 概述'), ['概述', '概述-1', '概述-2']);
  resetBlocks();
  assert.deepEqual(ids('## 概述\n\n## 概述'), ['概述', '概述-1']);
});

test('重名标题编号在增量渲染后也和整篇一致', () => {
  const doc = filler + '\n\n## 小结\n\n甲\n\n' + filler + '\n\n## 小结\n\n乙\n';
  resetBlocks();
  renderBlocks(doc);
  const after = doc.replace('\n\n## 小结\n\n甲\n\n', '\n\n甲\n\n');
  const incremental = assignHeadingIds(renderBlocks(after).blocks).flat();
  resetBlocks();
  const full = assignHeadingIds(renderBlocks(after).blocks).flat();
  assert.deepEqual(incremental, full);
  assert.deepEqual(full.filter((id) => id.startsWith('小结')), ['小结']);
});

test('跨文件双链带上标题锚点', () => {
  resetBlocks();
  const { blocks } = renderBlocks('见 [[笔记#第二节]] 和 [[#本页标题|这里]]');
  assert.match(blocks[0].html, /href="%E7%AC%94%E8%AE%B0#第二节" data-wiki="笔记"/);
  assert.match(blocks[0].html, /href="#本页标题" data-wiki=""/);
});

test('删除写在引用块、列表项里的链接定义后，用到它的链接也变回原文', () => {
  for (const def of ['> [a]: https://apple.com\n', '- [a]: https://apple.com\n', '1. [a]: https://apple.com\n']) {
    const doc = filler + '\n\n见 [苹果][a]。\n\n' + filler + '\n\n' + def;
    resetBlocks();
    assert.ok(renderBlocks(doc).blocks.some((b) => b.html.includes('href="https://apple.com"')), `定义 ${def.trim()} 应该生效`);
    const { full } = assertIncrementalMatches(doc, doc.replace(def, ''));
    assert.ok(!full.blocks.some((b) => b.html.includes('href="https://apple.com"')));
  }
});

test('在引用块里新写一个链接定义，窗口外用到它的链接也会生效', () => {
  const doc = filler + '\n\n见 [苹果][a]。\n\n' + filler + '\n\n> 引用\n';
  const { full } = assertIncrementalMatches(doc, doc.replace('> 引用\n', '> [a]: https://apple.com\n'));
  assert.ok(full.blocks.some((b) => b.html.includes('href="https://apple.com"')));
});

const headingIds = (src) => {
  resetBlocks();
  return assignHeadingIds(renderBlocks(src).blocks).flat();
};

test('去重后的 id 不会和另一个标题撞上', () => {
  const ids = headingIds('# a\n\n# a\n\n# a-1');
  assert.equal(new Set(ids).size, ids.length);
  assert.deepEqual(ids, ['a', 'a-1', 'a-1-1']);
  const ids2 = headingIds('# a-1\n\n# a\n\n# a');
  assert.deepEqual(ids2, ['a-1', 'a', 'a-2']);
});

test('作者在原生 HTML 里写的 id 不会被改写，也不会被自动生成的 id 占用', () => {
  resetBlocks();
  const { blocks } = renderBlocks('<h2 id="custom">一</h2>\n\n<h2 id="custom">二</h2>\n\n## Custom\n\n## 小结');
  // 原生 HTML 标题不参与编号，HTML 里的 id 原样保留。
  assert.equal(blocks.filter((b) => b.html.includes('id="custom"')).length, 2);
  assert.deepEqual(assignHeadingIds(blocks).flat(), ['custom-1', '小结']);
});

test('单引号 id 的 HTML 标题和 Markdown 标题在同一块里时，id 不会错位', () => {
  resetBlocks();
  const { blocks } = renderBlocks("<details>\n<h3 id='x'>单引号</h3>\n\n## 正文标题\n\n</details>");
  assert.equal(blocks.length, 1);
  assert.deepEqual(blocks[0].slugs, ['正文标题']);
  assert.match(blocks[0].html, /<h3 id='x'>/);
  // 预览按 [data-slug] 写 id，只会写到 Markdown 标题上。
  assert.equal((blocks[0].html.match(/data-slug=/g) ?? []).length, 1);
  assert.match(blocks[0].html, /<h2 data-slug="正文标题"/);
});

test('各种合法写法的 HTML id 都会被避开', () => {
  for (const html of ['<div id=intro>x</div>', '<div ID="intro">x</div>', '<div id = "intro">x</div>', "<div id='intro'>x</div>", '<div\tid="intro">x</div>', '<a name="intro"></a>', '<span class="a" id=intro />']) {
    assert.deepEqual(headingIds(html + '\n\n## Intro'), ['intro-1'], html);
  }
  // 属性值里的实体按解码后的值比较，和 DOM 里的 id 一致。
  assert.deepEqual(headingIds('<div id="a&amp;b">x</div>\n\n## a&b'), ['ab']);
  // 正文、代码里出现的 id= 文字不算。
  assert.deepEqual(headingIds('`<div id="intro">`\n\n```html\n<div id=intro>\n```\n\n## Intro'), ['intro']);
});

test('大文档里没显示出来的块，也能按 HTML 锚点找到', () => {
  const doc = '# 锚点\n\n' + filler + '\n\n<a id="deep"></a>\n\n<p name="notanchor" id=\'other\'>x</p>\n\n' + filler + '\n\n正文[^1]\n\n[^1]: 脚注\n';
  resetBlocks();
  const { blocks } = renderBlocks(doc);
  const ids = assignHeadingIds(blocks);
  const deep = anchorBlockIndex(blocks, ids, 'deep');
  assert.ok(deep > 0 && blocks[deep].html.includes('<a id="deep">'));
  assert.ok(blocks[anchorBlockIndex(blocks, ids, 'other')].html.includes("id='other'"));
  // 只有 <a> 的 name 算锚点。
  assert.equal(anchorBlockIndex(blocks, ids, 'notanchor'), -1);
  // 脚注的 id 也能找到。
  assert.ok(blocks[anchorBlockIndex(blocks, ids, 'fn1')].html.includes('footnotes'));
  // Markdown 标题照常能找到。
  assert.equal(anchorBlockIndex(blocks, ids, '锚点'), 0);
});

test('回车一次就换行，空一行才分段，中文行之间不插空格', () => {
  resetBlocks();
  const { blocks } = renderBlocks('你好 你好你\n你\n\n你好\n\n你\n你行');
  assert.deepEqual(blocks.map((b) => b.html.trim()), ['<p>你好 你好你<br>\n你</p>', '<p>你好</p>', '<p>你<br>\n你行</p>']);
});
