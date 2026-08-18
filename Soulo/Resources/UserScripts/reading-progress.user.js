// ==UserScript==
// @name Reading Progress Bar
// @description Shows a refined reading progress indicator at the top of every webpage.
// @namespace com.dkluge.soulo.examples.reading-progress
// @version 1.1.0
// @match *://*/*
// @grant GM_addStyle
// @run-at document-start
// ==/UserScript==

GM_addStyle(`
  #soulo-reading-progress {
    --soulo-progress: 0%;
    --soulo-progress-start: #31c7d4;
    --soulo-progress-middle: #4d86f7;
    --soulo-progress-end: #7657e8;
    position: fixed;
    inset: 0 0 auto;
    z-index: 2147483647;
    height: 3px;
    overflow: visible;
    pointer-events: none;
    opacity: 0;
    transform: translateZ(0);
    transition: opacity 220ms ease;
    contain: layout style paint;
  }

  #soulo-reading-progress.soulo-progress-visible { opacity: 1; }

  #soulo-reading-progress .soulo-progress-line {
    position: absolute;
    inset: 0 auto 0 0;
    width: var(--soulo-progress);
    border-radius: 0 999px 999px 0;
    background: linear-gradient(
      90deg,
      var(--soulo-progress-start) 0%,
      var(--soulo-progress-middle) 56%,
      var(--soulo-progress-end) 100%
    );
    box-shadow:
      0 1px 4px rgba(47, 118, 232, .3),
      0 0 10px rgba(77, 134, 247, .16);
    transition: width 90ms linear;
  }

  #soulo-reading-progress .soulo-progress-line::after {
    content: '';
    position: absolute;
    top: 50%;
    right: -2px;
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: #8c70f2;
    box-shadow:
      0 0 0 1px rgba(255, 255, 255, .72),
      0 0 9px rgba(92, 87, 235, .72);
    transform: translateY(-50%) scale(.82);
  }

  @media (prefers-color-scheme: dark) {
    #soulo-reading-progress {
      --soulo-progress-start: #48d9d1;
      --soulo-progress-middle: #6ea2ff;
      --soulo-progress-end: #9a7cff;
    }
    #soulo-reading-progress .soulo-progress-line {
      box-shadow:
        0 1px 5px rgba(88, 153, 255, .42),
        0 0 12px rgba(121, 104, 255, .24);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    #soulo-reading-progress,
    #soulo-reading-progress .soulo-progress-line { transition: none; }
  }
`);

let progress = null;
let scheduled = false;

function updateProgress() {
  scheduled = false;
  if (!progress) return;

  const root = document.documentElement;
  const body = document.body;
  const documentHeight = Math.max(
    root.scrollHeight,
    root.offsetHeight,
    body ? body.scrollHeight : 0,
    body ? body.offsetHeight : 0
  );
  const scrollable = Math.max(0, documentHeight - window.innerHeight);
  const currentScroll = window.scrollY || root.scrollTop || 0;
  const ratio = scrollable === 0 ? 0 : Math.min(1, Math.max(0, currentScroll / scrollable));

  progress.style.setProperty('--soulo-progress', `${ratio * 100}%`);
  progress.classList.toggle('soulo-progress-visible', scrollable > 24);
}

function scheduleUpdate() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(updateProgress);
}

function installProgress() {
  if (!document.documentElement) {
    document.addEventListener('DOMContentLoaded', installProgress, { once: true });
    return;
  }
  if (document.getElementById('soulo-reading-progress')) return;

  progress = document.createElement('div');
  progress.id = 'soulo-reading-progress';
  progress.setAttribute('role', 'progressbar');
  progress.setAttribute('aria-hidden', 'true');

  const line = document.createElement('div');
  line.className = 'soulo-progress-line';
  progress.appendChild(line);
  document.documentElement.appendChild(progress);

  addEventListener('scroll', scheduleUpdate, { passive: true });
  addEventListener('resize', scheduleUpdate, { passive: true });

  if ('ResizeObserver' in window) {
    new ResizeObserver(scheduleUpdate).observe(document.documentElement);
  } else {
    new MutationObserver(scheduleUpdate).observe(document.documentElement, {
      childList: true,
      subtree: true
    });
  }
  scheduleUpdate();
}

installProgress();
