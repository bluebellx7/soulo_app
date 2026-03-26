# 搜罗 Soulo

聚合搜索 App - 一键搜遍全球平台

## 项目概述

搜罗是一款聚合搜索 iOS App，用户输入关键词后可在多个平台（抖音、B站、Google、YouTube 等）的搜索结果间快速切换，平台按国家/地区分组。所有搜索历史和配置本地存储，保护隐私。

## 技术栈

- SwiftUI + WKWebView
- SwiftData (搜索历史、收藏)
- UserDefaults JSON (平台配置)
- iOS Speech 框架 (语音输入)
- NSUbiquitousKeyValueStore (iCloud 同步)
- 最低支持 iOS 17.0

## 项目结构

```
Soulo/
├── Soulo.xcodeproj/
├── Info.plist
└── Soulo/
    ├── Source/
    │   ├── App/
    │   │   └── SouloApp.swift                  # App 入口，ModelContainer 配置，环境注入
    │   │
    │   ├── Models/
    │   │   ├── SearchPlatform.swift             # 搜索平台数据模型
    │   │   ├── PlatformRegion.swift             # 地区枚举 (中国/国际/日本/俄罗斯)
    │   │   ├── SearchHistoryItem.swift          # 搜索历史 SwiftData Model
    │   │   ├── BookmarkItem.swift               # 收藏书签 SwiftData Model
    │   │   └── AppSettings.swift                # 设置项 Key 文档
    │   │
    │   ├── ViewModels/
    │   │   ├── SearchViewModel.swift            # 搜索状态管理，核心协调器
    │   │   ├── WebViewModel.swift               # WKWebView 状态绑定
    │   │   ├── PlatformManagerViewModel.swift   # 平台排序/显隐/自定义管理
    │   │   ├── BookmarkViewModel.swift          # 收藏状态管理
    │   │   └── SettingsViewModel.swift          # 设置页状态管理
    │   │
    │   ├── Views/
    │   │   ├── Home/
    │   │   │   ├── HomeView.swift               # 首页根视图，搜索框居中 → 顶部动画
    │   │   │   ├── SearchBarView.swift          # 搜索栏组件 (文字 + 语音)
    │   │   │   ├── SearchSuggestionsView.swift  # 热搜/历史建议胶囊
    │   │   │   └── ClipboardPromptView.swift    # 剪贴板检测提示横幅
    │   │   │
    │   │   ├── Search/
    │   │   │   ├── SearchResultsView.swift      # 搜索结果页主布局
    │   │   │   ├── RegionTabBar.swift           # 地区分组 Tab (中国/国际/日本/俄罗斯)
    │   │   │   ├── PlatformTabBar.swift         # 平台 Tab (抖音/B站/...)
    │   │   │   └── SearchHistoryView.swift      # 搜索历史列表
    │   │   │
    │   │   ├── WebView/
    │   │   │   ├── WebViewContainer.swift       # WebView 装饰外框容器
    │   │   │   ├── WebViewRepresentable.swift   # WKWebView UIViewRepresentable
    │   │   │   ├── WebViewToolbar.swift         # 底部工具栏 (前进/后退/刷新/收藏/分享)
    │   │   │   └── WebViewProgressBar.swift     # 加载进度条
    │   │   │
    │   │   ├── Settings/
    │   │   │   ├── SettingsView.swift           # 设置主页
    │   │   │   ├── PlatformManagementView.swift # 平台管理 (排序/显隐/添加)
    │   │   │   ├── AddCustomPlatformView.swift  # 添加自定义平台表单
    │   │   │   ├── LanguageSettingsView.swift   # 语言切换
    │   │   │   └── PrivacySettingsView.swift    # 隐私设置 (无痕/清除数据)
    │   │   │
    │   │   ├── Bookmarks/
    │   │   │   └── BookmarksView.swift          # 收藏列表
    │   │   │
    │   │   └── Shared/
    │   │       ├── SharedComponents.swift       # 通用组件 (Logo, CapsuleTag 等)
    │   │       └── PlatformIconView.swift       # 平台图标渲染
    │   │
    │   ├── Services/
    │   │   ├── PlatformDataStore.swift          # 平台数据层，内置 22 个平台及 URL 模板
    │   │   ├── SearchHistoryService.swift       # 搜索历史 CRUD
    │   │   ├── BookmarkService.swift            # 收藏 CRUD
    │   │   ├── ClipboardService.swift           # 剪贴板检测
    │   │   ├── SpeechRecognitionService.swift   # 语音识别服务
    │   │   └── CloudSyncService.swift           # iCloud KVS 同步
    │   │
    │   ├── Utils/
    │   │   ├── LanguageManager.swift            # 多语言管理 (复用 IDPhotoApp 模式)
    │   │   ├── ThemeManager.swift               # 主题/外观管理
    │   │   └── Constants.swift                  # 全局常量
    │   │
    │   └── Extensions/
    │       ├── Color+Theme.swift                # 主题颜色扩展
    │       ├── String+URL.swift                 # URL 校验和编码
    │       └── View+Modifiers.swift             # 自定义 ViewModifier
    │
    ├── Assets.xcassets/                         # App 图标 + 平台图标
    │
    ├── en.lproj/                               # 英语
    ├── zh-Hans.lproj/                          # 简体中文
    ├── ja.lproj/                               # 日语
    ├── ko.lproj/                               # 韩语
    ├── fr.lproj/                               # 法语
    ├── de.lproj/                               # 德语
    ├── es.lproj/                               # 西班牙语
    └── vi.lproj/                               # 越南语
```

