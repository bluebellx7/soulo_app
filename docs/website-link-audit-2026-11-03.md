# 网站导航链接检查（2026-11-03）

## 方法与限制

- 对影视、磁力、网盘、阅读、音乐目录中的 169 个条目逐一请求；搜索源另以 `test` 替换 `%@`，检查 85 个模板。使用桌面 Chrome 的 User-Agent，跟随 HTTP 重定向，超时 12 秒。
- 200 只表示请求返回，不代表页面内容、搜索或下载功能一定正常；403、202、429、513、超时及 TLS 错误也可能由访问地区、反爬验证或测试网络造成，不能直接判定永久失效。搜索源的检查会受到登录、浏览器验证和限流影响。
- 检查结果是本次测试的快照，网站状态会变化。未删除现有条目。

## 截图中的候选网站

截图中与现有目录重复的入口不重复加入。磁力导航和地址发布页不加入磁力搜索；停放、跳转到无关页面及无法验证的搜索接口未加入。`cili.xyz` 首页有搜索框，但实际搜索 API 两次超时，未能验证，未加入。

天天磁力的内嵌搜索服务 `so.ttbt.top` 本次返回搜索结果页，已收录用户指定的 `d2.ttbt.me`。磁力猫、磁力狗使用“电影”和“流浪地球”返回结果，部分结果含成人内容。

| 截图名称 | 测试地址 | 请求结果 | 最终地址 / 页面标题 |
|---|---|---|---|
| 种子吧 | https://zzb01.xyz | 请求异常：SSLError | — |
| 磁力猫 | https://clm34.top | 请求异常：SSLError | — |
| 磁力宝 | https://clb08.xyz | 请求异常：SSLError | — |
| 磁搜 | https://xn---icisoucom-e12p686ciwltn3epeo.cilibaidu.xyz | 200 | https://cferror.com/ 第一福利导航 - 官方网址发布 |
| 磁力熊猫 | https://xiongmaoto.top | 200 | https://xiongmaoto.top/ 磁力熊猫 - 最懂你的磁力链接搜索引擎 |
| 无限磁力 | https://wx567.top | 200 | https://gotowww.aipages.dev/7d/?wx567.top welcome |
| 磁力炮 | https://cilipao.com | 403 | https://cilipao.com/ Attention Required! \| Cloudflare |
| 磁力么 | https://cilime.net | 403 | https://www.cilime.lat/ Attention Required! \| Cloudflare |
| 无极磁力 | https://wuji.me | 200 | https://wuji.me/ ØMagnet 无极磁链 - 种子分享平台 |
| 磁力虎 | https://cilihu.vip | 200 | https://www.cilihu.vip/ 磁力虎 - cilihu.vip \| 磁力链接任务搜索引擎 |
| 磁力大大 | https://cilidada.org | 200 | https://www.cilidada.org/ CiliDaDa.com-磁力大大资源数据库 |
| 磁力导航 | https://cilimiao.cn | 200 | https://cilimiao.cn/ BT磁力搜索_磁力狗_CILIMAO磁力猫_磁力搜索引擎2025导航大全 |
| 磁力草 | https://cilicao.cc | 请求异常：SSLError | — |
| 吴签磁力 | https://wuqiangb.top | 200 | https://tech.imwuchong.net/feo/FB4pFz80QU?_=001&p=1 网址安全中心 \| 加载中 |
| 搜磁力 | https://tt.cilimiaomiao.xyz | 200 | https://202608.urldance.com/6d/?cilimiaomiao.xyz#others welcome |
| 天堂磁力 | https://tt3.ttcl.cc | 200 | https://tt3.ttcl.cc/ 天堂磁力 |
| 磁力先锋 | https://tellme.vip/clxf | 200 | https://gotowww.aipages.dev/7d/?tellme.vip welcome |
| 磁力星球 | https://so5.xingqiu.icu | 200（验证或跳转页） | https://so5.xingqiu.icu/ Redirecting... |
| SkrBT | https://skrbtgb.top | 200 | https://tech.imwuchong.net/feo/q3DJ9VrF0G?_=001&p=1 网址安全中心 \| 加载中 |
| 吃力网 | https://mylgwb.sokk35.buzz | 请求异常：SSLError | — |
| BT联盟 | https://mm.btlm.in | 200 | https://btlm.info BT联盟 |
| 黑马磁力 | https://heimacili.top | 200 | https://heimacili.top/ |
| 磁力先锋 | https://clxf.me | 200（验证或跳转页） | https://clxf.me/ Redirecting... |
| 磁力口袋 | https://clkd.org | 200 | https://clkd.org/ 磁力口袋 - 最新地址发布页 |
| 磁力导航 | https://cili.xyz | 200 | https://cili.xyz/ cili.xyz - Magnet Pioneer |
| 搜磁力 | https://cili.xfuse.fun | 请求异常：SSLError | — |
| 磁力波 | https://cili.boo | 请求异常：SSLError | — |
| 磁力吧 | https://cili.bar | 请求异常：SSLError | — |
| 磁力酷 | https://ciliku.net | 200 | https://gotowww.aipages.dev/8d/?ciliku.net welcome |
| 磁力多 | https://ciliduo.cyou | 200 | https://ciliduo.cyou/ 搜狗 |
| 磁力帝 | https://cilidi.top | 200 | https://cilidi.top/ 磁力帝最新网址，收藏我回家不迷路！御选入口 · 最新地址 |
| Yiove 磁力搜索 | https://bt.pyth.onl | 403 | https://bt.iaaaaa.com/ 网站不存在 |
| 磁力蜘蛛 | https://btmovi.cyou | 200 | https://btmovi.cyou/ 磁力蜘蛛 |
| BT联盟 | https://btlm.info | 200 | https://btlm.info/ BT联盟 |
| BTFOX | https://btfox.xyz | 请求异常：SSLError | — |
| 磁力狐 | https://bt15.foxs.vip | 200 | https://bt15.foxs.vip/ уБЂтіЏуІљ |
| 磁力多 | https://be.dobt.top | 200 | https://be.dobt.top/ BT搜索 |
| 91BT | https://91bt.cyou | 200 | https://91bt.cyou/ 91BT发布页 · 轨道中继 · 最新地址 |
| 无极磁链 | https://18mag.net | 403 | https://18mag.net/ Attention Required! \| Cloudflare |
| 人人磁力 | https://renrencili.info | 200 | https://gotowww.aipages.dev/7d/?renrencili.info welcome |

