// Turns design-canvas .dc.html artboards into standalone HTML (and PNG) files.
// Usage: node export_dc.js <srcDir> <outDir>
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const [SRC, OUT] = process.argv.slice(2);

const get = (scope, p) => p.trim().split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope);
const esc = (v) => String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');

function holes(s, scope) {
  return s.replace(/\{\{([^}]*)\}\}/g, (m, p) => {
    const t = p.trim();
    if (t === 'false') return 'false';
    const v = get(scope, t);
    if (v === undefined) throw new Error('unresolved ' + m);
    return esc(v);
  });
}

function expand(s, scope) {
  let out = '';
  for (;;) {
    const m = /<sc-(for|if)\b([^>]*)>/.exec(s);
    if (!m) return out + holes(s, scope);
    out += holes(s.slice(0, m.index), scope);
    const tag = m[1];
    const re = new RegExp(`<sc-${tag}\\b[^>]*>|</sc-${tag}>`, 'g');
    re.lastIndex = m.index + m[0].length;
    let depth = 1, r;
    while ((r = re.exec(s))) { depth += r[0][1] === '/' ? -1 : 1; if (!depth) break; }
    const inner = s.slice(m.index + m[0].length, r.index);
    const attr = (n) => (new RegExp(`${n}="([^"]*)"`).exec(m[2]) || [])[1];
    if (tag === 'for') {
      const list = get(scope, attr('list').replace(/[{}]/g, '')) || [];
      const as = attr('as');
      for (const it of list) out += expand(inner, { ...scope, [as]: it });
    } else if (get(scope, attr('value').replace(/[{}]/g, ''))) out += expand(inner, scope);
    s = s.slice(r.index + r[0].length);
  }
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const files = fs.readdirSync(SRC).filter((f) => f.endsWith('.dc.html')).sort();
  const b = await chromium.launch();
  for (const f of files) {
    const src = fs.readFileSync(path.join(SRC, f), 'utf8');
    const title = (/<title>(.*?)<\/title>/.exec(src) || [])[1] || f;
    const helmet = (/<helmet>([\s\S]*?)<\/helmet>/.exec(src) || [])[1] || '';
    let body = /<x-dc>([\s\S]*?)<\/x-dc>/.exec(src)[1].replace(/<helmet>[\s\S]*?<\/helmet>/, '');
    const js = (/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/.exec(src) || [])[1];
    let vals = {};
    if (js) vals = new Function('DCLogic', js + '\nreturn new Component().renderVals();')(class {});
    body = expand(body, vals);
    const A = JSON.parse(fs.readFileSync(path.join(SRC, 'assets.json'), 'utf8'));
    body = body.replace(/\/_blob\/([0-9a-f]{32})/g, (m, id) => '../assets/' + A[id]);
    const name = f.replace(/\.dc\.html$/, '');
    body = body.replace(/href="([^"]+)\.dc\.html"/g, 'href="$1.html"');
    const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>${title}</title>\n${helmet.trim()}\n</head>\n<body>\n${body.trim()}\n</body>\n</html>\n`;
    fs.writeFileSync(path.join(OUT, name + '.html'), html);
    const p = await b.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 });
    await p.goto('file://' + path.join(OUT, name + '.html'));
    await p.waitForTimeout(600);
    const box = await p.evaluate(() => { const e = document.body.firstElementChild; const r = e.getBoundingClientRect(); return { w: Math.ceil(r.width), h: Math.ceil(r.height) }; });
    await p.setViewportSize({ width: box.w, height: box.h });
    await p.screenshot({ path: path.join(OUT, name + '.png'), clip: { x: 0, y: 0, width: box.w, height: box.h } });
    await p.close();
    console.log(name, box.w + 'x' + box.h);
  }
  await b.close();
})();