## 功能清单

### 搜索
- [x] 搜索框输入关键词
- [x] 搜索框动画 (居中 → 顶部)
- [x] 搜索历史记录
- [x] 语音输入 (iOS Speech 框架)
- [x] 剪贴板检测 (打开 app 提示"搜索 xxx?")
- [x] 搜索建议/热搜词
- [x] 支持直接输入网址

### 结果展示 & WebView
- [x] 国家/地区分组 Tab (中国/国际/日本/俄罗斯)
- [x] 平台 Tab (按地区筛选)
- [x] 内嵌 WebView 展示搜索结果
- [x] WebView 装饰外框
- [x] WebView 导航栏 (前进/后退/刷新)
- [x] 加载进度条
- [x] 长按图片可保存
- [x] 网页内可修改搜索词

### 平台管理
- [x] 用户排序平台
- [x] 用户显示/隐藏平台
- [x] 用户添加自定义平台 (名称 + URL 模板)
- [x] 按使用频率自动排序

### 收藏 & 分享
- [x] 收藏当前网页
- [x] 分享搜索结果
- [x] 收藏列表管理

### 隐私
- [x] 无痕搜索模式
- [x] 一键清除历史
- [x] 清除 WebView 缓存/Cookie

### 个性化
- [x] 深色/浅色/跟随系统
- [x] 多语言 (8 种)
- [x] iCloud 同步 (历史 + 平台配置)

## 内置平台 (22 个)

### 中国 (9 个)
| 平台 | 搜索 URL 模板 |
|------|---------------|
| 抖音 | `https://www.douyin.com/search/%@` |
| B站 | `https://search.bilibili.com/all?keyword=%@` |
| 小红书 | `https://www.xiaohongshu.com/search_result?keyword=%@` |
| 微博 | `https://s.weibo.com/weibo?q=%@` |
| 知乎 | `https://www.zhihu.com/search?type=content&q=%@` |
| 百度 | `https://www.baidu.com/s?wd=%@` |
| 淘宝 | `https://s.taobao.com/search?q=%@` |
| 京东 | `https://search.jd.com/Search?keyword=%@` |
| 微信搜一搜 | `https://weixin.sogou.com/weixin?query=%@` |

### 国际 (6 个)
| 平台 | 搜索 URL 模板 |
|------|---------------|
| Google | `https://www.google.com/search?q=%@` |
| YouTube | `https://www.youtube.com/results?search_query=%@` |
| Twitter/X | `https://x.com/search?q=%@` |
| Reddit | `https://www.reddit.com/search/?q=%@` |
| Amazon | `https://www.amazon.com/s?k=%@` |
| TikTok | `https://www.tiktok.com/search?q=%@` |

### 日本 (4 个)
| 平台 | 搜索 URL 模板 |
|------|---------------|
| Yahoo Japan | `https://search.yahoo.co.jp/search?p=%@` |
| Google JP | `https://www.google.co.jp/search?q=%@` |
| Twitter/X JP | `https://x.com/search?q=%@&lang=ja` |
| YouTube JP | `https://www.youtube.com/results?search_query=%@&gl=JP` |

### 俄罗斯 (2 个)
| 平台 | 搜索 URL 模板 |
|------|---------------|
| Yandex | `https://yandex.ru/search/?text=%@` |
| VK | `https://vk.com/search?c%5Bq%5D=%@` |

> URL 模板中 `%@` 为关键词占位符，运行时替换为 percent-encoded 的搜索词。

## 实现阶段

### Phase 1: 基础骨架
App 入口、模型定义、平台数据层、语言/主题管理、首页基础布局

### Phase 2: 核心搜索流程
搜索栏、WebView 封装、地区/平台 Tab、搜索结果页、进度条、导航栏

### Phase 3: 历史 & 收藏
SwiftData 持久化、搜索历史、收藏书签、首页建议

### Phase 4: 语音 & 智能输入
语音识别、剪贴板检测、URL 直接输入

### Phase 5: 平台管理
排序、显隐、自定义平台、使用频率排序

### Phase 6: 设置 & 隐私
完整设置页、语言切换、外观切换、无痕模式、数据清除

### Phase 7: iCloud 同步 & 精打磨
iCloud KVS 同步、动画细节、长按保存图片、8 种语言翻译、边界处理

## 存储策略

| 数据 | 存储方式 | 原因 |
|------|----------|------|
| 平台配置 | UserDefaults JSON | 数据量小，需快速读取，便于 iCloud KVS 同步 |
| 搜索历史 | SwiftData | 无限增长集合，需查询/排序/去重 |
| 收藏书签 | SwiftData | 同上 |
| 用户偏好 | @AppStorage | 简单键值对 |
| iCloud 同步 | NSUbiquitousKeyValueStore | 数据小于 1MB，比 CloudKit 简单 |

## Info.plist 权限

```xml
NSSpeechRecognitionUsageDescription - 语音搜索
NSMicrophoneUsageDescription - 录音用于语音识别
NSPhotoLibraryAddUsageDescription - 保存网页图片到相册
```
