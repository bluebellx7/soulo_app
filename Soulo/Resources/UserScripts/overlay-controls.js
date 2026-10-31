(() => {
  if (window.__souloOverlayControls) return;
  let pageScale = 1, contentZoom = 1;
  const size = 48, iconSize = 23;
  function metrics() {
    const viewport = window.visualViewport;
    const value = window === window.top ? (viewport?.scale || 1)*contentZoom : pageScale;
    const scale = Number.isFinite(value) && value > 0 ? Math.max(.05, Math.min(20,value)) : 1;
    return {scale, unit:1/scale, size:size/scale, gap:8/scale,
      left:viewport?.offsetLeft || 0, top:viewport?.offsetTop || 0,
      width:viewport?.width || innerWidth, height:viewport?.height || innerHeight};
  }
  function apply(element, viewport = metrics()) {
    for (const [property,value] of [['transform-origin','top left'],['transform','scale('+Number(viewport.unit.toFixed(6))+')']]) {
      if (element.style.getPropertyValue(property) !== value) element.style.setProperty(property,value,'important');
    }
  }
  window.__souloOverlayControls = {size,iconSize,metrics,apply,setContentZoom(value) {
    if (Number.isFinite(value) && value >= .05 && value <= 20) contentZoom = value;
  },setPageScale(value) {
    if (Number.isFinite(value) && value >= .05 && value <= 20) pageScale = value;
  }};
})();
