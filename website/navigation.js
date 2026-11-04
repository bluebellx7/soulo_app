(() => {
  'use strict';
  const header = document.querySelector('[data-shared-nav]');
  const button = header?.querySelector('.nav-menu-toggle');
  const links = header?.querySelector('.nav-links');
  if (!button || !links) return;
  const compact = matchMedia('(max-width: 1080px)');
  function setExpanded(expanded, restoreFocus = false) {
    header.classList.toggle('is-menu-open', expanded);
    button.setAttribute('aria-expanded', String(expanded));
    if (restoreFocus) button.focus({preventScroll: true});
  }
  button.addEventListener('click', () => setExpanded(button.getAttribute('aria-expanded') !== 'true'));
  links.addEventListener('click', event => {
    if (event.target.closest('a')) setExpanded(false);
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && button.getAttribute('aria-expanded') === 'true') {
      setExpanded(false, true);
    }
  });
  document.addEventListener('pointerdown', event => {
    if (!header.contains(event.target)) setExpanded(false);
  });
  compact.addEventListener('change', () => setExpanded(false));
  header.classList.add('is-enhanced');
})();
