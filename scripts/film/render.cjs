// Renders film.html to video. Needs Chromium, ffmpeg and playwright-core:
//   PLAYWRIGHT_CORE=/path/to/playwright-core CHROMIUM=/usr/bin/chromium node scripts/film/render.cjs [out.mp4] [--stills 1,8.9,13.8]
// Serves the repo root so film.html can load docs/assets.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const http = require('http'), fs = require('fs'), path = require('path'), { execFileSync } = require('child_process');
const root = path.resolve(__dirname, '../..');
const args = process.argv.slice(2);
const stillsArg = args.indexOf('--stills');
const stills = stillsArg >= 0 ? args[stillsArg + 1].split(',').map(Number) : null;
const out = path.resolve(args.find(a => a.endsWith('.mp4')) || path.join(root, 'docs/film.mp4'));
const FPS = 30;
const types = { '.html': 'text/html', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const f = path.join(root, decodeURIComponent(req.url.split('?')[0]));
  if (!f.startsWith(root) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
}).listen(0);

(async () => {
  const port = server.address().port;
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  page.on('pageerror', e => console.error('page error:', e.message));
  await page.goto(`http://localhost:${port}/scripts/film/film.html`);
  await page.evaluate(() => window.ready);
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'film-'));
  const times = stills || Array.from({ length: Math.round(await page.evaluate(() => DURATION) * FPS) }, (_, i) => i / FPS);
  for (const [i, t] of times.entries()) {
    await page.evaluate(t => render(t), t);
    await page.screenshot({ path: stills ? path.join(path.dirname(out), `still-${t}.png`) : path.join(dir, `f${String(i).padStart(5, '0')}.png`) });
    if (!stills && i % 150 === 0) console.log(`frame ${i}/${times.length}`);
  }
  await browser.close(); server.close();
  if (stills) return;
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', path.join(dir, 'f%05d.png'),
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out]);
  fs.copyFileSync(path.join(dir, 'f00840.png'), out.replace(/\.mp4$/, '-poster.png'));
  fs.rmSync(dir, { recursive: true });
  console.log('wrote', out);
})();
