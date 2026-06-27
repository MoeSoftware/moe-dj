/*
  Moe DJ — DUI screen page (display + interactive panel).

  Receives messages from client/dui.lua via SendDuiMessage:
    screen {booth}  - now-playing state (both modes)
    mode   {mode}   - 'display' | 'panel'
    cursor {u,v}    - on-screen cursor position (0..1)
    click  {}       - activate whatever is under the cursor
    queue  {queue}  - queue contents (panel mode)

  Panel buttons send actions back to the client via NUI callbacks (fetch).
*/
(() => {
    const resName = (() => { try { return GetParentResourceName(); } catch (e) { return 'moe-dj'; } })();
    const nui = (cb, data) =>
        fetch(`https://${resName}/${cb}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data || {}),
        }).catch(() => {});

    const $ = (id) => document.getElementById(id);
    const screenEl = $('screen');
    const cursorEl = $('cursor');

    let state = { posMs: 0, anchor: 0, duration: null, playing: false, vol: 0.8 };
    const cur = { u: 0.5, v: 0.5 };

    window.addEventListener('message', (e) => {
        const d = typeof e.data === 'string' ? safeParse(e.data) : e.data;
        if (!d) return;
        switch (d.action) {
            case 'screen': render(d.booth || { idle: true }); break;
            case 'mode':   setMode(d.mode); break;
            case 'cursor': moveCursor(d.u, d.v); break;
            case 'click':  doClick(); break;
            case 'queue':  renderQueue(d.queue || []); break;
        }
    });

    function setMode(mode) {
        screenEl.classList.toggle('panel', mode === 'panel');
        screenEl.classList.toggle('display', mode !== 'panel');
    }

    // ---- shared now-playing render (updates both views) ----
    function render(b) {
        const t = b.track;
        const playing = b.status === 'playing';
        const paused = b.status === 'paused';
        const active = (playing || paused) && t;

        screenEl.classList.remove('idle', 'playing', 'paused');
        screenEl.classList.add(playing ? 'playing' : paused ? 'paused' : 'idle');

        $('booth').textContent = b.name || 'Moe DJ';
        $('p-booth').textContent = b.name || 'Booth';
        $('badge').textContent = playing ? 'LIVE' : paused ? 'PAUSED' : 'IDLE';
        if (b.baseVolume != null) { state.vol = b.baseVolume; $('p-vol').textContent = Math.round(b.baseVolume * 100) + '%'; }

        const title = active ? (t.title || prettyUrl(t.url) || 'Track') : 'Nothing playing';
        $('title').textContent = active ? title : 'No music playing';
        $('p-title').textContent = title;
        $('sub').textContent = active ? (t.sourceType || '') : '';
        $('duration').textContent = active && t.duration ? fmt(t.duration) : '--:--';

        // anchor the server-synced position to our local clock so the bar ticks
        // smoothly between updates (Date.now() used only as a local delta).
        state.posMs = active ? (b.posMs || 0) : 0;
        state.anchor = Date.now();
        state.duration = active ? (t.duration || null) : null;
        state.playing = playing;
        fitTitle();
    }

    function renderQueue(queue) {
        $('p-qcount').textContent = queue.length;
        const next = queue[0];
        $('p-next').textContent = next ? (next.title || prettyUrl(next.url)) : '—';
    }

    // ---- cursor + clicking ----
    function moveCursor(u, v) {
        cur.u = u; cur.v = v;
        cursorEl.style.left = (u * window.innerWidth) + 'px';
        cursorEl.style.top = (v * window.innerHeight) + 'px';
        document.querySelectorAll('.hover').forEach((el) => el.classList.remove('hover'));
        const el = elementAtCursor();
        if (el) el.classList.add('hover');
    }

    function elementAtCursor() {
        const x = cur.u * window.innerWidth, y = cur.v * window.innerHeight;
        const hit = document.elementFromPoint(x, y);
        return hit ? hit.closest('[data-act]') : null;
    }

    function doClick() {
        const el = elementAtCursor();
        if (!el) return;
        const act = el.dataset.act;
        if (act === 'add') nui('duiAddLink');
        else if (act === 'queue') nui('duiQueue');
        else nui('duiAction', { type: act });
    }

    // local progress ticker
    setInterval(() => {
        if (!state.playing) return;
        const elapsed = Math.max(0, (state.posMs + (Date.now() - state.anchor)) / 1000);
        $('elapsed').textContent = fmt(elapsed);
        const pct = state.duration ? Math.min(100, (elapsed / state.duration) * 100) : 0;
        $('fill').style.width = pct + '%';
        $('p-fill').style.width = pct + '%';
    }, 500);

    function fitTitle() {
        const el = $('title');
        el.classList.remove('scroll');
        if (el.scrollWidth > el.parentElement.clientWidth + 4) el.classList.add('scroll');
    }

    function safeParse(s) { try { return JSON.parse(s); } catch (e) { return null; } }
    function fmt(sec) {
        sec = Math.max(0, Math.floor(sec));
        const m = Math.floor(sec / 60), s = sec % 60;
        return `${m}:${s < 10 ? '0' : ''}${s}`;
    }
    function prettyUrl(url) {
        if (!url) return '';
        if (/[?&]v=|youtu\.be\//i.test(url)) return 'YouTube video';
        try { return decodeURIComponent(url.split('/').pop().split('?')[0]) || url; } catch (e) { return url; }
    }
})();
