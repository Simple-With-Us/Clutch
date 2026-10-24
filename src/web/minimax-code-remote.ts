/** Browser shell for the direct MiniMax Code ACP remote. */
export function miniMaxCodeRemoteHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MiniMax Code Remote</title>
  <style>
    :root { color-scheme: light; font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; height: 100vh; overflow: hidden; color: #18212f; background: #f6f8fb; }
    button, input, textarea { font: inherit; }
    button { cursor: pointer; }
    .app { display: grid; grid-template-columns: 320px 1fr; height: 100%; }
    aside { display: flex; flex-direction: column; min-width: 0; border-right: 1px solid #dce2ea; background: #fff; }
    header { display: flex; align-items: center; gap: 10px; padding: 14px 16px; border-bottom: 1px solid #e8ecf1; }
    .mark { display: grid; place-items: center; width: 28px; height: 28px; border-radius: 8px; color: #fff; background: #111827; font-weight: 800; }
    h1 { margin: 0; font-size: 15px; }
    .subtle { color: #64748b; font-size: 12px; }
    .actions { display: flex; gap: 8px; padding: 12px; }
    .actions button, #send { border: 0; border-radius: 8px; padding: 9px 12px; color: #fff; background: #111827; }
    .actions button.secondary { color: #334155; background: #eef2f6; }
    #threads { overflow: auto; padding: 0 8px 12px; }
    .thread { width: 100%; margin: 2px 0; padding: 10px; border: 0; border-radius: 8px; text-align: left; color: inherit; background: transparent; }
    .thread:hover, .thread.active { background: #eef2ff; }
    .thread strong, .thread span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .thread span { margin-top: 3px; color: #64748b; font-size: 11px; }
    main { display: grid; grid-template-rows: auto 1fr auto; min-width: 0; }
    .main-head { justify-content: space-between; background: rgba(255,255,255,.88); }
    #status { color: #64748b; font-size: 12px; }
    #messages { overflow: auto; padding: 24px max(24px, 8vw); }
    .empty { max-width: 520px; margin: 18vh auto 0; text-align: center; color: #64748b; }
    .message { max-width: 850px; margin: 0 auto 16px; white-space: pre-wrap; line-height: 1.55; }
    .message.user { padding: 12px 14px; border-radius: 12px; background: #e9edff; }
    .message.thought { color: #64748b; font-size: 12px; }
    .message.error { color: #b42318; }
    .composer { padding: 14px max(24px, 8vw) 18px; border-top: 1px solid #dce2ea; background: #fff; }
    .cwd { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; color: #64748b; font-size: 12px; }
    .cwd input { flex: 1; min-width: 0; border: 0; outline: 0; color: #475569; }
    .prompt { display: flex; align-items: flex-end; gap: 10px; padding: 10px; border: 1px solid #cbd5e1; border-radius: 12px; background: #fff; }
    textarea { flex: 1; min-height: 44px; max-height: 180px; resize: vertical; border: 0; outline: 0; }
    #send:disabled { cursor: default; opacity: .45; }
    @media (max-width: 760px) { .app { grid-template-columns: 240px 1fr; } }
  </style>
</head>
<body>
  <div class="app">
    <aside>
      <header><div class="mark">M</div><div><h1>MiniMax Code</h1><div class="subtle">Existing local threads</div></div></header>
      <div class="actions"><button id="new">New Thread</button><button id="refresh" class="secondary">Refresh</button></div>
      <div style="padding:0 12px 10px"><input id="filter" type="search" placeholder="Filter threads" style="width:100%;padding:8px 10px;border:1px solid #dce2ea;border-radius:8px;outline:0"></div>
      <div id="threads"></div>
    </aside>
    <main>
      <header class="main-head"><div><h1 id="title">MiniMax Code Remote</h1><div class="subtle" id="detail">Select a thread or start a new one.\u00a0 ACP permission requests are allowed once.</div></div><div id="status">Connecting…</div></header>
      <section id="messages"><div class="empty">Choose an existing MiniMax Code thread to continue working in it.</div></section>
      <section class="composer">
        <label class="cwd">Working directory <input id="cwd" value=""></label>
        <div class="prompt"><textarea id="prompt" placeholder="Send instructions to MiniMax Code"></textarea><button id="send">Send</button></div>
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
      const threads = document.querySelector('#threads');
      const messages = document.querySelector('#messages');
      const status = document.querySelector('#status');
      const title = document.querySelector('#title');
      const detail = document.querySelector('#detail');
      const cwd = document.querySelector('#cwd');
      const prompt = document.querySelector('#prompt');
      const send = document.querySelector('#send');
      let connectionId = null;
      let remoteSessionId = null;
      let busy = false;

      const setStatus = (text) => { status.textContent = text; };
      const clearMessages = () => { messages.innerHTML = ''; };
      const addMessage = (kind, text) => {
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
        const query = (document.querySelector('#filter').value || '').trim().toLowerCase();
        const visible = query
          ? items.filter((item) => [item.title || '', item.cwd || '', item.sessionId || ''].join(' ').toLowerCase().includes(query))
          : items;
        threads.innerHTML = '';
        for (const item of visible) {
          const button = document.createElement('button');
          button.className = 'thread' + (item.sessionId === remoteSessionId ? ' active' : '');
          const name = document.createElement('strong');
          name.textContent = item.title || 'Untitled thread';
          const meta = document.createElement('span');
          meta.textContent = [item.cwd || '', stamp(item.updatedAt)].filter(Boolean).join(' · ');
          button.append(name, meta);
          button.addEventListener('click', () => loadThread(item));
          threads.appendChild(button);
        }
        if (!visible.length) threads.innerHTML = '<div class="subtle" style="padding:12px">' + (items.length ? 'No threads match the filter.' : 'No MiniMax Code threads found.') + '</div>';
      };
      const refresh = async () => {
        setStatus('Loading threads…');
        try {
          const body = await api('/clutch/v1/sessions?engine=mcode');
          allThreads = Array.isArray(body.sessions) ? body.sessions : [];
          drawThreads(allThreads);
          setStatus('Ready');
        } catch (error) {
          setStatus('Unavailable');
          clearMessages();
          addMessage('error', error.message);
        }
      };
      const loadThread = async (item) => {
        if (busy) return;
        busy = true;
        send.disabled = true;
        setStatus('Loading history…');
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
          clearMessages();
          for (const update of body.history || []) {
            const kind = update.kind === 'user_message_chunk' ? 'user' : update.kind === 'agent_thought_chunk' ? 'thought' : 'agent';
            addMessage(kind, update.text || '');
          }
          if (!(body.history || []).length) addMessage('thought', 'Thread loaded.');
          setStatus('Ready');
          await refresh();
        } catch (error) {
          setStatus('Load failed');
          addMessage('error', error.message);
        } finally {
          busy = false;
          send.disabled = false;
        }
      };
      const newThread = () => {
        connectionId = null;
        remoteSessionId = null;
        title.textContent = 'New MiniMax Code Thread';
        detail.textContent = 'The thread is created when you send the first instruction.\u00a0 ACP permission requests are allowed once.';
        clearMessages();
        prompt.focus();
        drawThreads(allThreads);
        refresh();
      };
      const consumeSse = async (response) => {
        if (!response.ok || !response.body) throw new Error('Chat request failed (' + response.status + ')');
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
            else if (event === 'error') throw new Error(data.message || 'MiniMax Code failed');
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
          setStatus('Ready');
          await refresh();
        } catch (error) {
          setStatus('Turn failed');
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
      send.addEventListener('click', sendPrompt);
      prompt.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); sendPrompt(); }
      });
      if (!token) {
        setStatus('Not paired');
        clearMessages();
        addMessage('error', 'Clutch could not read the chat token. Start the local Clutch service, then reopen MiniMax Code Remote.');
      } else {
        refresh();
      }
    })();
  </script>
</body>
</html>`;
}
