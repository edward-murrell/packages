// Landing page behaviour. Copied to site/site.js by scripts/build-repo.sh.
(function () {
  'use strict';

  // Navigation: solid background once scrolled
  const nav = document.getElementById('nav');
  if (nav) {
    const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 20);
    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }

  // Mobile menu
  const toggle = document.getElementById('navToggle');
  const menu = document.getElementById('navMenu');
  if (toggle && menu) {
    const setOpen = (open) => {
      menu.classList.toggle('open', open);
      toggle.classList.toggle('open', open);
      toggle.setAttribute('aria-expanded', String(open));
    };
    toggle.addEventListener('click', () => setOpen(!menu.classList.contains('open')));
    menu.addEventListener('click', (e) => { if (e.target.closest('a')) setOpen(false); });
    document.addEventListener('click', (e) => { if (nav && !nav.contains(e.target)) setOpen(false); });
  }

  // Copy buttons on code blocks (copies the text without prompts or comments)
  document.querySelectorAll('.codeblock').forEach((block) => {
    const btn = block.querySelector('.copy-btn');
    const code = block.querySelector('code');
    if (!btn || !code || !navigator.clipboard) { if (btn) btn.hidden = true; return; }
    btn.addEventListener('click', () => {
      const clone = code.cloneNode(true);
      clone.querySelectorAll('.prompt, .comment').forEach((el) => el.remove());
      const text = clone.textContent.split('\n').map((l) => l.trimEnd()).join('\n').trim();
      navigator.clipboard.writeText(text).then(() => {
        btn.classList.add('copied');
        setTimeout(() => btn.classList.remove('copied'), 1500);
      });
    });
  });

  // Scroll reveal
  const items = document.querySelectorAll('[data-reveal]');
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('revealed');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.08, rootMargin: '0px 0px -32px 0px' });
    items.forEach((el) => observer.observe(el));
  } else {
    items.forEach((el) => el.classList.add('revealed'));
  }
})();
