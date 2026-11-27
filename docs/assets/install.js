// Install method tabs and copy buttons.
const tabs = [...document.querySelectorAll('.tab')];
function select(tab) {
  tabs.forEach(t => {
    const on = t === tab;
    t.setAttribute('aria-selected', on);
    t.tabIndex = on ? 0 : -1;
    document.getElementById(t.getAttribute('aria-controls')).classList.toggle('active', on);
  });
}
tabs.forEach((t, i) => {
  t.addEventListener('click', () => select(t));
  t.addEventListener('keydown', e => {
    const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
    if (!d) return;
    const n = tabs[(i + d + tabs.length) % tabs.length];
    select(n); n.focus();
  });
});
const fromHash = { '#homebrew': 't-brew', '#one-line': 't-curl', '#from-source': 't-src', '#download': 't-dmg' }[location.hash];
if (fromHash) select(document.getElementById(fromHash));

// Copies the commands without the "$ " prompts.
document.querySelectorAll('.copy').forEach(b => b.addEventListener('click', async () => {
  const pre = b.parentElement.querySelector('pre').cloneNode(true);
  pre.querySelectorAll('.p, .c').forEach(p => p.remove());
  try { await navigator.clipboard.writeText(pre.textContent.split('\n').map(l => l.trimEnd()).join('\n').trim()); b.textContent = 'Copied'; }
  catch { b.textContent = 'Press ⌘C'; }
  setTimeout(() => b.textContent = 'Copy', 1600);
}));
