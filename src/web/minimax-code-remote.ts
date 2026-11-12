/** Browser shell for the direct MiniMax Code ACP remote. */
export function miniMaxCodeRemoteHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>MiniMax Code Remote</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f4f6fa;
      --surface: #ffffff;
      --ink: #1c2430;
      --muted: #3d4a5c;
      --line: #d5dce6;
      --accent: #1c2430;
      --accent-ink: #ffffff;
      --secondary: #e6edf5;
      --secondary-ink: #1c2430;
      --active: #e6ebf8;
      --user: #e6ebf8;
      --danger: #7f1d1d;
      --danger-bg: #fde8e6;
      --focus: #1d4ed8;
      --focus-ring: rgba(29, 78, 216, 0.28);
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #10151c;
        --surface: #1a212c;
        --ink: #f3f6fb;
        --muted: #c9d3e0;
        --line: #334052;
        --accent: #f3f6fb;
        --accent-ink: #10151c;
        --secondary: #2a3442;
        --secondary-ink: #f3f6fb;
        --active: #2c3850;
        --user: #2c3850;
        --danger: #ffd2cc;
        --danger-bg: #4a2424;
        --focus: #93c5fd;
        --focus-ring: rgba(147, 197, 253, 0.35);
      }
    }
    * { box-sizing: border-box; }
    body { margin: 0; height: 100vh; height: 100dvh; overflow: hidden; color: var(--ink); background: var(--bg); }
    button, input, textarea { font: inherit; color: inherit; }
    button { cursor: pointer; }
    :focus { outline: none; }
    :focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
    ::placeholder { color: var(--muted); opacity: 1; }
    .sr {
      position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
      overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
    }
    .app { display: grid; grid-template-columns: 300px minmax(0, 1fr); height: 100%; }
    aside {
      display: flex; flex-direction: column; min-width: 0;
      border-right: 1px solid var(--line); background: var(--surface);
    }
    header { display: flex; align-items: center; gap: 12px; padding: 14px 16px; border-bottom: 1px solid var(--line); }
    .brand { display: flex; align-items: center; gap: 12px; min-width: 0; flex: 1; }
    .mark {
      display: grid; place-items: center; width: 36px; height: 36px; flex: none;
      border-radius: 10px; color: var(--accent-ink); background: var(--accent); font-weight: 700;
    }
    h1, h2, p { margin: 0; }
    h1 { font-size: 17px; line-height: 1.3; }
    h2 { font-size: 20px; line-height: 1.3; }
    .subtle { color: var(--muted); font-size: 13px; line-height: 1.4; }
    .actions { display: flex; gap: 8px; padding: 12px; }
    .actions button, #send, #threads-toggle, #close-threads {
      min-height: 44px; border: 0; border-radius: 10px; padding: 0 14px;
      color: var(--accent-ink); background: var(--accent);
    }
    .actions button.secondary, #threads-toggle, #close-threads {
      color: var(--secondary-ink); background: var(--secondary);
    }
    #threads-toggle, #close-threads { display: none; }
    .filter { padding: 0 12px 12px; }
    #filter, .cwd input, textarea {
      width: 100%; min-height: 44px; border: 1px solid var(--line); border-radius: 10px;
      padding: 10px 12px; background: var(--surface); color: var(--ink);
    }
    #threads { overflow: auto; padding: 0 8px 12px; }
    .thread {
      width: 100%; min-height: 44px; margin: 4px 0; padding: 10px 12px;
      border: 0; border-radius: 10px; text-align: left; color: inherit; background: transparent;
    }
    .thread:hover, .thread.active { background: var(--active); }
    .thread.active { box-shadow: inset 3px 0 0 var(--focus); }
    .thread strong, .thread span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .thread span { margin-top: 2px; color: var(--muted); font-size: 13px; }
    .empty-threads { padding: 12px; }
    main { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
    .titles { min-width: 0; flex: 1; }
    .main-head { justify-content: space-between; background: var(--surface); }
    #status { color: var(--muted); font-size: 13px; white-space: nowrap; }
    .banner {
      margin: 12px max(16px, 5vw) 0; padding: 12px 14px; border-radius: 12px;
      background: var(--danger-bg); color: var(--danger);
    }
    #messages { flex: 1; min-height: 0; overflow: auto; padding: 24px max(16px, 5vw); }
    .empty { max-width: 32rem; margin: 12vh auto 0; text-align: center; }
    .empty p { margin-top: 8px; color: var(--muted); }
    .message { max-width: 42rem; margin: 0 auto 16px; white-space: pre-wrap; }
    .message.user { padding: 12px 14px; border-radius: 12px; background: var(--user); }
    .message.thought { color: var(--muted); font-size: 13px; }
    .message.error { padding: 12px 14px; border-radius: 12px; background: var(--danger-bg); color: var(--danger); }
    .composer {
      padding: 14px max(16px, 5vw) max(18px, env(safe-area-inset-bottom));
      border-top: 1px solid var(--line); background: var(--surface);
    }
    .cwd { display: flex; flex-direction: column; align-items: stretch; gap: 6px; margin-bottom: 8px; color: var(--muted); font-size: 13px; }
    .prompt {
      display: flex; align-items: flex-end; gap: 10px; padding: 8px;
      border: 1px solid var(--line); border-radius: 14px; background: var(--surface);
    }
    .prompt:focus-within { border-color: var(--focus); box-shadow: 0 0 0 3px var(--focus-ring); }
    textarea { flex: 1; max-height: 180px; resize: vertical; border: 0; padding: 8px; background: transparent; }
    #send:disabled { cursor: default; opacity: .45; }
    @media (max-width: 800px) {
      .app { grid-template-columns: 1fr; }
      aside { position: fixed; inset: 0; z-index: 3; border-right: 0; }
      .app.threads-closed aside { display: none; }
      #threads-toggle, #close-threads { display: inline-flex; align-items: center; justify-content: center; }
      .main-head { flex-wrap: wrap; }
      #status { margin-left: auto; }
      .empty { margin-top: 6vh; }
    }
  </style>
</head>
<body>
  <div class="app" id="app">
    <aside id="sidebar">
      <header>
        <div class="brand">
          <div class="mark" aria-hidden="true">M</div>
          <div><h1>MiniMax Code</h1><p class="subtle">Threads on this Mac</p></div>
        </div>
        <button id="close-threads" type="button">Close</button>
      </header>
      <div class="actions">
        <button id="new" type="button">New Thread</button>
        <button id="refresh" class="secondary" type="button">Refresh</button>
      </div>
      <div class="filter">
        <label class="sr" for="filter">Filter threads</label>
        <input id="filter" type="search" placeholder="Filter threads" autocomplete="off" aria-label="Filter threads">
      </div>
      <div id="threads" role="list" aria-label="Threads"><p class="subtle empty-threads">No threads yet.</p></div>
    </aside>
    <main>
      <header class="main-head">
        <button id="threads-toggle" type="button" aria-expanded="true" aria-controls="sidebar">Threads</button>
        <div class="titles">
          <h1 id="title">MiniMax Code</h1>
          <p class="subtle" id="detail">Choose a thread, or start a new one.</p>
        </div>
        <p id="status" role="status">Connecting…</p>
      </header>
      <p id="banner" class="banner" role="alert" hidden></p>
      <section id="messages" role="log" aria-live="polite" aria-relevant="additions">
        <div class="empty">
          <h2>No Thread Open</h2>
          <p>Choose a thread to continue, or start a new one.</p>
        </div>
      </section>
      <section class="composer">
        <label class="cwd">Folder <input id="cwd" aria-label="Folder" placeholder="Path on this Mac" value="" autocomplete="off" spellcheck="false"></label>
        <div class="prompt">
          <label class="sr" for="prompt">Message</label>
          <textarea id="prompt" placeholder="Message MiniMax Code"></textarea>
          <button id="send" type="button">Send</button>
        </div>
      </section>
    </main>
  </div>
  <script>
    (() => {
      const query = new URLSearchParams(location.search);
      const supplied = query.get('token');
      if (supplied) sessionStorage.setItem('clutchChatToken', supplied);
      const token = supplied || sessionStorage.getItem('clutchChatToken') || '';
      if (supplied) history.replaceState({}, '', location.pathname);
      const headers = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
      const app = document.querySelector('#app');
      const threads = document.querySelector('#threads');
      const messages = document.querySelector('#messages');
      const status = document.querySelector('#status');
      const title = document.querySelector('#title');
      const detail = document.querySelector('#detail');
      const banner = document.querySelector('#banner');
      const cwd = document.querySelector('#cwd');
      const prompt = document.querySelector('#prompt');
      const send = document.querySelector('#send');
      const toggle = document.querySelector('#threads-toggle');
      let connectionId = null;
      let remoteSessionId = null;
      let busy = false;

      const setStatus = (text) => { status.textContent = text; };
      const phone = () => window.matchMedia('(max-width: 800px)').matches;
      const setThreadsOpen = (open) => {
        app.classList.toggle('threads-closed', !open);
        toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      };
      const showBanner = (text) => {
        banner.hidden = false;
        banner.textContent = text;
        if (phone()) setThreadsOpen(false);
      };
      const hideBanner = () => { banner.hidden = true; banner.textContent = ''; };
      const showEmpty = (heading, copy) => {
        messages.replaceChildren();
        const wrap = document.createElement('div');
        wrap.className = 'empty';
        const h = document.createElement('h2');
        h.textContent = heading;
        const p = document.createElement('p');
        p.textContent = copy;
        wrap.append(h, p);
        messages.appendChild(wrap);
      };
      const addMessage = (kind, text) => {
        const empty = messages.querySelector('.empty');
        if (empty) empty.remove();
        const node = document.createElement('div');
        node.className = 'message ' + kind;
        node.textContent = text;
        messages.appendChild(node);
        messages.scrollTop = messages.scrollHeight;
      };
      const api = async (path, init = {}) => {
        const response = await fetch(path, { ...init, headers: { ...headers, ...(init.headers || {}) } });
        const body = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(body.error || ('Request failed (' + response.status + ')'));
        return body;
      };
      const stamp = (value) => {
        if (!value) return '';
        const date = new Date(value);
        return Number.isNaN(date.valueOf()) ? '' : date.toLocaleString();
      };
      let allThreads = [];
      const drawThreads = (items) => {
        const queryText = (document.querySelector('#filter').value || '').trim().toLowerCase();
        const visible = queryText
          ? items.filter((item) => [item.title || '', item.cwd || '', item.sessionId || ''].join(' ').toLowerCase().includes(queryText))
          : items;
        threads.replaceChildren();
        for (const item of visible) {
          const button = document.createElement('button');
          button.type = 'button';
          button.className = 'thread' + (item.sessionId === remoteSessionId ? ' active' : '');
          button.setAttribute('role', 'listitem');
          if (item.sessionId === remoteSessionId) button.setAttribute('aria-current', 'true');
          const name = document.createElement('strong');
          name.textContent = item.title || 'Untitled thread';
          const meta = document.createElement('span');
          meta.textContent = [item.cwd || 'No folder', stamp(item.updatedAt)].filter(Boolean).join(' · ');
          button.append(name, meta);
          button.addEventListener('click', () => loadThread(item));
          threads.appendChild(button);
        }
        if (!visible.length) {
          const note = document.createElement('p');
          note.className = 'subtle empty-threads';
          note.textContent = items.length ? 'No threads match.' : 'No threads yet.';
          threads.appendChild(note);
        }
      };
      const refresh = async () => {
        setStatus('Loading threads…');
        try {
          const body = await api('/clutch/v1/sessions?engine=mcode');
          allThreads = Array.isArray(body.sessions) ? body.sessions : [];
          drawThreads(allThreads);
          hideBanner();
          setStatus('Ready');
        } catch (error) {
          setStatus('Unavailable');
          showBanner(error.message);
        }
      };
      const loadThread = async (item) => {
        if (busy) return;
        busy = true;
        send.disabled = true;
        setThreadsOpen(false);
        setStatus('Loading messages…');
        try {
          const body = await api('/clutch/v1/sessions/load', {
            method: 'POST',
            body: JSON.stringify({ engine: 'mcode', sessionId: item.sessionId, cwd: item.cwd || cwd.value || undefined }),
          });
          connectionId = body.sessionId;
          remoteSessionId = item.sessionId;
          cwd.value = item.cwd || cwd.value;
          title.textContent = item.title || 'Untitled thread';
          detail.textContent = item.cwd || 'MiniMax Code thread';
          messages.replaceChildren();
          for (const update of body.history || []) {
            const kind = update.kind === 'user_message_chunk' ? 'user' : update.kind === 'agent_thought_chunk' ? 'thought' : 'agent';
            addMessage(kind, update.text || '');
          }
          if (!(body.history || []).length) showEmpty('No messages yet', 'Send a message to continue this thread.');
          hideBanner();
          setStatus('Ready');
          await refresh();
        } catch (error) {
          setStatus('Could not open thread');
          showBanner(error.message);
        } finally {
          busy = false;
          send.disabled = false;
        }
      };
      const newThread = () => {
        connectionId = null;
        remoteSessionId = null;
        title.textContent = 'New thread';
        detail.textContent = 'This thread starts when you send the first message.';
        showEmpty('New thread', 'Send a message to start this thread.');
        hideBanner();
        setThreadsOpen(false);
        prompt.focus();
        drawThreads(allThreads);
        refresh();
      };
      const consumeSse = async (response) => {
        if (!response.ok || !response.body) throw new Error('The message could not be sent (' + response.status + ').');
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let boundary;
          while ((boundary = buffer.indexOf('\\n\\n')) >= 0) {
            const block = buffer.slice(0, boundary);
            buffer = buffer.slice(boundary + 2);
            const event = /^event: (.+)$/m.exec(block)?.[1] || 'message';
            const raw = /^data: (.+)$/m.exec(block)?.[1];
            if (!raw) continue;
            const data = JSON.parse(raw);
            if (event === 'start') connectionId = data.sessionId;
            else if (event === 'message') addMessage('agent', data.text || '');
            else if (event === 'thought') addMessage('thought', data.text || '');
            else if (event === 'error') throw new Error(data.message || 'MiniMax Code could not finish that message.');
          }
        }
      };
      const sendPrompt = async () => {
        const text = prompt.value.trim();
        if (!text || busy) return;
        busy = true;
        send.disabled = true;
        prompt.value = '';
        addMessage('user', text);
        setStatus('MiniMax Code is working…');
        try {
          const response = await fetch('/clutch/v1/chat', {
            method: 'POST', headers,
            body: JSON.stringify({ engine: 'mcode', sessionId: connectionId, cwd: cwd.value || undefined, prompt: text }),
          });
          await consumeSse(response);
          hideBanner();
          setStatus('Ready');
          await refresh();
        } catch (error) {
          setStatus('Message failed');
          showBanner(error.message);
          addMessage('error', error.message);
        } finally {
          busy = false;
          send.disabled = false;
          prompt.focus();
        }
      };
      document.querySelector('#filter').addEventListener('input', () => drawThreads(allThreads));
      document.querySelector('#refresh').addEventListener('click', refresh);
      document.querySelector('#new').addEventListener('click', newThread);
      toggle.addEventListener('click', () => setThreadsOpen(app.classList.contains('threads-closed')));
      document.querySelector('#close-threads').addEventListener('click', () => setThreadsOpen(false));
      send.addEventListener('click', sendPrompt);
      prompt.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); sendPrompt(); }
      });
      if (phone()) setThreadsOpen(true);
      if (!token) {
        setStatus('Not signed in');
        showBanner('This page is not signed in.\\u00a0 Start Clutch on this Mac, then open MiniMax Code again.');
      } else {
        refresh();
      }
    })();
  </script>
</body>
</html>`;
}
