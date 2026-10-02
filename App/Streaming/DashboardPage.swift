import Foundation

/// The page the phone serves to a browser on the same network: every running stream as a tile
/// with its latest values and a small history, refreshed once a second.
///
/// One self-contained HTML file with no external script, font or image — it has to work in a
/// workshop with no internet, from a laptop that has never heard of Sensorstorm. It reads the
/// same JSON a script would, from `/data`.
enum DashboardPage {
    static let html = #"""
    <!doctype html>
    <html lang="de">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sensorstorm</title>
    <style>
      :root { color-scheme: dark; }
      * { box-sizing: border-box; }
      body { margin: 0; background: #000; color: #eee; font: 15px/1.4 -apple-system, system-ui, sans-serif; }
      header { display: flex; align-items: center; gap: 12px; padding: 14px 18px; border-bottom: 1px solid #222; position: sticky; top: 0; background: #000e; backdrop-filter: blur(8px); }
      header h1 { font-size: 17px; margin: 0; flex: 1; }
      #state { font-size: 12px; padding: 3px 9px; border-radius: 99px; background: #1c3; color: #000; }
      #state.off { background: #c33; color: #fff; }
      main { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; padding: 14px 18px 40px; }
      .tile { background: #1b1b1b; border: 1px solid #383838; border-radius: 14px; padding: 12px 14px; }
      .tile h2 { font-size: 13px; margin: 0 0 6px; color: #8cd; font-weight: 600; letter-spacing: .02em; }
      .row { display: flex; justify-content: space-between; font-variant-numeric: tabular-nums; font-size: 14px; }
      .row span:first-child { color: #999; }
      canvas { width: 100%; height: 46px; margin-top: 8px; display: block; }
      footer { padding: 0 18px 24px; color: #777; font-size: 12px; }
    </style>
    </head>
    <body>
    <header><h1>Sensorstorm</h1><span id="clock"></span><span id="state">verbunden</span></header>
    <main id="tiles"></main>
    <footer>Nur lesen. Die Werte kommen einmal pro Sekunde vom Telefon, das Fenster darf offen bleiben. Dieselben Daten gibt es als JSON unter /data.</footer>
    <script>
    const tiles = {};
    const history = {};
    const colours = ['#f25d5d', '#66d982', '#6499fa', '#f5bd52', '#c285f2', '#5cded9'];
    function fmt(v) {
      if (typeof v !== 'number' || !isFinite(v)) return '—';
      const a = Math.abs(v);
      return v.toFixed(a === 0 ? 2 : a < 0.01 ? 5 : a < 1 ? 4 : a < 100 ? 3 : a < 10000 ? 2 : 1);
    }
    function draw(canvas, series) {
      const dpr = window.devicePixelRatio || 1;
      const w = canvas.clientWidth * dpr, h = canvas.clientHeight * dpr;
      canvas.width = w; canvas.height = h;
      const g = canvas.getContext('2d');
      let lo = Infinity, hi = -Infinity;
      series.forEach(s => s.forEach(v => { if (isFinite(v)) { lo = Math.min(lo, v); hi = Math.max(hi, v); } }));
      if (!isFinite(lo)) return;
      if (hi === lo) { hi += 1; lo -= 1; }
      series.forEach((s, i) => {
        g.beginPath();
        g.strokeStyle = colours[i % colours.length];
        g.lineWidth = 1.5 * dpr;
        s.forEach((v, k) => {
          const x = s.length > 1 ? k / (s.length - 1) * w : w;
          const y = h - (v - lo) / (hi - lo) * (h - 4 * dpr) - 2 * dpr;
          if (k === 0) g.moveTo(x, y); else g.lineTo(x, y);
        });
        g.stroke();
      });
    }
    function render(payload) {
      const root = document.getElementById('tiles');
      payload.forEach(item => {
        const name = item.name;
        const keys = Object.keys(item).filter(k => k !== 'name' && k !== 'time');
        let tile = tiles[name];
        if (!tile) {
          const el = document.createElement('div');
          el.className = 'tile';
          el.innerHTML = '<h2></h2><div class="rows"></div><canvas></canvas>';
          el.querySelector('h2').textContent = name;
          root.appendChild(el);
          tile = tiles[name] = { el, rows: el.querySelector('.rows'), canvas: el.querySelector('canvas') };
          history[name] = {};
        }
        tile.rows.innerHTML = keys.map(k => '<div class="row"><span>' + k + '</span><span>' + fmt(item[k]) + '</span></div>').join('');
        keys.forEach(k => {
          const h = history[name][k] = history[name][k] || [];
          h.push(item[k]); if (h.length > 90) h.shift();
        });
        draw(tile.canvas, keys.slice(0, 6).map(k => history[name][k]));
      });
    }
    async function tick() {
      const state = document.getElementById('state');
      try {
        const r = await fetch('/data', { cache: 'no-store' });
        const j = await r.json();
        render(j.payload || []);
        state.textContent = 'verbunden'; state.className = '';
        document.getElementById('clock').textContent = new Date().toLocaleTimeString();
      } catch (e) {
        state.textContent = 'keine Verbindung'; state.className = 'off';
      }
    }
    tick(); setInterval(tick, 1000);
    </script>
    </body>
    </html>
    """#
}
