# 应用内手绘插画

2026-11-05：使用 imagegen 技能和内置 image_gen 工具生成。风格参考项目原有 `IllustrationTransfer`，保留细炭笔线条、淡紫色和奶油色、轻微纸张纹理，透明背景，不包含文字。

图片分别用于下载、收藏、历史的空列表，沿用 `ToolIllustration` 的尺寸和深色模式处理，不在首页预加载。文件列表和 Wi-Fi 传输的现有插画保留。

资源：

- `Soulo/Assets.xcassets/IllustrationDownloads.imageset/illustration.png`
- `Soulo/Assets.xcassets/IllustrationBookmarks.imageset/illustration.png`
- `Soulo/Assets.xcassets/IllustrationHistory.imageset/illustration.png`

生成提示词：

## downloads

Use case: illustration. Create one new standalone in-app empty-state illustration for the Soulo browser. The attached illustration is a STYLE REFERENCE ONLY: match its graceful fine charcoal ink outlines, slightly textured cream and muted lavender fills, quiet warm editorial sketch mood, friendly adult character proportions, sparse small botanical details, and simple balanced composition. Genuine transparent background, isolated artwork, no background panel, no glow, no shadow halo, no lettering, no words, no logos, no border. Complete unclipped composition with generous transparent margin, landscape 3:2, readable at 280x180 points. Do not copy the transfer scene. Scene: a young adult woman in a cream sweater and lavender trousers sitting beside a small open lavender storage box, carefully putting a few simple paper documents into it; one subtle downward arrow above the papers conveys saving downloads. A small plant grounds the composition. Calm, minimal, not busy.

## bookmarks

Use case: illustration. Create one new standalone in-app empty-state illustration for the Soulo browser. The attached illustration is a STYLE REFERENCE ONLY: match its graceful fine charcoal ink outlines, slightly textured cream and muted lavender fills, quiet warm editorial sketch mood, friendly adult character proportions, sparse small botanical details, and simple balanced composition. Genuine transparent background, isolated artwork, no background panel, no glow, no shadow halo, no lettering, no words, no logos, no border. Complete unclipped composition with generous transparent margin, landscape 3:2, readable at 280x180 points. Do not copy the transfer scene. Scene: a young adult woman in a cream top and lavender skirt standing beside a low bookcase, selecting and keeping a favorite book with a visible lavender bookmark ribbon. A couple of simple webpage-shaped cards rest beside the bookcase to suggest saved websites. One small plant. Calm minimal composition.

## history

Use case: illustration. Create one new standalone in-app empty-state illustration for the Soulo browser. The attached illustration is a STYLE REFERENCE ONLY: match its graceful fine charcoal ink outlines, slightly textured cream and muted lavender fills, quiet warm editorial sketch mood, friendly adult character proportions, sparse small botanical details, and simple balanced composition. Genuine transparent background, isolated artwork, no background panel, no glow, no shadow halo, no lettering, no words, no logos, no border. Complete unclipped composition with generous transparent margin, landscape 3:2, readable at 280x180 points. Do not copy the transfer scene. Scene: a young adult woman in cream and lavender sitting at a small round table, looking through a few simple unlettered browser-page cards; a small analog clock with a curved backward arrow beside the cards suggests browsing history. One small plant. Quiet minimal composition.

## 版本与主动评价页面（2026-11-05）

使用内置 image_gen，以 `IllustrationTransfer` 为画风参考、`SouloLogo` 为标识参考生成两张新图。保留透明背景，深色界面保留原色以呈现金色 Logo。原始 Logo 资源不修改。

- 版本页：`Soulo/Assets.xcassets/IllustrationAbout.imageset/illustration.png`
- 主动评价页：`Soulo/Assets.xcassets/IllustrationReview.imageset/illustration.png`

