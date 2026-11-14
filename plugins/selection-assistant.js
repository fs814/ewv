// Selection assistant, after appine's plugin of the same name: select text on
// a page and a small toolbar appears next to the mouse.
//
//   Translate  ask the configured AI model for a translation
//   Ask AI     chat about the selection
//   Capture    org-capture the selection with the page's URL and title
//   Search     search the web for the selection, in a new ewv buffer
//
// ewv-plugins.el wraps this file in `(function (EWV) { ... })(config)` and has
// the webview run it at the start of every document.  Unlike appine's version
// this script does none of the work itself: every button posts a request to
// Emacs, which holds the API key and the settings and posts the answer back.
// The requests carry EWV.token, which only this closure knows, so a page
// cannot forge them.
//
// The widgets live in a closed shadow tree, styled with a constructed style
// sheet and built without HTML strings: the page's CSS, CSP and Trusted Types
// policy do not reach them.

if (window.top !== window) return;
const webview = window.chrome && window.chrome.webview;
if (!webview) return;
// Bound now, before any page script could replace it.
const post = webview.postMessage.bind(webview);
const send = message => post(Object.assign({ token: EWV.token }, message));

const MAX_TEXT = 20000;
const STYLE = `
:host { all: initial; }
.bar, .panel {
  position: absolute; display: none; box-sizing: border-box;
  font: 13px/1.4 "Segoe UI", system-ui, sans-serif; color: #1d1d1f; background: #fff;
  border: 1px solid #d0d0d5; border-radius: 10px; box-shadow: 0 8px 24px rgba(0, 0, 0, .18);
  user-select: none; text-align: left;
}
.bar.on { display: flex; padding: 4px; gap: 2px; white-space: nowrap; }
.panel.on { display: flex; flex-direction: column; width: 420px; max-width: calc(100vw - 24px); }
button { font: inherit; color: inherit; border: 0; background: transparent; padding: 6px 10px; border-radius: 6px; cursor: pointer; }
button:hover { background: rgba(120, 120, 128, .16); }
.head { display: flex; align-items: center; padding: 6px 6px 6px 14px; font-weight: 600; border-bottom: 1px solid #e3e3e8; }
.head span { flex: 1; }
.log { max-height: 320px; min-height: 48px; overflow-y: auto; padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; user-select: text; cursor: auto; }
.msg { white-space: pre-wrap; overflow-wrap: anywhere; }
.msg.user { align-self: flex-end; background: rgba(120, 120, 128, .16); padding: 6px 10px; border-radius: 12px; max-width: 85%; }
.msg.pending { color: #8a8a90; }
.msg.error { color: #d93025; }
.quote { color: #6e6e73; font-size: 12px; border-left: 3px solid #d0d0d5; padding-left: 8px; max-height: 4.2em; overflow: hidden; }
textarea { font: inherit; color: inherit; background: transparent; border: 1px solid #d0d0d5; border-radius: 8px; margin: 0 12px 12px; padding: 8px 10px; resize: none; outline: none; height: 56px; }
textarea:focus { border-color: #0a64d6; }
@media (prefers-color-scheme: dark) {
  .bar, .panel { color: #f2f2f4; background: #2a2a2d; border-color: #48484d; }
  .head { border-bottom-color: #48484d; }
  .quote, textarea { border-color: #48484d; }
  .quote { color: #a1a1a8; }
  textarea:focus { border-color: #58a6ff; }
  .msg.error { color: #ff7b72; }
}`;

let host = null, root = null, bar = null, panel = null, title = null, log = null, input = null;
let text = '';              // the selection the toolbar is about
let rect = null;            // where it is, in viewport coordinates
let mouse = { x: 0, y: 0 }; // where the mouse button went up, in page coordinates
let hideTimer = null;
let chat = null;            // { kind, context, messages, id, pending, waiting }
let nextId = 1;

function el(tag, cls, content) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (content !== undefined) e.textContent = content;
  return e;
}

function button(label, action) {
  const b = el('button', '', label);
  b.addEventListener('click', e => { e.preventDefault(); action(); });
  return b;
}

function build() {
  if (!document.documentElement) return false;
  if (!host) {
    host = el('div');
    host.setAttribute('data-ewv-ui', '');
    Object.assign(host.style, { position: 'absolute', left: '0', top: '0', width: '0', height: '0', zIndex: '2147483647' });
    root = host.attachShadow({ mode: 'closed' });
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(STYLE);
    root.adoptedStyleSheets = [sheet];

    bar = el('div', 'bar');
    if (EWV.translate) bar.append(button('🌐 Translate', () => openPanel('translate')));
    if (EWV.ask) bar.append(button('✨ Ask AI', () => openPanel('ask')));
    if (EWV.capture) bar.append(button('📝 Capture', capture));
    if (EWV.search) bar.append(button('🔍 Search', search));
    // Keep the click from moving the focus or collapsing the selection.
    bar.addEventListener('mousedown', e => e.preventDefault());
    bar.addEventListener('mouseenter', () => clearTimeout(hideTimer));

    panel = el('div', 'panel');
    const head = el('div', 'head');
    title = el('span');
    head.append(title, button('✕', hideAll));
    log = el('div', 'log');
    input = el('textarea');
    input.placeholder = 'Ask about the selection… (Enter to send)';
    panel.append(head, log, input);
    root.append(bar, panel);
  }
  // A page that rewrites its document drops our element: put it back.
  if (!host.isConnected) document.documentElement.appendChild(host);
  return true;
}

