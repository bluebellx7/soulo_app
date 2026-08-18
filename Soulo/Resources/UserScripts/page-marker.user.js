// ==UserScript==
// @name Area Text Extractor
// @description Tap the movable button, then tap any page area to extract and copy its visible text.
// @namespace com.dkluge.soulo.examples.page-marker
// @version 2.0.0
// @match *://*/*
// @grant GM_addStyle
// @grant GM_getValue
// @grant GM_setValue
// @grant GM_setClipboard
// @grant GM_registerMenuCommand
// @run-at document-end
// ==/UserScript==

(() => {
  'use strict';

  if (window.__souloAreaTextExtractorInstalled) return;
  window.__souloAreaTextExtractorInstalled = true;

  const hostID = 'soulo-area-text-extractor-host';
  const targetClass = 'soulo-area-text-extractor-target';
  const pickedClass = 'soulo-area-text-extractor-picked';
  const positionKey = 'soulo:area-text-extractor:button-position';
  const dragPadding = 10;

  const translations = {
    en: { title: 'Area Text Extractor', start: 'Tap a page area to extract its text', cancel: 'Cancel extraction', result: 'Extracted text', copy: 'Copy text', again: 'Select again', close: 'Close', empty: 'No visible text was found in this area.', copied: 'Text copied', chars: 'characters', tag: 'Area' },
    'zh-CN': { title: '区域文字提取', start: '点击网页中的任一区域提取文字', cancel: '取消提取', result: '提取的文字', copy: '复制文字', again: '重新选择', close: '关闭', empty: '这个区域没有可提取的可见文字。', copied: '文字已复制', chars: '个字符', tag: '区域' },
    'zh-TW': { title: '區域文字擷取', start: '點擊網頁中的任一區域擷取文字', cancel: '取消擷取', result: '擷取的文字', copy: '複製文字', again: '重新選擇', close: '關閉', empty: '此區域沒有可擷取的可見文字。', copied: '文字已複製', chars: '個字元', tag: '區域' },
    ja: { title: '範囲テキスト抽出', start: 'ページ内の範囲をタップしてテキストを抽出', cancel: '抽出をキャンセル', result: '抽出したテキスト', copy: 'テキストをコピー', again: 'もう一度選択', close: '閉じる', empty: 'この範囲に表示テキストがありません。', copied: 'コピーしました', chars: '文字', tag: '範囲' },
    ko: { title: '영역 텍스트 추출', start: '페이지 영역을 눌러 텍스트를 추출하세요', cancel: '추출 취소', result: '추출된 텍스트', copy: '텍스트 복사', again: '다시 선택', close: '닫기', empty: '이 영역에 표시된 텍스트가 없습니다.', copied: '텍스트 복사됨', chars: '자', tag: '영역' },
    fr: { title: 'Extracteur de texte', start: 'Touchez une zone pour en extraire le texte', cancel: 'Annuler l’extraction', result: 'Texte extrait', copy: 'Copier le texte', again: 'Resélectionner', close: 'Fermer', empty: 'Aucun texte visible dans cette zone.', copied: 'Texte copié', chars: 'caractères', tag: 'Zone' },
    de: { title: 'Bereichstext extrahieren', start: 'Bereich antippen, um sichtbaren Text zu extrahieren', cancel: 'Extraktion abbrechen', result: 'Extrahierter Text', copy: 'Text kopieren', again: 'Neu auswählen', close: 'Schließen', empty: 'In diesem Bereich wurde kein sichtbarer Text gefunden.', copied: 'Text kopiert', chars: 'Zeichen', tag: 'Bereich' },
    es: { title: 'Extractor de texto', start: 'Toca un área para extraer su texto', cancel: 'Cancelar extracción', result: 'Texto extraído', copy: 'Copiar texto', again: 'Elegir de nuevo', close: 'Cerrar', empty: 'No hay texto visible en esta área.', copied: 'Texto copiado', chars: 'caracteres', tag: 'Área' },
    it: { title: 'Estrai testo area', start: 'Tocca un’area per estrarne il testo', cancel: 'Annulla estrazione', result: 'Testo estratto', copy: 'Copia testo', again: 'Seleziona di nuovo', close: 'Chiudi', empty: 'Nessun testo visibile in quest’area.', copied: 'Testo copiato', chars: 'caratteri', tag: 'Area' },
    pt: { title: 'Extrator de texto', start: 'Toque em uma área para extrair o texto', cancel: 'Cancelar extração', result: 'Texto extraído', copy: 'Copiar texto', again: 'Selecionar novamente', close: 'Fechar', empty: 'Nenhum texto visível nesta área.', copied: 'Texto copiado', chars: 'caracteres', tag: 'Área' },
    ru: { title: 'Извлечение текста', start: 'Нажмите область страницы, чтобы извлечь текст', cancel: 'Отменить извлечение', result: 'Извлечённый текст', copy: 'Копировать текст', again: 'Выбрать снова', close: 'Закрыть', empty: 'В этой области нет видимого текста.', copied: 'Текст скопирован', chars: 'символов', tag: 'Область' },
    tr: { title: 'Alan metni çıkarıcı', start: 'Metnini çıkarmak için sayfadaki bir alana dokunun', cancel: 'Çıkarmayı iptal et', result: 'Çıkarılan metin', copy: 'Metni kopyala', again: 'Yeniden seç', close: 'Kapat', empty: 'Bu alanda görünür metin bulunamadı.', copied: 'Metin kopyalandı', chars: 'karakter', tag: 'Alan' },
    vi: { title: 'Trích xuất văn bản', start: 'Chạm vào một vùng để trích xuất văn bản', cancel: 'Hủy trích xuất', result: 'Văn bản đã trích xuất', copy: 'Sao chép văn bản', again: 'Chọn lại', close: 'Đóng', empty: 'Không có văn bản hiển thị trong vùng này.', copied: 'Đã sao chép văn bản', chars: 'ký tự', tag: 'Vùng' },
    ar: { title: 'استخراج نص المنطقة', start: 'اضغط على أي منطقة لاستخراج نصها', cancel: 'إلغاء الاستخراج', result: 'النص المستخرج', copy: 'نسخ النص', again: 'تحديد مرة أخرى', close: 'إغلاق', empty: 'لا يوجد نص ظاهر في هذه المنطقة.', copied: 'تم نسخ النص', chars: 'حرف', tag: 'المنطقة' },
    th: { title: 'ดึงข้อความจากพื้นที่', start: 'แตะพื้นที่บนหน้าเพื่อดึงข้อความ', cancel: 'ยกเลิกการดึงข้อความ', result: 'ข้อความที่ดึงมา', copy: 'คัดลอกข้อความ', again: 'เลือกใหม่', close: 'ปิด', empty: 'ไม่พบข้อความที่มองเห็นในพื้นที่นี้', copied: 'คัดลอกข้อความแล้ว', chars: 'อักขระ', tag: 'พื้นที่' }
  };

  const language = (() => {
    const raw = String(navigator.language || 'en');
    if (/^zh-(TW|HK|MO)/i.test(raw)) return 'zh-TW';
    if (/^zh/i.test(raw)) return 'zh-CN';
    const short = raw.split('-')[0].toLowerCase();
    return translations[short] ? short : 'en';
  })();
  const text = translations[language] || translations.en;
  const icons = {
    scan: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 4H5a1 1 0 0 0-1 1v3M16 4h3a1 1 0 0 1 1 1v3M8 20H5a1 1 0 0 1-1-1v-3M16 20h3a1 1 0 0 0 1-1v-3"/><path d="M8 9h8M8 12h8M8 15h5"/></svg>',
    copy: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>',
    close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg>',
    again: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/></svg>'
  };

  GM_addStyle(`
    .${targetClass} {
      outline: 3px solid rgba(255, 174, 44, .95) !important;
      outline-offset: 3px !important;
      background-color: rgba(255, 196, 65, .12) !important;
      cursor: crosshair !important;
    }
    .${pickedClass} { animation: soulo-area-picked 520ms ease-out !important; }
    @keyframes soulo-area-picked {
      0%, 100% { outline-color: transparent; }
      35% { outline: 4px solid rgba(255, 174, 44, .95); outline-offset: 4px; }
    }
  `);

  const host = document.createElement('div');
  host.id = hostID;
  host.setAttribute('data-soulo-ui', 'area-text-extractor');
  host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;contain:layout style;';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `
    <style>
      :host { all: initial; color-scheme: light dark; }
      *, *::before, *::after { box-sizing: border-box; }
      button { -webkit-tap-highlight-color: transparent; }
      svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
      .launcher, .guide, .panel, .toast { pointer-events: auto; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
      .launcher {
        position: fixed; right: max(18px, env(safe-area-inset-right)); bottom: max(112px, calc(env(safe-area-inset-bottom) + 88px));
        display: grid; place-items: center; width: 50px; height: 50px; padding: 0; border: 1px solid rgba(255,255,255,.58); border-radius: 17px;
        color: #302617; background: linear-gradient(145deg, rgba(255,226,143,.98), rgba(255,177,47,.98));
        box-shadow: 0 14px 34px rgba(71,48,10,.28), inset 0 1px 0 rgba(255,255,255,.72); cursor: grab; touch-action: none;
        transition: transform 160ms ease, box-shadow 160ms ease, border-radius 160ms ease;
      }
      .launcher.active { color: #fff; background: linear-gradient(145deg, #ffad24, #ef7f17); border-radius: 50%; box-shadow: 0 15px 36px rgba(204,103,15,.38), 0 0 0 5px rgba(255,169,48,.2); }
      .launcher.dragging { cursor: grabbing; transform: scale(1.06); transition: none; }
      .launcher:active { transform: scale(.95); }
      .launcher:focus-visible, .icon-button:focus-visible, .action:focus-visible { outline: 3px solid rgba(255,174,35,.48); outline-offset: 3px; }
      .guide {
        position: fixed; top: max(16px, env(safe-area-inset-top)); left: 50%; display: none; align-items: center; gap: 9px;
        max-width: calc(100vw - 30px); padding: 11px 15px; border: 1px solid rgba(255,255,255,.15); border-radius: 999px;
        color: #fff; background: rgba(27,28,31,.92); box-shadow: 0 12px 35px rgba(0,0,0,.25); backdrop-filter: blur(22px) saturate(145%);
        font: 650 13px/1.25 -apple-system, sans-serif; transform: translateX(-50%); animation: soulo-guide-in 180ms ease both;
      }
      .guide.visible { display: flex; }
      .guide svg { flex: 0 0 auto; width: 18px; height: 18px; color: #ffc65c; }
      .panel {
        position: fixed; left: 50%; bottom: max(24px, calc(env(safe-area-inset-bottom) + 16px)); display: none;
        width: min(520px, calc(100vw - 28px)); max-height: min(620px, calc(100vh - 60px)); overflow: hidden;
        border: 1px solid rgba(110,102,87,.18); border-radius: 25px; color: #26272a; background: rgba(250,249,246,.97);
        box-shadow: 0 26px 80px rgba(28,25,18,.29); backdrop-filter: blur(30px) saturate(150%); transform: translateX(-50%);
        animation: soulo-panel-in 220ms cubic-bezier(.2,.8,.2,1) both;
      }
      .panel.visible { display: block; }
      .header { display: flex; align-items: center; gap: 11px; padding: 16px 15px 13px 18px; border-bottom: 1px solid rgba(50,50,45,.09); }
      .badge { display: grid; place-items: center; width: 36px; height: 36px; border-radius: 12px; color: #5d4318; background: #ffe3a0; }
      .heading { flex: 1; min-width: 0; }
      .title { margin: 0; font: 750 16px/1.2 -apple-system, sans-serif; letter-spacing: -.01em; }
      .meta { margin-top: 3px; overflow: hidden; color: #79756d; font: 500 11px/1.2 -apple-system, sans-serif; text-overflow: ellipsis; white-space: nowrap; }
      .icon-button { display: grid; place-items: center; width: 36px; height: 36px; padding: 0; border: 0; border-radius: 11px; color: #68655f; background: transparent; cursor: pointer; }
      .icon-button:active { transform: scale(.92); background: rgba(45,43,37,.08); }
      .preview { max-height: min(420px, calc(100vh - 240px)); min-height: 120px; overflow: auto; margin: 0; padding: 18px; overscroll-behavior: contain; color: #2f3032; background: transparent; font: 500 15px/1.65 -apple-system, sans-serif; white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; -webkit-user-select: text; }
      .footer { display: grid; grid-template-columns: 1fr 1.4fr; gap: 9px; padding: 12px 14px max(14px, env(safe-area-inset-bottom)); border-top: 1px solid rgba(50,50,45,.09); }
      .action { display: flex; align-items: center; justify-content: center; gap: 8px; min-height: 44px; padding: 0 14px; border: 0; border-radius: 13px; color: #4f4d48; background: rgba(46,43,35,.07); font: 700 13px/1 -apple-system, sans-serif; cursor: pointer; }
      .action.primary { color: #332817; background: linear-gradient(145deg, #ffe08c, #ffb83e); }
      .action:active { transform: scale(.97); }
      .toast { position: fixed; left: 50%; bottom: max(38px, calc(env(safe-area-inset-bottom) + 22px)); display: none; padding: 10px 14px; border-radius: 999px; color: #fff; background: rgba(28,29,32,.94); box-shadow: 0 10px 30px rgba(0,0,0,.24); font: 650 12px/1 -apple-system, sans-serif; transform: translateX(-50%); }
      .toast.visible { display: block; animation: soulo-toast-in 170ms ease both; }
      @media (prefers-color-scheme: dark) {
        .panel { color: #f0efec; background: rgba(31,32,34,.97); border-color: rgba(255,255,255,.1); }
        .header, .footer { border-color: rgba(255,255,255,.09); }
        .meta { color: #aaa79f; }
        .preview { color: #efeeeb; }
        .icon-button { color: #c1beb7; }
        .action { color: #dedbd4; background: rgba(255,255,255,.08); }
      }
      @media (max-width: 520px) { .preview { max-height: min(390px, calc(100vh - 230px)); } }
      @media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation: none !important; transition: none !important; } }
      @keyframes soulo-guide-in { from { opacity: 0; transform: translate(-50%, -8px); } to { opacity: 1; transform: translate(-50%, 0); } }
      @keyframes soulo-panel-in { from { opacity: 0; transform: translate(-50%, 12px) scale(.97); } to { opacity: 1; transform: translate(-50%, 0) scale(1); } }
      @keyframes soulo-toast-in { from { opacity: 0; transform: translate(-50%, 6px); } to { opacity: 1; transform: translate(-50%, 0); } }
    </style>
    <button class="launcher" type="button" aria-label="${text.title}" title="${text.title}">${icons.scan}</button>
    <div class="guide" role="status">${icons.scan}<span>${text.start}</span></div>
    <section class="panel" role="dialog" aria-modal="false" aria-label="${text.result}">
      <header class="header">
        <span class="badge">${icons.scan}</span>
        <div class="heading"><h2 class="title">${text.result}</h2><div class="meta"></div></div>
        <button class="icon-button" type="button" data-action="close" aria-label="${text.close}">${icons.close}</button>
      </header>
      <pre class="preview"></pre>
      <footer class="footer">
        <button class="action" type="button" data-action="again">${icons.again}<span>${text.again}</span></button>
        <button class="action primary" type="button" data-action="copy">${icons.copy}<span>${text.copy}</span></button>
      </footer>
    </section>
    <div class="toast" role="status" aria-live="polite"></div>
  `;
  (document.documentElement || document.body).appendChild(host);

  const launcher = root.querySelector('.launcher');
  const guide = root.querySelector('.guide');
  const panel = root.querySelector('.panel');
  const preview = root.querySelector('.preview');
  const meta = root.querySelector('.meta');
  const toast = root.querySelector('.toast');
  let isPicking = false;
  let hoveredElement = null;
  let extractedText = '';
  let toastTimer = 0;
  let suppressLauncherClick = false;
  let dragState = null;

  function normalizeText(value) {
    return String(value || '')
      .replace(/\r/g, '')
      .split('\n')
      .map(line => line.replace(/[\t ]+/g, ' ').trim())
      .filter(Boolean)
      .join('\n')
      .trim();
  }

  function visibleText(element) {
    if (!(element instanceof Element)) return '';
    return normalizeText(element.innerText || element.textContent || '');
  }

  function candidateFrom(node) {
    let element = node instanceof Element ? node : node?.parentElement;
    if (!element || element === host || host.contains(element)) return null;
    if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(element.tagName)) return null;
    for (let depth = 0; element && depth < 6; depth += 1, element = element.parentElement) {
      if (element === host || element === document.documentElement) return null;
      const style = getComputedStyle(element);
      if (style.display !== 'none' && style.visibility !== 'hidden' && visibleText(element)) return element;
    }
    return null;
  }

  function clearHoveredElement() {
    if (hoveredElement) hoveredElement.classList.remove(targetClass);
    hoveredElement = null;
  }

  function setHoveredElement(element) {
    if (element === hoveredElement) return;
    clearHoveredElement();
    hoveredElement = element;
    hoveredElement?.classList.add(targetClass);
  }

  function showToast(message) {
    clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.add('visible');
    toastTimer = setTimeout(() => toast.classList.remove('visible'), 1600);
  }

  function setPicking(enabled) {
    isPicking = enabled;
    launcher.classList.toggle('active', enabled);
    launcher.setAttribute('aria-label', enabled ? text.cancel : text.title);
    launcher.title = enabled ? text.cancel : text.title;
    guide.classList.toggle('visible', enabled);
    if (enabled) panel.classList.remove('visible');
    else clearHoveredElement();
  }

  function beginPicking() {
    setPicking(true);
  }

  function areaLabel(element) {
    const named = element.getAttribute('aria-label') || element.getAttribute('title');
    const role = element.getAttribute('role');
    return named || role || element.tagName.toLowerCase();
  }

  function presentResult(element, value) {
    extractedText = value;
    preview.textContent = value;
    meta.textContent = `${text.tag}: ${areaLabel(element)} · ${value.length} ${text.chars}`;
    panel.classList.add('visible');
    element.classList.add(pickedClass);
    setTimeout(() => element.classList.remove(pickedClass), 600);
    root.querySelector('[data-action="copy"]').focus({ preventScroll: true });
  }

  function pickElement(element, event) {
    if (!element) {
      showToast(text.empty);
      return;
    }
    const value = visibleText(element);
    if (!value) {
      showToast(text.empty);
      return;
    }
    event?.preventDefault();
    event?.stopPropagation();
    event?.stopImmediatePropagation();
    clearHoveredElement();
    setPicking(false);
    presentResult(element, value);
  }

  function clampButton(left, top) {
    const width = launcher.offsetWidth || 50;
    const height = launcher.offsetHeight || 50;
    return {
      left: Math.min(Math.max(dragPadding, left), Math.max(dragPadding, innerWidth - width - dragPadding)),
      top: Math.min(Math.max(dragPadding, top), Math.max(dragPadding, innerHeight - height - dragPadding))
    };
  }

  function placeButton(left, top) {
    const point = clampButton(left, top);
    launcher.style.left = `${point.left}px`;
    launcher.style.top = `${point.top}px`;
    launcher.style.right = 'auto';
    launcher.style.bottom = 'auto';
    return point;
  }

  function restoreButtonPosition() {
    const saved = GM_getValue(positionKey, null);
    if (!saved || !Number.isFinite(saved.x) || !Number.isFinite(saved.y)) return;
    const width = launcher.offsetWidth || 50;
    const height = launcher.offsetHeight || 50;
    placeButton(saved.x * Math.max(1, innerWidth - width), saved.y * Math.max(1, innerHeight - height));
  }

  function saveButtonPosition(point) {
    const width = launcher.offsetWidth || 50;
    const height = launcher.offsetHeight || 50;
    GM_setValue(positionKey, {
      x: point.left / Math.max(1, innerWidth - width),
      y: point.top / Math.max(1, innerHeight - height)
    });
  }

  launcher.addEventListener('pointerdown', event => {
    if (event.button !== undefined && event.button !== 0) return;
    const rect = launcher.getBoundingClientRect();
    dragState = {
      pointerID: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      left: rect.left,
      top: rect.top,
      moved: false
    };
    try { launcher.setPointerCapture(event.pointerId); } catch (_) {}
  });

  launcher.addEventListener('pointermove', event => {
    if (!dragState || event.pointerId !== dragState.pointerID) return;
    const deltaX = event.clientX - dragState.startX;
    const deltaY = event.clientY - dragState.startY;
    if (!dragState.moved && Math.hypot(deltaX, deltaY) < 6) return;
    dragState.moved = true;
    launcher.classList.add('dragging');
    event.preventDefault();
    placeButton(dragState.left + deltaX, dragState.top + deltaY);
  });

  function finishDragging(event) {
    if (!dragState || event.pointerId !== dragState.pointerID) return;
    const didMove = dragState.moved;
    dragState = null;
    launcher.classList.remove('dragging');
    try { launcher.releasePointerCapture(event.pointerId); } catch (_) {}
    if (!didMove) return;
    suppressLauncherClick = true;
    const rect = launcher.getBoundingClientRect();
    saveButtonPosition({ left: rect.left, top: rect.top });
    setTimeout(() => { suppressLauncherClick = false; }, 0);
  }

  launcher.addEventListener('pointerup', finishDragging);
  launcher.addEventListener('pointercancel', finishDragging);
  launcher.addEventListener('click', event => {
    if (suppressLauncherClick) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    setPicking(!isPicking);
  });

  document.addEventListener('pointermove', event => {
    if (!isPicking) return;
    setHoveredElement(candidateFrom(event.target));
  }, true);

  document.addEventListener('click', event => {
    if (!isPicking || event.composedPath().includes(host)) return;
    const element = candidateFrom(event.target);
    if (element) {
      pickElement(element, event);
    } else {
      event.preventDefault();
      event.stopPropagation();
      showToast(text.empty);
    }
  }, true);

  root.querySelector('[data-action="close"]').addEventListener('click', () => panel.classList.remove('visible'));
  root.querySelector('[data-action="again"]').addEventListener('click', beginPicking);
  root.querySelector('[data-action="copy"]').addEventListener('click', () => {
    if (!extractedText) return;
    GM_setClipboard(extractedText);
    showToast(text.copied);
  });

  window.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    if (isPicking) setPicking(false);
    else panel.classList.remove('visible');
  }, true);

  window.addEventListener('resize', () => {
    const rect = launcher.getBoundingClientRect();
    if (launcher.style.left) placeButton(rect.left, rect.top);
  });

  if (typeof GM_registerMenuCommand === 'function') {
    GM_registerMenuCommand(text.title, beginPicking);
  }

  restoreButtonPosition();
})();
