/*
  Moe DJ — audio engine. One YouTube IFrame player per booth. Volume in is always
  0..1 from Lua. app.js sets onMeta/onError.
*/
const Audio = (() => {
    const pool = document.getElementById('audio-pool');
    const instances = {}; // boothId -> instance

    // ---- YouTube IFrame API readiness ----
    let ytReady = false;
    const ytWaiters = [];
    window.onYouTubeIframeAPIReady = () => {
        ytReady = true;
        ytWaiters.forEach((fn) => fn());
        ytWaiters.length = 0;
    };
    const whenYT = (fn) => (ytReady ? fn() : ytWaiters.push(fn));

    const reportMeta = (id, url, meta) => { if (typeof api.onMeta === 'function') api.onMeta(id, url, meta); };
    const reportError = (id, url) => { if (typeof api.onError === 'function') api.onError(id, url); };

    function parseYouTubeId(url) {
        const m =
            url.match(/[?&]v=([^&]+)/) ||
            url.match(/youtu\.be\/([^?&/]+)/) ||
            url.match(/\/embed\/([^?&/]+)/) ||
            url.match(/\/shorts\/([^?&/]+)/);
        return m ? m[1] : null;
    }

    function destroyInstance(inst) {
        if (!inst) return;
        try {
            if (inst.player && inst.player.destroy) inst.player.destroy();
        } catch (e) { /* swallow — teardown should never throw */ }
        if (inst.node && inst.node.parentNode) inst.node.parentNode.removeChild(inst.node);
    }

    function clamp01(v) { v = Number(v) || 0; return v < 0 ? 0 : v > 1 ? 1 : v; }

    // -------------------- YOUTUBE --------------------
    function loadYouTube(id, url, seek, volume, paused) {
        const videoId = parseYouTubeId(url);
        const node = document.createElement('div');
        pool.appendChild(node);
        const inst = { type: 'youtube', url, player: null, node, ready: false, dur: 0, pendingVol: volume };
        if (!videoId) { console.warn('[moe-dj] bad youtube url:', url); reportError(id, url); return inst; }

        whenYT(() => {
            inst.player = new YT.Player(node, {
                height: '1', width: '1',
                videoId,
                playerVars: { autoplay: paused ? 0 : 1, controls: 0, disablekb: 1, fs: 0, playsinline: 1, origin: location.origin },
                events: {
                    onReady: (e) => {
                        inst.ready = true;
                        e.target.setVolume(Math.round(clamp01(inst.pendingVol) * 100));
                        try { e.target.seekTo(seek || 0, true); } catch (err) {}
                        if (paused) e.target.pauseVideo(); else e.target.playVideo();
                        let title = null;
                        try { title = (e.target.getVideoData() || {}).title || null; } catch (err) {}
                        if (title) reportMeta(id, url, { title });
                    },
                    onStateChange: (e) => {
                        if (e.data === YT.PlayerState.PLAYING && !inst.dur) {
                            inst.dur = e.target.getDuration() || 0;
                            reportMeta(id, url, { duration: inst.dur });
                        }
                    },
                    onError: () => { console.warn('[moe-dj] youtube embed error:', url); reportError(id, url); },
                },
            });
        });
        return inst;
    }

    // -------------------- public API --------------------
    const api = {
        onMeta: null,
        onError: null,

        load(id, sourceType, url, seek, volume, paused) {
            if (instances[id]) { destroyInstance(instances[id]); delete instances[id]; }
            instances[id] = loadYouTube(id, url, seek, volume, paused);
        },

        setVolume(id, volume) {
            const inst = instances[id];
            if (!inst) return;
            const v = clamp01(volume);
            if (inst.ready) inst.player.setVolume(Math.round(v * 100));
            else inst.pendingVol = v;
        },

        pause(id) {
            const inst = instances[id];
            if (inst && inst.ready) inst.player.pauseVideo();
        },

        resume(id, seek) {
            const inst = instances[id];
            if (inst && inst.ready) { inst.player.seekTo(seek, true); inst.player.playVideo(); }
        },

        sync(id, target, threshold) {
            const inst = instances[id];
            if (!inst || !inst.ready) return;
            threshold = threshold || 2.5;
            const cur = inst.player.getCurrentTime();
            if (Math.abs(cur - target) > threshold) inst.player.seekTo(target, true);
        },

        unload(id) {
            if (instances[id]) { destroyInstance(instances[id]); delete instances[id]; }
        },

        // Expand a YouTube playlist URL into individual watch URLs (so each track
        // keeps the normal server-synced queue behaviour). cb receives an array.
        resolveYouTubePlaylist(url, cb) {
            const listId = (url.match(/[?&]list=([^&]+)/) || [])[1];
            if (!listId) { cb([]); return; }
            whenYT(() => {
                const node = document.createElement('div');
                pool.appendChild(node);
                let done = false;
                let player = null;
                const finish = (ids) => {
                    if (done) return;
                    done = true;
                    try { if (player && player.destroy) player.destroy(); } catch (e) {}
                    if (node.parentNode) node.parentNode.removeChild(node);
                    cb(ids.map((vid) => 'https://www.youtube.com/watch?v=' + vid));
                };
                player = new YT.Player(node, {
                    height: '1', width: '1',
                    playerVars: { listType: 'playlist', list: listId, autoplay: 0 },
                    events: {
                        onReady: (e) => {
                            e.target.mute();
                            let tries = 0;
                            const iv = setInterval(() => {
                                const ids = (e.target.getPlaylist && e.target.getPlaylist()) || [];
                                if (ids.length) { clearInterval(iv); finish(ids); }
                                else if (++tries > 25) { clearInterval(iv); finish([]); }
                            }, 200);
                        },
                        onError: () => finish([]),
                    },
                });
                setTimeout(() => finish([]), 9000); // hard timeout
            });
        },
    };

    return api;
})();