// Show ELEMENT with its top left corner at page coordinates X, Y, moved as
// needed to stay inside the viewport.
function place(element, x, y, flipY) {
  element.classList.add('on');
  const w = element.offsetWidth, h = element.offsetHeight;
  const minX = window.scrollX + 8, maxX = window.scrollX + document.documentElement.clientWidth - w - 8;
  const minY = window.scrollY + 8, maxY = window.scrollY + window.innerHeight - h - 8;
  if (y > maxY && flipY !== undefined) y = flipY - h;
  element.style.left = Math.max(minX, Math.min(x, maxX)) + 'px';
  element.style.top = Math.max(minY, Math.min(y, maxY)) + 'px';
}

function hideBar() {
  clearTimeout(hideTimer);
  if (bar) bar.classList.remove('on');
}

function hideAll() {
  hideBar();
  if (panel) panel.classList.remove('on');
  chat = null;   // an answer still on its way is dropped
}

function showBar() {
  if (!build() || bar.childElementCount === 0) return;
  panel.classList.remove('on');
  chat = null;
  place(bar, mouse.x - 100, mouse.y + 15, mouse.y - 15);
  clearTimeout(hideTimer);
  hideTimer = setTimeout(hideBar, 3000);
}

function capture() {
  send({ op: 'capture', url: location.href, title: document.title, body: text });
  hideAll();
}

function search() {
  send({ op: 'search', text: text.slice(0, 500) });
  hideAll();
}

function request() {
  chat.id = String(nextId++);
  chat.waiting = true;
  chat.pending = el('div', 'msg pending', chat.kind === 'translate' ? 'Translating…' : 'Thinking…');
  log.append(chat.pending);
  log.scrollTop = log.scrollHeight;
  send({ op: 'assistant', id: chat.id, kind: chat.kind, text: chat.context, messages: chat.messages });
}

function openPanel(kind) {
  hideBar();
  chat = { kind, context: text, messages: [], id: null, pending: null, waiting: false };
  title.textContent = kind === 'translate' ? '🌐 Translate' : '✨ Ask AI';
  log.textContent = '';
  input.style.display = kind === 'ask' ? '' : 'none';
  input.value = '';
  if (kind === 'ask') log.append(el('div', 'quote', text.slice(0, 400)));
  const below = window.scrollY + rect.bottom + 10;
  place(panel, window.scrollX + rect.left, below, window.scrollY + rect.top - 10);
  if (kind === 'translate') request(); else input.focus();
}

function ask() {
  const question = input.value.trim();
  if (!chat || chat.waiting || !question) return;
  input.value = '';
  chat.messages.push({ role: 'user', content: question });
  log.append(el('div', 'msg user', question));
  request();
}

webview.addEventListener('message', e => {
  const m = e.data;
  if (!m || m.type !== 'ewv-assistant' || !chat || m.id !== chat.id) return;
  chat.waiting = false;
  chat.pending.classList.remove('pending');
  if (m.error) {
    chat.pending.classList.add('error');
    chat.pending.textContent = m.error;
    if (chat.kind === 'ask') chat.messages.pop();   // so the question can be asked again
  } else {
    chat.pending.textContent = m.text;
    if (chat.kind === 'ask') chat.messages.push({ role: 'assistant', content: m.text });
  }
  log.scrollTop = log.scrollHeight;
});

// Events from inside the shadow tree reach the page's listeners with our host
// element as their target.
const fromUs = e => host !== null && e.target === host;

window.addEventListener('mouseup', e => {
  if (fromUs(e)) return;
  mouse = { x: e.pageX, y: e.pageY };
  setTimeout(() => {
    const selection = window.getSelection();
    const selected = selection && selection.rangeCount > 0 ? selection.toString().trim() : '';
    if (selected) {
      text = selected.slice(0, MAX_TEXT);
      rect = selection.getRangeAt(0).getBoundingClientRect();
      showBar();
    } else {
      hideAll();
    }
  }, 50);
}, true);

// Typing in our box must not trigger the page's keyboard shortcuts.  This
// listener was added before any of the page's, so it runs first.
for (const type of ['keydown', 'keyup', 'keypress']) {
  window.addEventListener(type, e => {
    if (!fromUs(e)) return;
    e.stopImmediatePropagation();
    if (type !== 'keydown') return;
    if (e.key === 'Escape') {
      hideAll();
    } else if (e.key === 'Enter' && !e.shiftKey && root.activeElement === input) {
      e.preventDefault();
      ask();
    }
  }, true);
}
