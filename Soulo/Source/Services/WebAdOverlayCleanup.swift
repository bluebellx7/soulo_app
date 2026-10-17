import Foundation

/// Shared by cosmetic filtering and cookie handling: only remove a modal's
/// backdrop after a known filtered child has left it without visible content.
enum WebAdOverlayCleanup {
    static let filteredModalCleanup = #"""
    function cleanupFilteredModalOverlays(releaseLocks = false) {
      const isMgtv=/(^|\.)mgtv\.com$/.test(location.hostname);
      const visible = element => {
        if (!element?.isConnected) return false;
        const rect=element.getBoundingClientRect(),style=getComputedStyle(element);
        return rect.width>1&&rect.height>1&&style.display!=='none'&&style.visibility!=='hidden'&&Number(style.opacity)!==0;
      };
      const authentication = element => {
        const identity=[element.id,element.className,element.getAttribute('aria-label')].join(' ').toLowerCase();
        return /(^|[\s_-])(login|log-in|signin|sign-in|signup|sign-up|register|auth|passport)([\s_-]|$)/.test(identity)
          || !!element.querySelector('input[type="tel"],input[type="password"],input[autocomplete*="one-time-code"],input[name*="captcha" i],input[name*="verify" i]');
      };
      function hasContent(content) {
        if (!visible(content)) return false;
        if (authentication(content)) return true;
        const walker=document.createTreeWalker(content,NodeFilter.SHOW_TEXT);let node,visited=0;
        while((node=walker.nextNode())&&visited++<500){
          if(String(node.nodeValue||'').trim().length>1&&visible(node.parentElement))return true;
        }
        return [...content.querySelectorAll('input,select,textarea,button,img,video,iframe,canvas')].some(visible);
      }
      const filteredSelector='[data-soulo-hidden-ad],[data-soulo-hidden-consent]';
      let cleared=false;
      function clearEmptyModal(container,content,backdrop) {
        if(!content||!backdrop||container===document.body||container===document.documentElement||authentication(content))return;
        if(container.hasAttribute('data-soulo-cleared-overlay'))return;
        if(!(content.matches(filteredSelector)||content.querySelector(filteredSelector))||hasContent(content))return;
        // The sibling mask and the modal container can both intercept input.
        for(const element of new Set([container,backdrop])) {
          for(const [property,value] of [['display','none'],['visibility','hidden'],['pointer-events','none']]){
            element.style.setProperty(property,value,'important');
          }
          element.setAttribute('data-soulo-cleared-overlay','');
        }
        cleared=true;
      }
      document.querySelectorAll('.ReactModal__Overlay').forEach(overlay=>{
        clearEmptyModal(overlay,overlay.querySelector('.ReactModal__Content'),overlay);
      });
      if(isMgtv)document.querySelectorAll('[class*="styles_mgui-dialog__"]').forEach(container=>{
        clearEmptyModal(container,container.querySelector('[class*="styles_dialog__"]'),container.querySelector('[class*="styles_mask__"]'));
      });
      if(!cleared&&!releaseLocks)return;
      const dialogs='.ReactModal__Overlay,[role="dialog"],[aria-modal="true"],dialog[open]'
        +(isMgtv?', [class*="styles_mgui-dialog__"]':'');
      if([...document.querySelectorAll(dialogs)].some(visible))return;
      for(const root of [document.documentElement,document.body]){
        if(!root)continue;
        root.classList.remove('ReactModal__Body--open','ReactModal__Html--open');
        for(const property of ['overflow','overflow-y','touch-action']){
          if(/^(hidden|clip|none)$/.test(root.style.getPropertyValue(property)))root.style.removeProperty(property);
        }
        if(root===document.body&&root.style.position==='fixed'){
          const offset=-parseFloat(root.style.top||'0');
          for(const property of ['position','top','left','right','width'])root.style.removeProperty(property);
          if(Number.isFinite(offset)&&offset>0)window.scrollTo(0,offset);
        }
      }
      document.querySelectorAll('#__next[aria-hidden="true"],#app[aria-hidden="true"],#root[aria-hidden="true"]')
        .forEach(root=>root.removeAttribute('aria-hidden'));
    }
    """#

    static let source = filteredModalCleanup + #"""

    function cleanupAdOverlays() {
      // Use the site's browser option to release its own React state. Never
      // invoke the app-opening or service-agreement acceptance actions.
      if(/(^|\.)mgtv\.com$/.test(location.hostname)){
        document.querySelectorAll('[class*="OpenAppDialog_container__"]').forEach(dialog=>{
          if(dialog.hasAttribute('data-soulo-app-dismissed'))return;
          const close=[...dialog.querySelectorAll('p,button,[role="button"]')]
            .find(node=>String(node.textContent||'').trim()==='继续使用浏览器');
          if(!close)return;
          dialog.setAttribute('data-soulo-app-dismissed','');close.click();
          if(dialog.isConnected)hideAdElement(dialog);
        });
      }
      cleanupFilteredModalOverlays();
    }
    """#
}
