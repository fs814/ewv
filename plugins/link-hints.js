// Link hints, after appine's plugin of the same name (and Vimium): press the
// trigger key, every link and control in view gets a letter label, type a
// label to click it.  Esc, or any key that is not a label letter, cancels;
// Backspace takes back a letter.
//
// ewv-plugins.el wraps this file in `(function (EWV) { ... })(config)` and has
// the webview run it at the start of every document, before the page's own
// scripts.  EWV.key is the trigger key.  Emacs can also start the hints with
// a web message (M-x ewv-plugins-link-hints).
//
// Pages may forbid inline styles and HTML strings (CSP, Trusted Types), so the
// labels are built with createElement and styled through element.style only.

if (window.top !== window) return;

const HINT_KEYS = 'ASDFGHJKLQWERTYUIOP';
const SELECTOR = 'a[href], button, input:not([type="hidden"]), textarea, select, summary, ' +
                 '[role="button"], [role="link"], [role="tab"], [onclick], [tabindex]:not([tabindex="-1"])';

let hints = [];        // { label, el, tag }
let layer = null;
let typed = '';

function visible(el) {
  const r = el.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) return false;
  if (r.bottom <= 0 || r.top >= window.innerHeight || r.right <= 0 || r.left >= window.innerWidth) return false;
  const style = window.getComputedStyle(el);
  return style.display !== 'none' && style.visibility !== 'hidden' &&
         style.opacity !== '0' && style.pointerEvents !== 'none';
}

// Labels no one of which is the prefix of another, so typing one is never
// ambiguous: keep replacing the shortest label by its one-letter extensions.
function makeLabels(count) {
  const labels = [''];
  let offset = 0;
  while (labels.length - offset < count || labels.length === 1) {
    const prefix = labels[offset++];
    for (const ch of HINT_KEYS) labels.push(prefix + ch);
  }
  return labels.slice(offset, offset + count);
}

function show() {
  clear();
  if (!document.documentElement) return;
  const targets = [...document.querySelectorAll(SELECTOR)].filter(visible);
  if (targets.length === 0) return;
  const labels = makeLabels(targets.length);
  layer = document.createElement('div');
  layer.setAttribute('data-ewv-ui', '');
  Object.assign(layer.style, { position: 'absolute', left: '0', top: '0', zIndex: '2147483647', pointerEvents: 'none' });
  targets.forEach((el, i) => {
    const r = el.getBoundingClientRect();
    const tag = document.createElement('div');
    Object.assign(tag.style, {
      position: 'absolute',
      left: (window.scrollX + Math.max(0, r.left)) + 'px',
      top: (window.scrollY + Math.max(0, r.top)) + 'px',
      background: '#ffeb3b', color: '#000', font: 'bold 12px/1.2 Consolas, monospace',
      padding: '1px 4px', borderRadius: '3px', border: '1px solid #f57f17',
      boxShadow: '0 2px 4px rgba(0,0,0,.2)', whiteSpace: 'nowrap', textTransform: 'none', letterSpacing: '0',
    });
    layer.appendChild(tag);
    hints.push({ label: labels[i], el, tag });
  });
  document.documentElement.appendChild(layer);
  typed = '';
  render();
}

function clear() {
  if (layer) layer.remove();
  layer = null;
  hints = [];
  typed = '';
}

function render() {
  for (const h of hints) {
    const match = h.label.startsWith(typed);
    h.tag.style.display = match ? 'block' : 'none';
    if (!match) continue;
    h.tag.textContent = '';
    const done = document.createElement('span');
    done.style.opacity = '0.4';
    done.textContent = typed;
    h.tag.append(done, h.label.slice(typed.length));
  }
}

function activate(el) {
  const editable = el.matches('input:not([type="button"]):not([type="submit"]):not([type="checkbox"]):not([type="radio"]):not([type="reset"]), textarea, select') || el.isContentEditable;
  if (editable) el.focus(); else el.click();
}

function type(key) {
  key = key.toUpperCase();
  if (!HINT_KEYS.includes(key)) return clear();
  typed += key;
  const left = hints.filter(h => h.label.startsWith(typed));
  if (left.length === 0) return clear();
  if (left.length === 1) {
    const el = left[0].el;
    clear();
    activate(el);
    return;
  }
  render();
}

function isTyping(e) {
  const t = e.target;
  if (!t || !t.tagName) return false;
  // Our own widgets (the selection assistant) mark their host element.
  if (t.hasAttribute && t.hasAttribute('data-ewv-ui')) return true;
  return t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable;
}

window.addEventListener('keydown', e => {
  if (!layer) {
    if (e.key === EWV.key && !e.ctrlKey && !e.altKey && !e.metaKey && !isTyping(e)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      show();
    }
    return;
  }
  e.preventDefault();
  e.stopImmediatePropagation();
  if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
  if (e.key === 'Escape') return clear();
  if (e.key === 'Backspace') {
    if (typed.length === 0) return clear();
    typed = typed.slice(0, -1);
    return render();
  }
  type(e.key);
}, true);

// The labels sit at page coordinates: they go stale when the view moves.
window.addEventListener('scroll', () => { if (layer) clear(); }, true);
window.addEventListener('resize', () => { if (layer) clear(); });

if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener('message', e => {
    if (e.data && e.data.type === 'ewv-link-hints') show();
  });
}
