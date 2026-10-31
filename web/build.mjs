// 把预览页打包到 Resources/Preview，供 App 内置。
import { build } from 'esbuild';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '..', 'Resources', 'Preview');
const modules = join(here, 'node_modules');

// 项目在 iCloud 同步的目录里：不要整个删掉重建（会产生「xxx 2.js」冲突副本），只覆盖有变化的文件。
mkdirSync(join(out, 'katex', 'fonts'), { recursive: true });
const written = new Set();
function copy(from, to) {
  written.add(to);
  if (existsSync(to) && statSync(to).size === statSync(from).size && readFileSync(to).equals(readFileSync(from))) return;
  cpSync(from, to);
}

const bundled = join(here, 'node_modules', '.cache', 'preview.js');
await build({
  entryPoints: [join(here, 'src', 'preview.js')],
  outfile: bundled,
  bundle: true,
  minify: true,
  format: 'iife',
  target: 'safari26',
  legalComments: 'none',
});

copy(bundled, join(out, 'preview.js'));
copy(join(here, 'src', 'index.html'), join(out, 'index.html'));
copy(join(here, 'src', 'style.css'), join(out, 'style.css'));
copy(join(modules, 'mermaid', 'dist', 'mermaid.min.js'), join(out, 'mermaid.min.js'));
copy(join(modules, 'katex', 'dist', 'katex.min.css'), join(out, 'katex', 'katex.min.css'));
// WebKit 只用得到 woff2，其他字体格式不带。
for (const name of readdirSync(join(modules, 'katex', 'dist', 'fonts'))) {
  if (name.endsWith('.woff2')) copy(join(modules, 'katex', 'dist', 'fonts', name), join(out, 'katex', 'fonts', name));
}

// 删掉不再需要的旧文件。
function prune(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) prune(path);
    else if (!written.has(path)) rmSync(path);
  }
}
prune(out);

console.log('预览页已生成：', out);
