(() => {
  'use strict';
  const form = document.getElementById('recommend-form');
  const submit = document.getElementById('recommend-submit');
  const status = document.getElementById('recommend-status');
  if (!form || !submit || !status) return;
  let sending = false;
  const words = {
    invalid: ['请填写扩展名称和联系方式；如填写链接，请使用有效的 HTTPS 地址。', 'Enter an extension name and contact information. If you include a link, use a valid HTTPS address.'],
    sending: ['正在提交…', 'Sending…'],
    success: ['推荐已提交，谢谢！我们会先验证，再手动收录。', 'Recommendation sent. Thank you! We will test it before adding it.'],
    error: ['提交失败，内容已保留，请稍后重试。', 'Could not send. Your entries are kept; please try again.'],
    timeout: ['请求超时，内容已保留，请重试。', 'The request timed out. Your entries are kept; please try again.']
  };
  function say(key, error = false) {
    status.textContent = words[key][document.documentElement.lang.startsWith('zh') ? 0 : 1];
    status.dataset.error = String(error);
  }
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (sending || !form.reportValidity()) return;
    const data = new FormData(form);
    const name = String(data.get('name') || '').trim();
    const address = String(data.get('url') || '').trim();
    const reason = String(data.get('reason') || '').trim();
    const contact = String(data.get('contact') || '').trim();
    let url;
    if (address) { try { url = new URL(address); } catch {} }
    const content = ['[扩展推荐]', `名称：${name}`, address ? `链接：${address}` : '', reason ? `推荐理由：${reason}` : ''].filter(Boolean).join('\n');
    if (!name || !contact || (address && (!url || url.protocol !== 'https:' || !url.hostname || url.username || url.password)) || content.length > 2000) {
      say('invalid', true); status.focus(); return;
    }
    sending = true; submit.disabled = true; submit.setAttribute('aria-busy', 'true'); say('sending');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch('https://api.dkluge.com/api/feedback', {
        method: 'POST', headers: {'Content-Type': 'application/json'}, credentials: 'omit', referrerPolicy: 'no-referrer', signal: controller.signal,
        body: JSON.stringify({type: 'feature', content, contact_info: contact,
          device_info: JSON.stringify({app: 'Soulo extension catalog', language: document.documentElement.lang}),
          page_url: location.origin + location.pathname})
      });
      if (!response.ok) throw new Error('feedback failed');
      form.reset(); say('success'); status.focus();
    } catch (error) { say(error?.name === 'AbortError' ? 'timeout' : 'error', true); status.focus(); }
    finally { clearTimeout(timer); sending = false; submit.disabled = false; submit.removeAttribute('aria-busy'); }
  });
})();
