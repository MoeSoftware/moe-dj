/*
  Moe DJ — NUI controller.
  Routes messages from Lua: drives audio.js, renders the booth manager, and the
  jukebox "add links" / queue overlays. User actions post back via NUI callbacks.
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
    const managerEl = $('manager');

    // ----- inline SVG icons (no emojis) -----
    const ICONS = {
        trash: '<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4.5h6V7M7 7l1 12.5h8L17 7"/></svg>',
        grip:  '<svg class="ic" viewBox="0 0 24 24" fill="currentColor"><circle cx="9" cy="6" r="1.5"/><circle cx="15" cy="6" r="1.5"/><circle cx="9" cy="12" r="1.5"/><circle cx="15" cy="12" r="1.5"/><circle cx="9" cy="18" r="1.5"/><circle cx="15" cy="18" r="1.5"/></svg>',
        vol:   '<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M11 5L6 9H3v6h3l5 4z"/><path d="M15.5 9.5a3.5 3.5 0 010 5" stroke-linecap="round"/></svg>',
    };

    // ----- shared state -----
    let mgr = null;         // manager payload
    let form = null;        // booth being created/edited
    let pendingPlace = null;
    let replaceIndex = null;

    // route audio.js callbacks back to the server
    Audio.onMeta = (boothId, url, meta) =>
        nui('reportMeta', { boothId, url, title: meta.title || null, duration: meta.duration || null });
    Audio.onError = (boothId, url) => nui('reportError', { boothId, url });

    // ============================================================
    //  Message router
    // ============================================================
    window.addEventListener('message', (ev) => {
        const m = ev.data || {};
        switch (m.action) {
            case 'audio':           handleAudio(m); break;
            case 'openManager':     openManager(m.data); break;
            case 'managerBooths':   if (mgr) { mgr.booths = m.booths; if (!form) renderManagerList(); } break;
            case 'placementResult': onPlacementResult(m); break;
            case 'pasteLinks':      openPaste(false); break;
            case 'openQueue':       openQueueUi(); break;
            case 'queueData':       renderQueueUi(m.queue || []); break;
            case 'djscreenShow':    djsShow(m.model); break;
            case 'djscreenVals':    djsVals(m.s); break;
            case 'djscreenHide':    djsHide(); break;
        }
    });

    // ----- /djscreen alignment sidebar (display-only, no NUI focus) -----
    const djsEl = $('djscreen');
    function djsShow(model) {
        $('djs-model').textContent = model ? (' · ' + model) : '';
        djsEl.classList.remove('hidden');
    }
    function djsHide() { djsEl.classList.add('hidden'); }
    function djsVals(s) {
        if (!s) return;
        const m = (v) => v.toFixed(3) + 'm';
        const d = (v) => v.toFixed(1) + '°';
        const rows = [['X', m(s.x)], ['Y', m(s.y)], ['Z', m(s.z)], ['W', m(s.w)], ['H', m(s.h)], ['Tilt', d(s.rx)], ['Turn', d(s.rz)]];
        if (s.ry) rows.push(['Roll', d(s.ry)]);
        $('djs-vals').innerHTML = rows.map(([k, v]) => `<div class="djs-row"><span>${k}</span><b>${v}</b></div>`).join('');
    }

    function handleAudio(m) {
        switch (m.sub) {
            case 'load':   Audio.load(m.booth, m.sourceType, m.url, m.seek, m.volume, m.paused); break;
            case 'volume': Audio.setVolume(m.booth, m.volume); break;
            case 'pause':  Audio.pause(m.booth); break;
            case 'resume': Audio.resume(m.booth, m.seek); break;
            case 'sync':   Audio.sync(m.booth, m.target, m.threshold); break;
            case 'unload': Audio.unload(m.booth); break;
        }
    }

    // ============================================================
    //  Manager
    // ============================================================
    function openManager(data) {
        mgr = data;
        form = null;
        renderBrand($('mgr-brand'), data.brand);
        renderManagerList();
        managerEl.classList.remove('hidden');
    }
    function closeManager() {
        managerEl.classList.add('hidden');
        mgr = null; form = null;
        clearPreview();
        nui('managerClose');
    }
    $('mgr-close').addEventListener('click', closeManager);

    function renderManagerList() {
        clearPreview(); // no rings while viewing the list
        const body = $('mgr-body');
        body.innerHTML = '';

        const bar = document.createElement('div');
        bar.className = 'mgr-bar';
        bar.appendChild(mkBtn('+ Create booth', 'primary', () => startForm(null)));
        body.appendChild(bar);

        if (!mgr.booths || !mgr.booths.length) {
            body.insertAdjacentHTML('beforeend', '<div class="empty">No booths yet. Create one to get started.</div>');
            return;
        }
        mgr.booths.forEach((b) => {
            const row = document.createElement('div');
            row.className = 'booth-row';
            const playing = b.status === 'playing';
            row.innerHTML =
                `<div class="grow">
                    <div class="b-name">${escapeHtml(b.name)}</div>
                    <div class="b-meta">${(b.speakers || []).length} speaker(s) · range ${Math.round(b.range || 30)}m</div>
                 </div>
                 <span class="status-pill ${playing ? 'status-playing' : 'status-idle'}">${b.status}</span>`;
            row.appendChild(mkBtn('Teleport', 'btn-sm', () => { const id = b.id; closeManager(); nui('managerTeleport', { id }); }));
            row.appendChild(mkBtn('Edit', 'btn-sm', () => startForm(b)));
            row.appendChild(mkBtn('Delete', 'btn-sm danger', () => {
                modalConfirm(`Delete "${b.name}"? This cannot be undone.`).then((ok) => {
                    if (ok) nui('managerDelete', { id: b.id });
                });
            }));
            body.appendChild(row);
        });
    }

    function startForm(booth) {
        const defaultModel = (mgr.propModels && mgr.propModels[0]) ? mgr.propModels[0].model : null;
        form = booth
            ? { id: booth.id, name: booth.name, prop: booth.prop || null, propModel: (booth.prop && booth.prop.model) || defaultModel, speakers: [...(booth.speakers || [])], job: booth.job || '', grades: booth.grades || [], blip: booth.blip !== false, range: booth.range, falloff: booth.falloff }
            : { id: null, name: '', prop: null, propModel: defaultModel, speakers: [], job: mgr.defaultJob || '', grades: mgr.defaultGrades || [], blip: true };
        renderForm();
    }

    function renderForm() {
        const body = $('mgr-body');
        body.innerHTML = '';
        const wrap = document.createElement('div');
        wrap.className = 'form-grid';

        wrap.appendChild(field('Booth name', `<input type="text" id="f-name" value="${escapeAttr(form.name)}" placeholder="Main Stage" />`));

        // The jukebox prop is required — it's the DJ interaction point and the booth's anchor.
        // Pick a model (when more than one is configured), then place it.
        const propModels = mgr.propModels || [];
        const propText = form.prop ? `placed ✓ (${form.prop.x.toFixed(1)}, ${form.prop.y.toFixed(1)})` : 'not placed';
        const pr = field('Jukebox prop (required) — the DJ interaction point', `<div class="chip-row"><span class="grow" id="f-prop">${propText}</span></div>`);
        const prRow = pr.querySelector('.chip-row');
        if (propModels.length > 1) {
            const sel = document.createElement('select');
            sel.className = 'mdl-select';
            propModels.forEach((m) => {
                const o = document.createElement('option');
                o.value = m.model; o.textContent = m.label || m.model;
                if (m.model === form.propModel) o.selected = true;
                sel.appendChild(o);
            });
            sel.addEventListener('change', () => {
                form.propModel = sel.value;
                if (form.prop) form.prop.model = sel.value; // swap an already-placed prop's model
            });
            prRow.appendChild(sel);
        }
        prRow.appendChild(mkBtn(form.prop ? 'Re-place' : 'Place prop', 'btn-sm', () => place('prop')));
        wrap.appendChild(pr);

        wrap.appendChild(field(`Speakers (${form.speakers.length}/${mgr.maxSpeakers})`, '<div class="speaker-list" id="f-speakers"></div>'));

        if (mgr.hasCore) {
            wrap.appendChild(field(`Lock to job (optional) — core: ${mgr.coreName}`,
                `<input type="text" id="f-job" value="${escapeAttr(form.job)}" placeholder="blank = anyone can DJ" />`));
            wrap.appendChild(field('Allowed grades (comma-separated, blank = all grades)',
                `<input type="text" id="f-grades" value="${(form.grades || []).join(', ')}" placeholder="e.g. 2, 3, 4" />`));
        } else {
            wrap.appendChild(field('Access', '<div class="hint">No framework core detected — this booth is open to anyone.</div>'));
        }

        wrap.appendChild(field('Map blip',
            `<label class="check"><input type="checkbox" id="f-blip" ${form.blip !== false ? 'checked' : ''}/> Show a finder blip for this booth</label>`));

        const actions = document.createElement('div');
        actions.className = 'row-actions';
        // force-stop only makes sense on an existing, possibly-playing booth
        if (form.id) {
            actions.appendChild(mkBtn('Force-stop', 'btn-sm danger left', () => nui('managerForceStop', { id: form.id })));
        }
        actions.appendChild(mkBtn('Cancel', 'btn-sm', () => { form = null; clearPreview(); renderManagerList(); }));
        actions.appendChild(mkBtn(form.id ? 'Save changes' : 'Create', 'primary', saveForm));
        wrap.appendChild(actions);

        body.appendChild(wrap);
        renderSpeakers();
    }

    function renderSpeakers() {
        const list = $('f-speakers');
        list.innerHTML = '';
        form.speakers.forEach((s, i) => {
            if (s.range == null) s.range = mgr.defaultRange || 30;
            if (s.volume == null) s.volume = 1.0;
            const chip = document.createElement('div');
            chip.className = 'speaker-chip col';
            chip.innerHTML =
                `<div class="sp-head">
                    <span class="grow sp-label">${ICONS.vol} Speaker #${i + 1}</span>
                    <span class="sp-coords">${s.x.toFixed(1)}, ${s.y.toFixed(1)}, ${s.z.toFixed(1)}</span>
                 </div>
                 <div class="sp-slider">
                    <span class="sp-l">Range</span>
                    <input type="range" min="5" max="120" value="${Math.round(s.range)}" data-sp-range="${i}" />
                    <span class="sp-val" id="sp-range-val-${i}">${Math.round(s.range)}m</span>
                 </div>
                 <div class="sp-slider">
                    <span class="sp-l">Volume</span>
                    <input type="range" min="0" max="100" value="${Math.round(s.volume * 100)}" data-sp-vol="${i}" />
                    <span class="sp-val" id="sp-vol-val-${i}">${Math.round(s.volume * 100)}%</span>
                 </div>
                 <div class="sp-actions"></div>`;
            const acts = chip.querySelector('.sp-actions');
            acts.appendChild(mkBtn('Move', 'btn-sm', () => { replaceIndex = i; place('speaker'); }));
            acts.appendChild(mkBtn('Remove', 'btn-sm danger', () => { form.speakers.splice(i, 1); renderSpeakers(); }));
            list.appendChild(chip);
        });

        list.querySelectorAll('[data-sp-range]').forEach((el) => {
            const i = Number(el.dataset.spRange);
            el.addEventListener('input', () => {
                form.speakers[i].range = Number(el.value);
                $(`sp-range-val-${i}`).textContent = el.value + 'm';
                managerEl.classList.add('peek'); // fade card so the ring is visible
                sendPreview(i); // highlight the speaker being adjusted
            });
            const undim = () => { managerEl.classList.remove('peek'); sendPreview(); };
            el.addEventListener('change', undim);
            el.addEventListener('blur', undim);
        });
        list.querySelectorAll('[data-sp-vol]').forEach((el) => {
            const i = Number(el.dataset.spVol);
            el.addEventListener('input', () => {
                form.speakers[i].volume = Number(el.value) / 100;
                $(`sp-vol-val-${i}`).textContent = el.value + '%';
            });
        });

        if (form.speakers.length < mgr.maxSpeakers) {
            list.appendChild(mkBtn('+ Add speaker (walk & place)', 'btn-sm wide', () => { replaceIndex = null; place('speaker'); }));
        }
        sendPreview();
    }

    // draw range rings in-world for the current speakers (active = being dragged)
    function sendPreview(activeIdx) {
        if (!form) return;
        nui('managerPreview', {
            speakers: form.speakers.map((s, i) => ({
                x: s.x, y: s.y, z: s.z,
                range: s.range || (mgr.defaultRange || 30),
                active: i === activeIdx,
            })),
        });
    }
    function clearPreview() { nui('managerPreviewClear'); }

    function captureFields() {
        if ($('f-name')) form.name = $('f-name').value;
        if (mgr.hasCore && $('f-job')) { form.job = $('f-job').value; form.grades = parseGrades($('f-grades').value); }
        if ($('f-blip')) form.blip = $('f-blip').checked;
    }

    function place(kind) {
        captureFields();
        pendingPlace = kind;
        managerEl.classList.add('hidden'); // get the card out of the way while placing
        // boothId excludes self from spacing checks; model picks the ghost prop
        nui('managerPlace', { kind, boothId: form.id, model: form.propModel });
    }

    function onPlacementResult(m) {
        managerEl.classList.remove('hidden');
        if (!form || pendingPlace !== m.kind) return;
        pendingPlace = null;
        if (m.point) {
            if (m.kind === 'prop') {
                form.prop = { x: m.point.x, y: m.point.y, z: m.point.z, heading: m.point.heading, model: form.propModel };
            } else if (replaceIndex !== null && form.speakers[replaceIndex]) {
                const prev = form.speakers[replaceIndex];
                form.speakers[replaceIndex] = { x: m.point.x, y: m.point.y, z: m.point.z, range: prev.range, volume: prev.volume };
            } else if (form.speakers.length < mgr.maxSpeakers) {
                form.speakers.push({ x: m.point.x, y: m.point.y, z: m.point.z, range: mgr.defaultRange || 30, volume: 1.0 });
            }
        }
        replaceIndex = null;
        renderForm();
    }

    function saveForm() {
        captureFields();
        form.name = (form.name || '').trim();
        if (!form.prop) { modalAlert('Place a jukebox prop — it\'s the DJ interaction point.'); return; }
        if (!form.speakers.length) { modalAlert('Add at least one speaker.'); return; }

        const payload = {
            id: form.id,
            name: form.name,
            prop: form.prop,
            speakers: form.speakers,
            job: mgr.hasCore ? form.job.trim() : '',
            grades: mgr.hasCore ? form.grades : [],
            blip: form.blip,
            range: form.range,
            falloff: form.falloff,
        };
        nui(form.id ? 'managerUpdate' : 'managerCreate', payload);
        form = null;
        clearPreview();
        // refreshed list arrives via 'managerBooths'
    }

    // ============================================================
    //  helpers
    // ============================================================
    function field(label, innerHtml) {
        const d = document.createElement('div');
        d.className = 'field';
        d.innerHTML = `<label>${label}</label>${innerHtml}`;
        return d;
    }
    function mkBtn(text, cls, onClick) {
        const b = document.createElement('button');
        b.className = cls; b.textContent = text; b.addEventListener('click', onClick);
        return b;
    }
    function renderBrand(el, brand) {
        if (!brand) { el.innerHTML = ''; return; }
        // Just a credit — NUI can't open external links in a real browser anyway.
        el.innerHTML = `<span><b>${escapeHtml(brand.name)}</b> by ${escapeHtml(brand.author)}</span>`;
    }
    function parseGrades(str) {
        return (str || '').split(',').map((s) => parseInt(s.trim(), 10)).filter((n) => !isNaN(n));
    }
    function prettyUrl(url) {
        if (!url) return '';
        if (/[?&]v=|youtu\.be\//i.test(url)) return 'YouTube video'; // until the real title resolves
        try { return decodeURIComponent(url.split('/').pop().split('?')[0]) || url; } catch (e) { return url; }
    }
    function escapeHtml(s) {
        return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    }
    function escapeAttr(s) { return escapeHtml(s).replace(/"/g, '&quot;'); }

    // ---- in-UI modal (replaces native prompt / confirm / alert) ----
    const modalEl = $('modal');
    let modalResolve = null;
    function showModal(opts) {
        return new Promise((res) => {
            modalResolve = res;
            $('modal-title').textContent = opts.title || '';
            const inp = $('modal-input');
            if (opts.input) {
                inp.classList.remove('hidden');
                inp.value = opts.value || '';
                inp.placeholder = opts.placeholder || '';
                inp.readOnly = !!opts.readonly;
            } else {
                inp.classList.add('hidden');
            }
            $('modal-ok').textContent = opts.okText || 'OK';
            $('modal-cancel').textContent = opts.cancelText || 'Cancel';
            $('modal-cancel').style.display = opts.single ? 'none' : '';
            modalEl.classList.remove('hidden');
            if (opts.input) setTimeout(() => { inp.focus(); if (opts.readonly) inp.select(); }, 30);
        });
    }
    function closeModal(result) {
        modalEl.classList.add('hidden');
        const r = modalResolve; modalResolve = null;
        if (r) r(result);
    }
    function modalPrompt(title, opts) { return showModal(Object.assign({ title, input: true }, opts || {})); }
    function modalConfirm(title) { return showModal({ title }).then((v) => v === true); }
    function modalAlert(title) { return showModal({ title, single: true }); }
    $('modal-ok').addEventListener('click', () => {
        const inp = $('modal-input');
        closeModal(inp.classList.contains('hidden') ? true : inp.value);
    });
    $('modal-cancel').addEventListener('click', () => closeModal(null));
    $('modal-input').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); $('modal-ok').click(); }
        else if (e.key === 'Escape') { e.preventDefault(); closeModal(null); }
    });


    // ---- jukebox "add links" overlay (multi-add, real paste box) ----
    const pasteEl = $('paste');
    const queueEl = $('queueui');
    let pasteFromQueue = false; // opened on top of the queue manager?
    let lastQueue = [];

    function openPaste(fromQueue) {
        pasteFromQueue = !!fromQueue;
        if (pasteFromQueue) queueEl.classList.add('hidden');
        $('paste-input').value = '';
        $('paste-status').textContent = '';
        pasteEl.classList.remove('hidden');
        setTimeout(() => $('paste-input').focus(), 30);
    }
    function closePaste() {
        pasteEl.classList.add('hidden');
        if (pasteFromQueue) { pasteFromQueue = false; queueEl.classList.remove('hidden'); } // back to queue
        else nui('jukeboxOverlayClose');
    }

    // ---- jukebox queue manager ----
    function openQueueUi() {
        queueEl.classList.remove('hidden');
        renderQueueUi(lastQueue);
    }
    function closeQueueUi() {
        queueEl.classList.add('hidden');
        nui('jukeboxOverlayClose');
    }
    let drag = null; // { el } while a queue row is being dragged
    function renderQueueUi(queue) {
        if (drag) { lastQueue = queue || []; return; } // don't rebuild mid-drag
        lastQueue = queue || [];
        $('qm-count').textContent = lastQueue.length;
        const ul = $('qm-list');
        ul.innerHTML = '';
        if (!lastQueue.length) { ul.innerHTML = '<li class="qm-empty">Queue is empty — add some links.</li>'; return; }
        lastQueue.forEach((item, i) => {
            const pos = i + 1;
            const li = document.createElement('li');
            li.className = 'qm-row' + (i === 0 ? ' head' : '');
            li.dataset.i = pos; // original 1-based position (stable during a drag)
            li.innerHTML =
                `<span class="qm-grip">${ICONS.grip}</span>` +
                `<span class="qm-pos">${pos}</span>` +
                `<span class="qm-src">${escapeHtml(item.sourceType || '')}</span>` +
                `<span class="qm-title">${escapeHtml(item.title || prettyUrl(item.url))}</span>` +
                `<button class="qmini del" data-del="${pos}">${ICONS.trash}</button>`;
            li.addEventListener('mousedown', (e) => {
                if (e.button !== 0 || e.target.closest('[data-del]')) return; // left-button, not the remove btn
                e.preventDefault();
                drag = { el: li };
                li.classList.add('dragging');
            });
            ul.appendChild(li);
        });
        ul.querySelectorAll('[data-del]').forEach((b) =>
            b.addEventListener('click', () => nui('jukeboxQueueAction', { type: 'remove', index: Number(b.dataset.del) })));
    }
    // pointer-based reorder (HTML5 drag-and-drop is unreliable in CEF)
    document.addEventListener('mousemove', (e) => {
        if (!drag) return;
        const ul = $('qm-list');
        let target = null;
        for (const row of ul.querySelectorAll('.qm-row:not(.dragging)')) {
            const r = row.getBoundingClientRect();
            if (e.clientY < r.top + r.height / 2) { target = row; break; }
        }
        ul.insertBefore(drag.el, target); // null target -> append at end
    });
    document.addEventListener('mouseup', () => {
        if (!drag) return;
        drag.el.classList.remove('dragging');
        drag = null;
        commitOrder();
    });
    function commitOrder() {
        const order = [...$('qm-list').querySelectorAll('.qm-row')].map((r) => Number(r.dataset.i));
        if (order.length) nui('jukeboxQueueAction', { type: 'order', order });
    }
    $('qm-done').addEventListener('click', closeQueueUi);
    $('qm-add').addEventListener('click', () => openPaste(true));
    function addPasted() {
        const tokens = ($('paste-input').value || '')
            .split(/[\s,]+/).map((s) => s.trim()).filter((s) => /^https?:\/\//i.test(s));
        if (!tokens.length) { $('paste-status').textContent = 'No links found — paste a URL.'; return; }
        const direct = [];
        tokens.forEach((url) => {
            if (/youtube\.com\/playlist\?/i.test(url) && /[?&]list=/i.test(url)) {
                $('paste-status').textContent = 'Expanding playlist…';
                Audio.resolveYouTubePlaylist(url, (urls) => {
                    if (urls.length) nui('jukeboxAddLinks', { urls: urls.slice(0, 100) });
                    $('paste-status').textContent = 'Added ' + urls.length + ' from playlist.';
                });
            } else {
                direct.push(url);
            }
        });
        if (direct.length) {
            nui('jukeboxAddLinks', { urls: direct });
            $('paste-status').textContent = 'Added ' + direct.length + ' link(s). Paste more, or Done.';
        }
        $('paste-input').value = '';
        $('paste-input').focus();
    }
    $('paste-add').addEventListener('click', addPasted);
    $('paste-done').addEventListener('click', closePaste);
    $('paste-input').addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); addPasted(); }
        else if (e.key === 'Escape') { e.preventDefault(); closePaste(); }
    });

    // ESC closes whatever is open (modal first)
    document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        if (!pasteEl.classList.contains('hidden')) { closePaste(); return; }
        if (!queueEl.classList.contains('hidden')) { closeQueueUi(); return; }
        if (!modalEl.classList.contains('hidden')) { closeModal(null); return; }
        if (!managerEl.classList.contains('hidden')) closeManager();
    });
})();