评价入口由用户在设置中主动打开，页面以 `https://apps.apple.com/app/id6761165330?action=write-review` 链接 App Store，不在应用内选择星级。链接方式参考 [Apple 的主动评价说明](https://developer.apple.com/documentation/storekit/requesting-app-store-reviews)。

验证：模拟器中以简体中文浅色、英文深色分别检查两个页面的实际截图；评价页入口、App Store 链接的可点击区域、返回设置及进入版本页的 UI 回归通过。构建成功，50 个语言的严格本地化检查通过。详细截图和运行结果在本机 `/tmp/soulo-about-review-20261105/Illustrations.xcresult` 与 `screenshots/` 中。

### about

Use case: illustration-story. Asset type: decorative illustration inside the Soulo iOS browser. Input image 1 is STYLE REFERENCE ONLY. Match its fine hand-drawn charcoal outlines, lightly textured cream and muted lavender palette, friendly adult woman with dark hair in a loose bun, calm warm editorial illustration mood, delicate imperfect ink texture. Input image 2 is the EXACT SOULO LOGO reference: a warm pale golden brushstroke enso ring on a white rounded square. Preserve the ring identity and colors accurately, no letters inside the logo. Landscape 3:2 centered complete unclipped composition with generous transparent space around the subject, readable at 280x185 points. Genuine transparent background. No background panel, no words, no text, no typography, no watermark, no glow or vignette. Primary request: create a new charming version/about-page illustration of this woman proudly holding the Soulo app logo. She sits comfortably cross-legged in lavender trousers and a cream sweater, smiling softly toward the viewer. Both arms gently hold a large white rounded-square Soulo logo tile in front of her chest and lap. The logo is clearly visible and dominant, hands do not cover the golden ring. A tiny tasteful lavender botanical sprig can balance the composition. No laptop, no additional app icons, no border around the whole scene.

### review

Use case: illustration-story. Asset type: decorative illustration inside the Soulo iOS browser. Input image 1 is STYLE REFERENCE ONLY. Match its fine hand-drawn charcoal outlines, lightly textured cream and muted lavender palette, friendly adult woman with dark hair in a loose bun, calm warm editorial illustration mood, delicate imperfect ink texture. Input image 2 is the EXACT SOULO LOGO reference: a warm pale golden brushstroke enso ring on a white rounded square. Preserve the ring identity and colors accurately, no letters inside the logo. Landscape 3:2 centered complete unclipped composition with generous transparent space around the subject, readable at 280x185 points. Genuine transparent background. No background panel, no words, no text, no typography, no watermark, no glow or vignette. Primary request: create a new warm, grateful app-support illustration for a voluntary Rate Us page. The woman in the same cream sweater and lavender trousers is kneeling or seated beside a small white rounded-square Soulo logo tile, holding one lovely warm golden star close to her heart with a quiet friendly smile. The exact Soulo logo tile sits prominently next to her. One small lavender botanical sprig is sufficient. No row of rating stars, no rating selector, no five-star badge, no award or reward imagery, no speech bubble, no text.


## 主屏幕快捷操作说明（2026-11-06）

使用 imagegen 技能和内置 `image_gen` 工具，参考现有版本页插画及用户提供的 iOS 主屏幕长按菜单截图生成。插画用于“长按快捷操作”设置页顶部，说明这是主屏幕上的 App 图标菜单；选中项目、排序、删除和恢复默认的操作保留。采用透明背景，深色模式保留 Logo 原色，装饰图片不参与点击及辅助功能朗读，不在首页预加载。

资源：`Soulo/Assets.xcassets/IllustrationQuickActions.imageset/illustration.png`。

生成原图：`/Users/shunfei.z/.codex/generated_images/01a18c0b-4ab3-7e91-8ad0-4b994a55121c/exec-cca21743-8c30-40cb-8ba5-55ab386ac3a1.png`。

生成提示词：

Create a new sibling illustration by transforming the first reference's visual style into a clear instructional scene about iOS Home Screen app-icon quick actions. Match the first reference exactly in visual family: warm dark graphite pencil outlines, visible hand-drawn grain, restrained cream and pale lavender watercolor fills, small soft golden accents, gentle friendly proportions. The second reference is interaction reference only: long-pressing the Soulo app icon on the iPhone Home Screen reveals a four-action quick menu. Do not reproduce its forest wallpaper, other app brands, red markup, widgets, or readable text. Composition: a close, easy-to-understand illustrated iPhone Home Screen and a gently drawn hand with one index fingertip holding the white rounded-square Soulo icon with its distinctive pale golden open circular brushstroke logo. Make this icon clearly recognizable and prominent. One subtle lavender press pulse indicates press-and-hold. A separate rounded cream/lavender menu expands beneath the selected icon with exactly four orderly horizontal rows, each with a small simple graphite outline pictogram on the left (QR scan, cache/trash, privacy eye, search magnifier) and short neutral gray strokes as label placeholders. Keep the depiction schematic and handmade, not a glossy screen mockup. No letters, numerals, slogans, watermarks or labels anywhere. Landscape 3:2 composition, centered and compact, generous transparent negative space, large enough main elements to remain clear at 180-220px display height. Isolated artwork on genuinely transparent background; no colored canvas or checkerboard painted into the image, no large shadow/glow halo.

## 功能页说明（2026-11-07）

移除独立帮助中心，视频设置、设置备份和阅读列表使用与长按快捷操作相同的 `IllustratedFeatureIntro`。说明位于对应功能页面，不额外创建帮助弹窗。备份复用文件整理插画，阅读列表复用阅读插画；文字沿用现有 50 种语言的翻译。

视频设置的新插画使用 imagegen 技能和内置 `image_gen` 工具生成，参考 `IllustrationDownloads` 的画风与角色。保留透明通道，将原图等比例缩至 840 × 560，PNG 无损保存为 595,927 字节，足够页面 280 pt 宽度的三倍屏显示；不在首页预加载。

资源：`Soulo/Assets.xcassets/IllustrationPlayback.imageset/illustration.png`。

生成原图：`/Users/shunfei.z/.codex/generated_images/01a18c0b-4ab3-7e91-8ad0-4b994a55121c/exec-8ec2f024-176a-41e5-9d05-ddfb26408db8.png`。

生成提示词：

Use case: illustration-story
Asset type: small decorative illustration for the video settings page of Soulo, an iOS browser.
Input image: reference image only for matching the existing illustration style and character; it is not an edit target.
Primary request: Create one new illustration in the same hand-drawn colored-pencil style as the reference. A relaxed young woman with dark hair in a loose bun, an ivory knit sweater and muted lavender trousers sits comfortably on the floor watching a landscape tablet propped beside her. The tablet has a simple pale lavender screen containing a clear triangular play symbol and a short progress bar, with one small music note nearby to suggest both video and audio. One very small lavender-leaf plant balances the composition.
Style/medium: delicate dark pencil outlines, visible fine paper-grain shading within the drawing, restrained cream and lavender color fills. Match the existing friendly adult character and quiet mood. Avoid a glossy, 3D or vector-icon appearance.
Composition/framing: single coherent wide 3:2 composition, full character and tablet visible, compact silhouette with clean outer edges and enough empty margin for use at 160 pt tall. Transparent background, no halo, no background rectangle, no ground shadow extending outside the drawing.
Text: no words, labels, logo, watermark or UI text.