## 现有目录明细

各条状态为单次检查结果；URL 跳转目标和页面标题用于辅助核对。

| 目录 | 网站 | 地址 | 结果 | 最终地址 / 标题 |
|---|---|---|---|---|
| 影视 | 片吧影视 | https://www.pbkan.com/ | 200 | https://www.pbkan.com/ 2026最新电影电视剧排行榜 - 片吧影视 |
| 影视 | 可可影视 | https://www.kkys02.com/ | 850 | https://www.kkys02.com/ Protected by cdndefend, verifying your browser... |
| 影视 | Netflix | https://www.netflix.com/hk/ | 200 | https://www.netflix.com/jp/ Netflix (ネットフリックス) 日本 - 大好きな映画やドラマを楽しもう! |
| 影视 | Disney+ | https://www.disneyplus.com/zh-hk | 200 | https://www.disneyplus.com/zh-hk 迪士尼、Marvel、彼思、星球大戰、國家地理和 Hulu \| Disney+ 香港 |
| 影视 | 6V 电影 | https://www.6vdyy.com/ | 200 | https://www.6vdyy.com/ 6v电影网，最新电影，最新电视剧，免费电影下载，电视剧下载，迅雷下载 |
| 影视 | 磁力熊 | https://www.cilixiong.org/ | 200 | https://www.cilixiong.org/ 磁力熊 - 豆瓣高分电影1080P磁力下载 |
| 影视 | 追新番 | https://www.fanxinzhui.com/ | 200 | https://www.fanxinzhui.com/ čŋ―æ°įŠ |
| 影视 | 韩娱网 | https://koreayule.com/ | 200 | https://koreayule.com/ 最新热门韩剧、韩国电影、综艺、动漫大全、最新韩国娱乐资讯｜韩娱网 |
| 影视 | 日娱观察所 | https://ribenyule.com/ | 200 | https://ribenyule.com/ 日娱观察所_日本娱乐新闻、日剧电影动漫综艺资讯 |
| 影视 | 哔哩哔哩 | https://www.bilibili.com/ | 200 | https://www.bilibili.com/zh-Hans bilibili |
| 影视 | 稀饭动漫 | https://dick.xfani.com/ | 200 | https://xifan.moe/ 稀饭ACG - 连接动漫、漫画、游戏与二次元世界 |
| 影视 | Anime1 | https://anime1.in/ | 200 | https://anime1.in/ Anime1.in 動畫線上看 – 上千部動漫免費線上看！ |
| 影视 | 次元城动画 | https://www.cycani.org/ | 403 | https://www.cycani.org/ 不提供服务 |
| 影视 | trace.moe | https://trace.moe/ | 200 | https://trace.moe/ Anime Scene Search Engine - trace.moe |
| 影视 | 80s 电影 | https://y80s.tv/movie/search/ | 200（空页面或脚本验证） | https://y80s.tv/movie/search/ |
| 影视 | 茶杯狐 | https://cupfox.app/ | 200 | https://cupfox.app/ 茶杯狐 - 片荒剧荒就来茶杯狐 |
| 影视 | 搜片 | https://soupian.one/ | 200 | https://soupian.one/ 搜片.com - 搜你想看的影片 |
| 影视 | i8K 影视导航 | https://i8k.tv/ | 200 | https://i8k.tv/ i8K影视导航 - 最全免费在线影视网站导航 \| i8k.tv |
| 影视 | 阿里小站 | https://pan666.net/ | 403 | https://pan666.net/ Just a moment... |
| 影视 | UP 云搜 | https://www.upyunso.com/ | 200 | https://www.upyunso.com/ UPдә‘жҗң - зҪ‘зӣҳиө„жәҗжҗңзҙўзҘһеҷЁ |
| 影视 | 深影译站 | https://sysub.com/ | 200 | https://sysub.com/ 深影译站 – 与您共享全球影视经典 |
| 影视 | 找台词 | https://zhaotaici.cn/ | 200 | https://zhaotaici.cn/ 找台词 |
| 影视 | 33 台词 | https://33.agilestudio.cn/ | 请求异常：ReadTimeout | — |
| 影视 | QuoDB | https://www.quodb.com/ | 200 | https://www.quodb.com/ QuoDB \| The movie quotes database |
| 影视 | 影猫 MVCAT | https://www.mvcat.com/movie/ | 200 | https://www.mvcat.com/movie/ 电影分类 |
| 影视 | 巅峰剧单 | https://best.i8k.tv/ | 200 | https://best.i8k.tv/ 巅峰剧单 · 最佳电视剧集典藏 |
| 影视 | 烂番茄 | https://www.rottentomatoes.com/ | 200 | https://www.rottentomatoes.com/ Rotten Tomatoes: Movies \| TV Shows \| Movie Trailers \| Reviews \| Rotten Tomatoes |
| 影视 | Box Office Mojo | https://www.boxofficemojo.com/ | 200 | https://www.boxofficemojo.com/ Home - Box Office Mojo |
| 影视 | 类似电影 | https://leisidianying.com/ | 200 | https://leisidianying.com/ 选择类似电影和电视节目的最佳推荐服务 |
| 影视 | 盗火线 | https://dao-fire.com/ | 请求异常：SSLError | — |
| 影视 | CCTV 在线 | https://tv.cctv.com/live/cctv1/ | 200 | https://tv.cctv.com/live/cctv1/ CCTV-1综合频道高清直播_CCTV节目官网_央视网 |
| 影视 | 直播吧 | https://www.zhibo8.com/ | 200 | https://www.zhibo8.com/ 直播吧 |
| 影视 | ZY Player | https://zyplayer.fun/ | 200 | https://zyplayer.fun/ ZY Player 资源播放器 |
| 影视 | 茅台资源站 | https://mtzy.me/ | 200 | https://mtzy.me/ 茅台资源站 |
| 影视 | 4K 在线 | https://www.bbibb.top/ | 200 | https://www.bbibb.top/ 4K在线 |
| 影视 | 麦田影院 | https://www.mtyy5.com/ | 200 | https://www.mtyy5.com/ 麦田影院-好看的电影电视剧,海量高清影视免费在线观看 |
| 影视 | 大米星球 | https://www.dm154.top/ | 200 | https://www.dm154.top/ 大米星球_最新Netflix新剧_韩国电影免费在线观看 |
| 影视 | 秒看电影 | https://miaokan.cc/ | 200 | https://miaokan.cc/ 秒看电影_最新高清影视在线观看_免费电影资源网 |
| 影视 | 光速影视 | https://4kzaixian.top/ | 200 | https://4kzaixian.top/ 光速影视 |
| 影视 | 茶杯狐影视 | https://www.cupfox.lol/ | 403 | https://www.cupfox.lol/ Just a moment... |
| 影视 | 柯南影视 | https://www.knvod.com/ | 520 | https://www.knvod.com/ 250535.xyz \| 520: Web server is returning an unknown error |
| 影视 | FreeOK | https://www.freeokk.pro/ | 403 | https://www.freeokk.pro/ Just a moment... |
| 影视 | 看片狂人 | https://www.kpkuang.fun/ | 200 | https://www.kpkuang.fun/ 看片狂人 |
| 影视 | 在线之家 | https://www.zxzjhd.com/ | 200 | https://www.zxzj.run/ 在线之家 - 在线观看最新美剧\|最新韩剧\|天天美剧\|人人美剧 |
| 影视 | 樱花影院 | https://www.dcjyb.com/ | 200（空页面或脚本验证） | https://www.dcjyb.com/ |
| 影视 | 看剧 AI | https://kanju1.com/ | 200 | https://kanju1.com/ 看剧AI - KANJU.AI |
| 影视 | 腾讯视频 | https://v.qq.com/ | 200 | https://v.qq.com/ 腾讯视频-中国领先的在线视频媒体平台，海量高清视频在线观看 |
| 影视 | 爱奇艺 | https://www.iqiyi.com/ | 200 | https://www.iqiyi.com/ 爱奇艺 iQIYI-热门独播剧集在线观看 |
| 影视 | Apple TV | https://www.apple.com/apple-tv-plus | 200 | https://www.apple.com/apple-tv/ Apple TV - Apple |
| 影视 | 豆瓣电影 | https://movie.douban.com/ | 200 | https://movie.douban.com/ 豆瓣电影 |
| 影视 | 芒果 TV | https://www.mgtv.com/ | 200 | https://www.mgtv.com/ 芒果TV-天生青春 |
| 影视 | 小马盘 | https://www.xiaomapan.com/#/main/search?restype=1 | 200 | https://www.xiaomapan.com/#/main/search?restype=1 小马盘 - 网盘搜索引擎 |
| 影视 | 人人影视分享 | https://yyets.click/ | 200 | https://yyets.click/ 人人影视分享下载站 |
| 影视 | 嘎嘎影视 | https://www.gagays.com/ | 200 | https://www.gagays.com/ 嘎嘎影视 |
| 影视 | ACG.RIP | https://acg.rip/ | 200 | https://acg.rip/ ACG.RIP |
| 影视 | 云盘资源社区 | https://yunpan1.cc/ | 200 | https://yunpan1.cc/ yunpan1 -  云盘资源分享社区-yunpan1 |
| 影视 | 飘花电影 | https://www.piaohua.com/ | 200 | https://www.piaohua.com/ 飘花电影网_飘花迅雷电影下载网_最新电影_迅雷免费电影下载 |
| 影视 | CHAOSPACE | https://www.chaospace.xyz/ | 200 | https://www.chaospace.xyz/ CHAOSPACE – 蓝光影视 热门美剧 字幕分享 最好用的影视资源站 |
| 影视 | 蜜柑计划 | https://mikanani.me/ | 200 | https://mikanani.me/ 蜜柑计划 - Mikan Project |
| 影视 | 团长资源 | https://t-rex.tzfile.com/ | 200 | https://t-rex.tzfile.com/ 团长资源 - 影视聚集地 |
| 影视 | CINEFOX | https://www.cinefox.com/ | 200 | https://www.cinefox.com/ 씨네폭스 |
| 影视 | 人人影视字幕组 | https://www.yysub.net/ | 200 | https://www.yysub.net/ YYeTs 人人影视\|字幕组官方站 |
| 影视 | 树屋经典影视 | https://treehousesub.com/forum.php | 请求异常：ReadTimeout | — |
| 影视 | 天府泰剧 | https://weibo.com/tfthaimovie | 200 | https://passport.weibo.com/visitor/visitor?entry=miniblog&a=enter&url=https%3A%2F%2Fweibo.com%2Ftfthaimovie&domain=weibo.com&ua=Mozilla%2F5.0%20%28Macintosh%3B%20Intel%20Mac%20OS%20X%2010_15_7%29%20AppleWebKit%2F537.36%20%28KHTML%2C%20like%20Gecko%29%20Chrome%2F130.0.0.0%20Safari%2F537.36&_rand=1793691040092&sudaref= Sina Visitor System |
| 影视 | 纪录片之家论坛 | https://www.jlpzj.net/forum.php | 200 | https://www.jlpzj.net/forum.php 纪录片之家 -  Powered by Discuz! |
| 影视 | 影猫の仓库 | https://ymck.pro/ | 200 | https://www.ymck.pro/ 影猫の仓库 - 免费观影第一站 ! |
| 影视 | 金牌影院 | https://www.x8kb9k8.com/ | 200 | https://www.x8kb9k8.com/ 金牌影院_免费在线播放_高清全集_电影网站_在线视频 |
| 影视 | NO 视频 | https://www.novipnoad.net/ | 403 | https://www.novipnoad.net/ Just a moment... |
| 影视 | 威视 TV | https://weishitv.xyz/ | 200 | https://weishitv.xyz/ 威视TV-海量高清在线影视库 |
| 影视 | 人人电影网 | https://www.rrdynb.com/ | 200 | https://www.rrdynb.com/index.html зљСзЂЩзїіжК§дЄ≠ |
| 影视 | Ultra4K | https://dianying4k.com/ | 200 | https://dianying4k.com/ 4K 电影资料与资源目录 \| Ultra4K |
| 影视 | 电影街 | https://dyjie.net/ | 200 | https://dyjie.net/user/login/?next=%2F 用户登录 |
| 影视 | 比特大雄 | https://www.btdx8.net/ | 200 | https://www.btdx8.net/ 比特大雄_BT电影天堂_最新720P、1080P高清电影BT种子免注册下载网站 |
| 影视 | 番组放送 | https://bgmlist.com/ | 200 | https://bgmlist.com/ 每日放送 \| 番组放送 |
| 影视 | Animex 动漫社 | https://www.animetox.com/ | 200 | https://www.animetox.com/ Animex动漫社 - 二次元及日本文化最速报 |
| 影视 | 时光电影榜 | https://list.mtime.com/listIndex | 200 | https://list.mtime.com/listIndex Mtime时光网 —— 榜单/片单 |
| 影视 | Anime Garden | https://animes.garden/ | 200 | https://animes.garden/ Anime Garden 動漫花園第三方镜像站以及动画 BT 资源聚合站 |
| 影视 | 预告片世界 | https://www.6huo.com/ | 请求异常：ReadTimeout | — |
| 影视 | IMP Awards | https://www.impawards.com/ | 200 | http://www.impawards.com/ IMP Awards - All the Latest Movie Posters |
| 影视 | 射手网（伪） | https://assrt.net/ | 200 | https://assrt.net/ 首页 - 射手网(伪) - assrt.net - 字幕下载，字幕组，中文字幕，美剧字幕，英剧字幕，双语字幕，新番字幕 |
| 影视 | 央视纪实 | https://jishi.cctv.com/ | 200 | https://jishi.cctv.com/ 纪实-中国纪录片第一频道,最新、高清正版海量纪录片_央视网 |
| 影视 | 西瓜卡通 | https://cn1.xgcartoon.com/ | 502 | https://cn1.xgcartoon.com/ 502 Bad Gateway |
| 影视 | 纪录片之家 | https://www.05jl.com/ | 200 | https://www.05jl.com/ BBC纪录片大全_最新美剧下载 \| 纪录片之家 |
| 影视 | 厂长资源 | https://www.4kcz.com/ | 403 | https://www.4kcz.com/ |
| 影视 | 影视搜 | https://yingshi.xyz/ | 请求异常：ProxyError | — |
| 磁力 | 无极磁链 | https://wuji.me/ | 200 | https://wuji.me/ ØMagnet 无极磁链 - 种子分享平台 |
| 磁力 | 无极磁链镜像 | https://xcili.net/ | 200 | https://xcili.net/ ØMagnet 无极磁链 - 种子分享平台 |
| 磁力 | 磁力熊猫 | https://xiongmaoto.top/ | 200 | https://xiongmaoto.top/ 磁力熊猫 - 最懂你的磁力链接搜索引擎 |
| 磁力 | 磁力炮 | https://www.cilipao.pics/ | 403 | https://www.cilipao.pics/ Attention Required! \| Cloudflare |
| 磁力 | 磁力么 | https://www.cilime.lat/ | 403 | https://www.cilime.lat/ Attention Required! \| Cloudflare |
| 磁力 | 磁力搜索 | https://cilisousuo.co/ | 200 | https://cilisousuo.co/ 磁力搜索 |
| 磁力 | 磁力蜘蛛 | https://btmovi.cyou/ | 200 | https://btmovi.cyou/ 磁力蜘蛛 |
| 磁力 | 磁力王 | https://www.ciliwang360.shop/ | 200 | https://www.ciliwang360.shop/ 磁力王-最佳的磁力搜索引擎 |
| 磁力 | 种子吧 | https://zzb05.top/ | 请求异常：SSLError | — |
| 磁力 | 磁力虎 | https://www.cilihu.vip/ | 200 | https://www.cilihu.vip/ 磁力虎 - cilihu.vip \| 磁力链接任务搜索引擎 |
| 磁力 | 磁力大大 | https://www.cilidada.org/v/ | 200 | https://www.cilidada.org/v/ 【磁力大大资源数据库】-CiliDaDa.com |
| 磁力 | 天天磁力 | https://d2.ttbt.me/ | 200 | https://d2.ttbt.me/ 天天磁力 |
| 磁力 | BT之家 1LOU | https://www.1lou.pro/ | 200 | https://www.1lou.pro/ BT之家1LOU站-回归初心，追求极简 |
| 磁力 | SeedHub | https://www.seedhub.cc/ | 403 | https://www.seedhub.cc/ Just a moment... |
| 磁力 | 6V 电影 | https://www.6vdyy.com/ | 200 | https://www.6vdyy.com/ 6v电影网，最新电影，最新电视剧，免费电影下载，电视剧下载，迅雷下载 |
| 磁力 | 6V 电影备用 | https://www.6v520.com/ | 200 | https://www.6v520.com/ 6v电影_免费电影_高清电影__最新电视剧下载（旧版66影视） |
| 磁力 | 磁力熊 | https://www.cilixiong.org/ | 200 | https://www.cilixiong.org/ 磁力熊 - 豆瓣高分电影1080P磁力下载 |
| 磁力 | 迅雷电影天堂 | https://xunlei8.org/ | 200 | https://xunlei8.org/ 最新电影高清迅雷下载_720P_1080P - 迅雷电影天堂 |
| 磁力 | 比特大雄 | https://www.btdx8.net/ | 200 | https://www.btdx8.net/ 比特大雄_BT电影天堂_最新720P、1080P高清电影BT种子免注册下载网站 |
| 磁力 | 飘花电影 | https://www.piaohua.com/ | 200 | https://www.piaohua.com/ 飘花电影网_飘花迅雷电影下载网_最新电影_迅雷免费电影下载 |
| 磁力 | CHAOSPACE | https://www.chaospace.xyz/ | 200 | https://www.chaospace.xyz/ CHAOSPACE – 蓝光影视 热门美剧 字幕分享 最好用的影视资源站 |
| 磁力 | 人人影视分享 | https://yyets.click/ | 200 | https://yyets.click/ 人人影视分享下载站 |
| 磁力 | Ultra4K | https://dianying4k.com/ | 200 | https://dianying4k.com/ 4K 电影资料与资源目录 \| Ultra4K |
| 磁力 | 蜜柑计划 Mikan | https://mikanani.me/ | 200 | https://mikanani.me/ 蜜柑计划 - Mikan Project |
| 磁力 | Anime Garden | https://animes.garden/ | 200 | https://animes.garden/ Anime Garden 動漫花園第三方镜像站以及动画 BT 资源聚合站 |
| 磁力 | ACG.RIP | https://acg.rip/ | 200 | https://acg.rip/ ACG.RIP |
| 磁力 | Nyaa | https://nyaa.si/ | 200 | https://nyaa.si/ Browse :: Nyaa |
| 磁力 | Nyaa 中文站 | https://cn.nyaa.net/ | 200 | https://cn.nyaa.net/ Nyaa |
| 磁力 | 樱花动漫 BT | https://yhdm33.com/ | 200 | https://yhdm33.com/ 樱花动漫 - 专注二次元ACG动漫BT迅雷下载 |
| 磁力 | EZTV | https://eztvx.to/ | 200 | https://eztvx.to/ EZTV - TV Torrents Online Series Download \| Official |
| 磁力 | RuTracker | https://rutracker.net/forum/index.php | 200 | https://rutracker.net/forum/index.php RuTracker.org |
| 磁力 | 磁力猫 | https://cdn.cilimao.fun:39520/?host=cilimao.de | 200 | https://cdn.cilimao.fun:39520/?host=cilimao.de 磁力猫 |
| 磁力 | 磁力狗 | https://cdn.ciligou.in:39520/?host=ciligou.de | 200 | https://cdn.ciligou.in:39520/?host=ciligou.de 磁力狗 - 懂你的搜索 |
| 磁力 | Tokyo Toshokan | https://www.tokyotosho.info/ | 200 | https://www.tokyotosho.info/ Tokyo Toshokan :: #tokyotosho @ irc.rizon.net :: Torrent Listing |
| 网盘 | 千帆搜索 | https://pan.qianfan.app/ | 200 | https://pan.qianfan.app/ еҚғеёҶжҗңзҙў - иө„жәҗи¶…дё°еҜҢзҡ„иҒҡеҗҲзҪ‘зӣҳжҗңзҙўеј•ж“ҺпјҒ |
| 网盘 | 盘搜Pro | https://panso.vip/ | 200 | https://panso.vip/ 网盘搜索-找网盘资源就上盘搜VIP-聚合网盘搜索引擎 |
| 网盘 | 阿立盘搜 | https://aliso.vip/ | 200 | https://aliso.vip/ 阿立盘搜-聚合网盘资源搜索助手-夸克/百度/迅雷/阿里/UC/115/123/天翼云盘/移动云盘等网盘资源 |
| 网盘 | 搜盘鸭 | https://sopanya.com/ | 200 | https://sopanya.com/ 搜盘鸭 - 夸克、百度、阿里、UC、迅雷网盘资源搜索 |
| 网盘 | 爱搜 | https://www.esoua.com/ | 200 | https://www.esoua.com/ 爱搜-网盘资源搜索-一站式网盘资源搜索下载，阿里夸克百度迅雷UC全聚合 |
| 网盘 | 易搜 | https://yiso.fun/ | 403 | https://yiso.fun/ Just a moment... |
| 网盘 | 影盘社 | https://www.melost.cn/ | 200 | https://www.melost.cn/ 影盘社-百度/夸克/迅雷网盘资源搜索引擎 |
| 网盘 | UP云搜 | https://www.upyunso.com/ | 200 | https://www.upyunso.com/ UPдә‘жҗң - зҪ‘зӣҳиө„жәҗжҗңзҙўзҘһеҷЁ |
| 网盘 | 盘了个盘 | https://www.panlegepan.com/ | 200 | https://www.panlegepan.com/ зӣҳдәҶдёӘзӣҳ - иҒҡеҗҲзҪ‘зӣҳиө„жәҗжҗңзҙў \| йҳҝйҮҢдә‘зӣҳжҗңзҙў |
| 网盘 | 小马盘 | https://www.xiaomapan.com/#/main/search?restype=1 | 200 | https://www.xiaomapan.com/#/main/search?restype=1 小马盘 - 网盘搜索引擎 |
| 网盘 | 小兔搜搜 | https://xiaotusoso.com/ | 200 | https://xiaotusoso.com/ |
| 网盘 | Ai资源帮 | https://ai-zyb.com/ | 200 | https://ai-zyb.com/ Ai资源帮 - 首发Ai资源搜索Agent |
| 网盘 | 云盘资源社区 | https://yunpan1.cc/ | 200 | https://yunpan1.cc/ yunpan1 -  云盘资源分享社区-yunpan1 |
| 网盘 | 团长资源 | https://t-rex.tzfile.com/ | 200 | https://t-rex.tzfile.com/ 团长资源 - 影视聚集地 |
| 网盘 | 影视搜 | https://yingshi.xyz/ | 请求异常：ProxyError | — |
| 网盘 | 人人电影网 | https://www.rrdynb.com/ | 200 | https://www.rrdynb.com/index.html зљСзЂЩзїіжК§дЄ≠ |
| 网盘 | SeedHub | https://www.seedhub.cc/ | 403 | https://www.seedhub.cc/ Just a moment... |
| 网盘 | 纪录片数据库 | https://docu-lib.com/ | 200 | https://docu-lib.com/ 纪录片数据库 - 纪录片下载 Docu-Lib |
| 网盘 | 学霸盘 | https://www.xuebapan.com/ | 200 | https://www.xuebapan.com/ 学霸盘 - 百度网盘学习资料搜索下载神器 |
| 网盘 | 会搜盘 | https://www.huisoupan.com/ | 200 | https://www.huisoupan.com/ 网盘资源搜索 - 百度网盘与夸克网盘学习资料、PPT模板、设计素材、电子书下载入口 |
| 网盘 | 4K精品夸克资源 | https://link3.cc/4kzy | 200 | https://link3.cc/4kzy 4K精品收藏级资源分享 \| Link3 |
| 网盘 | 资源收藏夹·网盘 | https://zyscj.com/zy/search/diskresource.html | 200 | https://zyscj.com/zy/search/diskresource.html 🔗网盘资源合集 \| 资源收藏夹 |
| 网盘 | 夸克网盘 | https://pan.quark.cn/ | 200 | https://pan.quark.cn/ 夸克网盘 - 网页版丨客户端下载丨安全存储丨极速传输丨阿里云守护 |
| 网盘 | 阿里云盘 | https://www.alipan.com/ | 200 | https://www.alipan.com/ 阿里云盘 - 备份无忧 整理有序·阿里巴巴集团出品 |
| 网盘 | 百度网盘 | https://pan.baidu.com/ | 200 | https://pan.baidu.com/ 百度网盘-免费云盘丨文件共享软件丨超大容量丨存储安全 |
| 网盘 | 迅雷云盘 | https://pan.xunlei.com/ | 200 | https://pan.xunlei.com/ 迅雷 |
| 网盘 | 115生活 | https://115.com/ | 200 | https://115.com/ 115科技官网_首页_115生活(曾用名“115网盘”) |
| 网盘 | 蓝奏云盘 | https://www.lanzou.com/ | 200 | https://www.lanzou.com/ 蓝奏·云存储 |
| 阅读 | Z-Library | https://zh.z-library.sk/ | 513 | https://zh.z-library.sk/ Verifying your browser \| DiamWall |
| 阅读 | iBooks · 读书小站 | https://ibooks.org.cn/ | 200 | https://ibooks.org.cn/ 读书小站 \| 悦读不孤读 |
| 阅读 | SoBooks | https://sobooks.cc/ | 200 | https://sobooks.cc/ SoBooks – EPUB/MOBI/AZW3/PDF电子书免费下载 |
| 阅读 | 苦瓜书盘 | https://kgbook.com/ | 200 | https://kgbook.com/ 苦瓜书盘 |
| 阅读 | 安娜的档案 | https://annas-archive.gl/ | 请求异常：SSLError | — |
| 阅读 | 鸠摩搜索 | https://www.jiumodiary.com/ | 200 | https://www.jiumodiary.com/ Jiumo Search 鸠摩搜索 - 文档搜索引擎 |
| 阅读 | 书格 | https://www.shuge.org/ | 200 | https://www.shuge.org/ 书格 |
| 阅读 | 古腾堡计划 | https://www.gutenberg.org/ | 200 | https://www.gutenberg.org/ Free eBooks \| Project Gutenberg |
| 阅读 | Standard Ebooks | https://standardebooks.org/ | 200 | https://standardebooks.org/ Standard Ebooks: Free and liberated ebooks, carefully produced for the true book lover |
| 阅读 | 书伴 | https://bookfere.com/ | 200 | https://bookfere.com/ 书伴 – 你的电子书伴侣 |
| 阅读 | Calibre | https://calibre-ebook.com/ | 200 | https://calibre-ebook.com/ calibre - E-book management |
| 音乐 | 歌曲宝 | https://www.gequbao.com/ | 403 | https://www.gequbao.com/ Just a moment... |
| 音乐 | 无损音乐下载 | https://flac.music.hi.cn/ | 200 | https://flac.music.hi.cn/ 无损音乐下载 |
| 音乐 | 歌曲海 | https://www.gequhai.com/ | 403 | https://www.gequhai.com/ |
| 音乐 | 全网音乐免费下载 | https://music.txqq.pro/ | 200 | https://music.txqq.pro/ 全网音乐免费下载 - 多站合一音乐搜索,音乐在线试听,下载,在线解析网 |
| 音乐 | 放屁网 | https://www.fangpiw.com/ | 403 | https://www.fangpiw.com/ Just a moment... |
| 音乐 | HiFiBa | https://hifiba.com/ | 200 | https://hifiba.com/ 无损音乐磁场_音乐下载_母带24bit_192kHz_FLAC_WAV_MP3_内嵌封面歌词歌曲分享 - HiFiBa |
| 音乐 | Bandcamp | https://bandcamp.com/ | 200 | https://bandcamp.com/ Bandcamp |
| 音乐 | Jamendo | https://www.jamendo.com/start | 200 | https://www.jamendo.com/start Jamendo Music \| Free music downloads |
| 音乐 | Free Music Archive | https://freemusicarchive.org/home | 200 | https://freemusicarchive.org/home Welcome to the Free Music Archive - Free Music Archive |
| 音乐 | Freesound | https://freesound.org/ | 200 | https://freesound.org/ Freesound |
| 音乐 | OpenTracks | https://opentracks.com/ | 200 | https://opentracks.com/ フリーBGM19338曲・効果音1283点 無料ダウンロード｜フリーBGM OpenTracks（旧DOVA-SYNDROME） |

## 搜索源模板明细

测试地址中 `test` 是检查使用的示例关键词。

| 搜索源 | 测试地址 | 结果 | 最终地址 / 标题 |
|---|---|---|---|
| ChatGPT Search | https://chatgpt.com/?hints=search&q=test | 403 | https://chatgpt.com/?hints=search&q=test |
| Perplexity | https://www.perplexity.ai/search?q=test | 403 | https://www.perplexity.ai/search/new?q=test Just a moment... |
| Andi | https://andisearch.com/?q=test | 200 | https://andisearch.com/?q=test Andi - AI Search for the Next Generation |
| Felo Search | https://felo.ai/search?q=test | 200 | https://felo.ai/search/kAyzUPrvk-SlQYz32Se4O?q=test test |
| Consensus | https://consensus.app/results/?q=test | 403 | https://consensus.app/results/?q=test Just a moment... |
| You.com | https://you.com/search?q=test | 200 | https://you.com/signin?redirectUrl=%2Fsearch%3Fq%3Dtest You.com \| Search and inference for AI |
| iAsk.AI | https://iask.ai/?q=test | 200 | https://iask.ai/q/test-gtb6ke0 iAsk Student · test |
| Semantic Scholar | https://www.semanticscholar.org/search?q=test | 202 | https://www.semanticscholar.org/search?q=test |
| 百度 | https://www.baidu.com/s?wd=test | 200 | https://www.baidu.com/s?wd=test test_百度搜索 |
| 搜狗 | https://www.sogou.com/web?query=test | 200 | https://www.sogou.com/web?query=test |
| Google | https://www.google.com/search?q=test | 200 | https://www.google.com/search?q=test Google Search |
| Bing | https://www.bing.com/search?q=test | 200 | https://www.bing.com/search?q=test test - 検索 |
| DuckDuckGo | https://duckduckgo.com/?q=test | 200 | https://duckduckgo.com/?q=test test at DuckDuckGo |
| 360 搜索 | https://www.so.com/s?q=test | 200 | https://www.so.com/s?q=test test_360搜索 |
| Yandex | https://yandex.com/search/?text=test | 200 | https://yandex.com/showcaptcha?cc=1&form-fb-hint=2.1&mt=9217E9D35792092DCD6C1F18FE298A436C19F276FC77B605C08A7DE7B3983795C6D3802E5F1F61B822053F3D18E1CB46FC0D97F76790FED314C666496A1DEEB78C70497585653ED2DFCD15525F2CD387439EA0BD32CC21F7FD0461A7D4249018DF9DC71A9B78F85968CA5394CE2FE744DACC3AA867DEC7B7EB380FBB788941FB0251DCAF845CEDDF&retpath=aHR0cHM6Ly95YW5kZXguY29tL3NlYXJjaD90ZXh0PXRlc3Q%2C_d29c578c47994d9a5b87e237671e5b75&t=2%252F1793691060%252F7099ddd7c2dc5287f57118227e31fd13&u=9692105027205225963&s=53f8ba1b69960c2770381a59ade4c524 Are you not a robot? |
| Startpage | https://www.startpage.com/sp/search?query=test | 200 | https://www.startpage.com/sp/search?query=test |
| Yahoo! | https://search.yahoo.com/search?p=test | 500 | https://search.yahoo.com/search?p=test |
| Mojeek | https://www.mojeek.com/search?q=test | 200 | https://www.mojeek.com/search?q=test Captcha |
| Brave Search | https://search.brave.com/search?q=test | 429 | https://search.brave.com/search?q=test Request refused - Brave Search |
| Ecosia | https://www.ecosia.org/search?q=test | 403 | https://www.ecosia.org/search?q=test Ecosia Firewall |
| Qwant | https://www.qwant.com/?q=test&t=web | 200 | https://www.qwant.com/?q=test&t=web Service unavailable |
| Naver | https://search.naver.com/search.naver?query=test | 200 | https://search.naver.com/search.naver?query=test test : 네이버 검색 |
| Daum | https://search.daum.net/search?w=tot&q=test | 200 | https://search.daum.net/search?w=tot&q=test test – Daum 검색 |
| Google 日本 | https://www.google.co.jp/search?q=test | 200 | https://www.google.co.jp/search?q=test Google Search |
| Yahoo! 日本 | https://search.yahoo.co.jp/search?p=test | 200 | https://search.yahoo.co.jp/search?p=test 「test」の検索結果 - Yahoo!検索 |
| 中文维基百科 | https://zh.wikipedia.org/w/index.php?search=test | 200 | https://zh.wikipedia.org/w/index.php?search=test test - 搜索结果 - 维基百科，自由的百科全书 |
| Wikipedia | https://en.wikipedia.org/w/index.php?search=test | 200 | https://en.wikipedia.org/wiki/Test Test - Wikipedia |
| 百度学术 | https://xueshu.baidu.com/s?wd=test | 200（验证或跳转页） | https://wappass.baidu.com/static/captcha/tuxing_v2.html?&logid=11446965882634257238&ak=c27bbc89afca0463650ac9bde68ebe06&backurl=https%3A%2F%2Fxueshu.baidu.com%2Fs%3Fwd%3Dtest&ext=x9G9QDmMXq%2FNo87gjGO0P6Cs2%2BQsCdf6nrrgGiy6NCYsr0rrDszYO2sAbAnT1vLIUgqUK9LXd1cIlztrhMwiv5LjTJOXogJlpsHvDVSC%2FysKiHF4%2Bejckz4WXEDORy3g&signature=52c655b979cd3f742d77ab5aa9ec02ca&timestamp=1793691060 百度安全验证 |
| Google Scholar | https://scholar.google.com/scholar?q=test | 403 | https://scholar.google.com/scholar?q=test Sorry... |
| PubMed | https://pubmed.ncbi.nlm.nih.gov/?term=test | 200 | https://pubmed.ncbi.nlm.nih.gov/?term=test test - Search Results - PubMed |
| PubMed Central | https://pmc.ncbi.nlm.nih.gov/search/?term=test | 200 | https://pmc.ncbi.nlm.nih.gov/search/?term=test test - Search Results - PMC |
| DOAJ | https://doaj.org/search/articles/test | 403 | https://doaj.org/search/articles/test Just a moment... |
| arXiv | https://arxiv.org/search/?query=test&searchtype=all | 200 | https://arxiv.org/search/?query=test&searchtype=all Search \| arXiv e-print repository |
| BASE | https://www.base-search.net/Search/Results?lookfor=test&type=all | 200 | https://www.base-search.net/Search/Results?lookfor=test&type=all Making sure you're not a bot! |
| OALib | https://www.oalib.com/search?kw=test | 200 | https://www.oalib.com/search?kw=test |
| PLOS ONE | https://journals.plos.org/plosone/search?q=test | 200 | https://journals.plos.org/plosone/search?q=test Search Results \| PLOS One |
| Nature | https://www.nature.com/search?q=test | 200 | https://www.nature.com/search?q=test test \| Nature Search Results |
| ResearchGate | https://www.researchgate.net/search/publication?q=test | 403 | https://www.researchgate.net/search/publication?q=test ResearchGate - Temporarily Unavailable |
| JSTOR | https://www.jstor.org/action/doBasicSearch?Query=test | 200 | https://www.jstor.org/action/doBasicSearch?Query=test Client Challenge |
| SpringerLink | https://link.springer.com/search?query=test | 200 | https://link.springer.com/search?query=test Search research articles and books \| Springer Nature Link |
| Wiley Online Library | https://onlinelibrary.wiley.com/action/doSearch?AllField=test | 403 | https://onlinelibrary.wiley.com/action/doSearch?AllField=test Just a moment... |
| MIT DSpace | https://dspace.mit.edu/search?query=test | 202 | https://dspace.mit.edu/search?query=test |
| ScienceDirect | https://www.sciencedirect.com/search?qs=test | 403 | https://www.sciencedirect.com/search?qs=test ScienceDirect |
| AMiner | https://www.aminer.cn/search/pub?q=test | 200 | https://www.aminer.cn/search/pub?q=test AMiner - AI赋能科技情报挖掘-学术搜索-论文检索-论文专利-文献追踪-学者画像 |
| Thèses.fr | https://theses.fr/?q=test | 200 | https://theses.fr/?q=test Theses.fr |
| 小红书 | https://www.xiaohongshu.com/search_result?keyword=test&source=web_explore_feed&type=51 | 200 | http://www.xiaohongshu.com/search_result/?keyword=test&source=web_explore_feed&type=51 test - 小红书搜索 |
| 抖音 | https://www.douyin.com/search/test | 200 | https://www.douyin.com/search/test |
| X | https://x.com/search?q=test | 200 | https://x.com/i/jf/onboarding/web?redirect_after_login=%2Fsearch%3Fq%3Dtest&mode=login X - The Everything App / X |
| YouTube | https://www.youtube.com/results?search_query=test | 200 | https://www.youtube.com/results?search_query=test |
| Product Hunt | https://www.producthunt.com/search?q=test | 403 | https://www.producthunt.com/search?q=test Just a moment... |
| Facebook | https://www.facebook.com/search/top?q=test | 400 | https://www.facebook.com/search/top?q=test Error |
| Instagram | https://www.instagram.com/explore/tags/test/ | 200 | https://www.instagram.com/explore/tags/test/ Instagram |
| Bilibili | https://search.bilibili.com/all?keyword=test | 200 | https://search.bilibili.com/zh-Hans/all?keyword=test test-哔哩哔哩_bilibili |
| 知乎 | https://www.zhihu.com/search?type=content&q=test | 403 | https://www.zhihu.com/search?type=content&q=test |
| 微博 | https://s.weibo.com/weibo?q=test | 200 | https://passport.weibo.com/visitor/visitor?entry=miniblog&a=enter&url=https%3A%2F%2Fs.weibo.com%2Fweibo%3Fq%3Dtest&domain=.weibo.com&sudaref=&ua=php-sso_sdk_client-0.6.29&_rand=1793691063.9315 Sina Visitor System |
| 今日头条 | https://so.toutiao.com/search?keyword=test | 200 | https://so.toutiao.com/search?keyword=test test-头条搜索 |
| Threads | https://www.threads.com/search?q=test | 200 | https://www.threads.com/search?q=test Threads |
| Reddit | https://www.reddit.com/search/?q=test&type=link | 403 | https://www.reddit.com/search/?q=test&type=link |
| Pinterest | https://www.pinterest.com/search/pins/?q=test | 200 | https://www.pinterest.com/search/pins/?q=test Pinterest |
| LinkedIn | https://www.linkedin.com/search/results/all/?keywords=test | 403 | https://www.linkedin.com/uas/login?session_redirect=%2Fsearch%2Fresults%2Fall%2F%3Fkeywords%3Dtest&skipRedirect=true Attention Required! \| Cloudflare |
| 微信文章 | https://weixin.sogou.com/weixinwap?type=2&ie=utf8&s_from=input&query=test | 200 | https://weixin.sogou.com/weixinwap?type=2&ie=utf8&s_from=input&query=test test的相关微信公众号文章 – 搜狗微信搜索 |
| GitHub | https://github.com/search?q=test&type=repositories | 200 | https://github.com/search?q=test&type=repositories Repository search results · GitHub |
| Stack Overflow | https://stackoverflow.com/search?q=test | 200 | https://stackoverflow.com/nocaptcha?s=e27ea1d0-0ea4-4f2c-b1ac-5a1f3ba5abb3 Human verification - Stack Overflow |
| CSDN | https://so.csdn.net/so/search?q=test | 200 | https://so.csdn.net/so/search?q=test |
| 掘金 | https://juejin.cn/search?query=test | 200 | https://juejin.cn/search?query=test 搜索 - 掘金 |
| 淘宝 | https://s.m.taobao.com/h5?q=test | 200 | https://s.m.taobao.com/h5?q=test ŠĚśň«ŁŠÉťš┤ó |
| 京东 | https://so.m.jd.com/ware/search.action?keyword=test | 200（验证或跳转页） | https://cfe.m.jd.com/privatedomain/risk_handler/03101900/?returnurl=https%3A%2F%2Fso.m.jd.com%2Fware%2Fsearch.action%3Fkeyword%3Dtest&appid=2179&evtype=3&evurl=https://cfe.m.jd.com/privatedomain/risk_handler/03101900/&rpid=rp-186524731-10428-1793691067574 京东验证 |
| Amazon | https://www.amazon.com/s?k=test&i=mobile | 503 | https://www.amazon.com/s?k=test&i=mobile Sorry! Something went wrong! |
| eBay | https://www.ebay.com/sch/i.html?_nkw=test | 403 | https://www.ebay.com/sch/i.html?_nkw=test Error Page \| eBay |
| AcFun | https://www.acfun.cn/search?keyword=test | 200 | https://www.acfun.cn/search?keyword=test 搜索 - AcFun弹幕视频网 - 认真你就输啦 (?ω?)ノ- ( ゜- ゜)つロ |
| pixiv | https://www.pixiv.net/tags/test/artworks | 200 | https://www.pixiv.net/tags/test #testの人気イラストやマンガ（1000件超） - pixiv |
| 哔哩哔哩漫画 | https://manga.bilibili.com/search?from=manga_homepage&keyword=test | 200 | https://manga.bilibili.com/search?from=manga_homepage&keyword=test 搜索结果 - 哔哩哔哩漫画 |
| 优酷 | https://search.youku.com/search_video?keyword=test | 200 | https://search.youku.com/search_video?keyword=test 优酷搜索 |
| 爱奇艺 | https://m.iqiyi.com/search.html?source=input&key=test | 200 | https://www.iq.com/search?query=test&_from=iqiyi iQIYI - Watch Asian dramas shows movies animes Free online - Streaming Korean drama, Chinese drama, |
| 腾讯视频 | https://v.qq.com/x/search/?q=test | 200 | https://v.qq.com/x/search/?q=test 腾讯视频 |
| 芒果 TV | https://so.mgtv.com/so?k=test | 200 | https://so.mgtv.com/so?k=test 芒果TV |
| 片吧搜索 | https://www.pianbs.com/sou/-------------.html?wd=test&submit= | 200（验证或跳转页） | https://www.pianbs.com/sou/-------------.html?wd=test&submit= 系统安全验证 |
| 最大资源 | https://www.zuidazy.co/vodsearch/-------------.html?wd=test&submit=search | 200（验证或跳转页） | https://www.zuidazy.co/vodsearch/-------------.html?wd=test&submit=search 系统安全验证 |
| 优酷资源 | https://ukuzy0.com/index.php/vod/search.html?wd=test&submit=search | 200 | https://ukuzy0.com/index.php/vod/search.html?wd=test&submit=search 搜索结果test-u酷资源站 |
| 光速资源 | https://guangsuzy.com/index.php/vod/search.html?wd=test | 200（验证或跳转页） | https://guangsuzy.com/index.php/vod/search.html?wd=test 系统安全验证 |
| 金鹰资源 | https://jinyingzy.com/index.php/vod/search.html?wd=test&submit=search | 403 | https://jinyingzy.com/index.php/vod/search.html?wd=test&submit=search Just a moment... |
| 木头资源 | https://mtzy.me/vod/mysearch.html?wd=test&submit=search | 200（验证或跳转页） | https://mtzy.me/vod/mysearch.html?wd=test&submit=search 系统安全验证 |
| 极速资源 | https://jszy333.com/index.php/vod/search.html?wd=test | 200（验证或跳转页） | https://jszy333.com/index.php/vod/search.html?wd=test 系统安全验证 |
| Z-Library | https://zh.z-library.sk/s/test? | 513 | https://zh.z-library.sk/s/test Verifying your browser \| DiamWall |
| iBooks | https://ibooks.org.cn/?s=test | 200 | https://ibooks.org.cn/?s=test test \| 搜索结果  \| 读书小站 |
