# 磁力目录快速检查（2026-11-01）

核对已发布 `https://soulo.dkluge.com/magnets.json` 与仓库目录，37 个 ID、URL 一致。统一使用 `ubuntu` 搜索，不登录、不处理人机验证。分批读取页面，并用浏览器补测 JavaScript 搜索和入口导航。未修改目录或站点地址。

29 个入口发起了搜索交互或搜索请求（包含导航站自身的站内检索，以及被服务端拒绝的请求）；8 个未能发起独立搜索，原因见表。请求返回 200 不等于找到资源，导航站搜索也不等于实际磁力索引检索。

| 入口 | 本轮记录 | 提取的磁力样本 |
| --- | --- | ---: |
| [无极磁链](https://wuji.me/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [无极磁链镜像](https://xcili.net/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [磁力熊猫](https://xiongmaoto.top/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [磁力炮](https://www.cilipao.pics/) | 首页访问受限/验证页，未继续操作 | 0 |
| [磁力么](https://www.cilime.lat/) | 首页访问受限/验证页，未继续操作 | 0 |
| [磁力搜索](https://cilisousuo.co/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [找磁力](https://www.1000zhaocili.xyz/) | 搜索请求受限/失败（HTTP 404） | 0 |
| [磁力蜘蛛](https://btmovi.cyou/) | 浏览器已提交关键词；本轮未提取到磁力 | 0 |
| [磁力王](https://www.ciliwang360.shop/) | 浏览器已提交关键词；本轮未提取到磁力 | 0 |
| [种子吧](https://zzb05.top/) | 浏览器已提交关键词；本轮未提取到磁力 | 0 |
| [磁力虎](https://www.cilihu.vip/) | 当前是备用入口发布页，没有独立搜索框 | 0 |
| [磁力大大](https://www.cilidada.org/v/) | 搜索按钮未完成交互，未计为搜索通过 | 0 |
| [BT之家 1LOU](https://www.1lou.pro/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [SeedHub](https://www.seedhub.cc/) | 首页访问受限/验证页，未继续操作 | 0 |
| [6V 电影](https://www.6vdyy.com/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [6V 电影备用](https://www.6v520.com/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [磁力熊](https://www.cilixiong.org/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [迅雷电影天堂](https://xunlei8.org/) | 搜索请求受限/失败（HTTP 404） | 0 |
| [比特大雄](https://www.btdx8.net/) | 提交后跳转《钢铁之泪》详情页，未证明关键词检索正确，待复核 | 0 |
| [飘花电影](https://www.piaohua.com/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [CHAOSPACE](https://www.chaospace.xyz/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [人人影视分享](https://yyets.click/) | 已提交搜索，返回搜索页；未提取磁力 | 0 |
| [人人电影网](https://www.rrdynb.com/) | 搜索请求受限/失败（HTTP 403） | 0 |
| [Ultra4K](https://dianying4k.com/) | 浏览器已提交关键词；本轮未提取到磁力 | 0 |
| [电影街](https://dyjie.net/) | 搜索请求返回登录页，不能验证检索结果 | 0 |
| [蜜柑计划 Mikan](https://mikanani.me/) | 搜索请求已返回；本轮未提取到磁力 | 0 |
| [Anime Garden](https://animes.garden/) | 浏览器已提交关键词，取得磁力 | 2 |
| [ACG.RIP](https://acg.rip/) | 首次首页可读；后续连接超时，未完成搜索 | 0 |
| [Nyaa](https://nyaa.si/) | 搜索请求已返回，取得磁力 | 1 |
| [Nyaa 中文站](https://cn.nyaa.net/) | 搜索请求已返回，取得磁力 | 1 |
| [樱花动漫 BT](https://yhdm33.com/) | 搜索请求受限/失败（HTTP 404） | 0 |
| [EZTV](https://eztvx.to/) | 搜索请求受限/失败（HTTP 403） | 0 |
| [RuTracker](https://rutracker.net/forum/index.php) | 搜索请求受限/失败（HTTP 403） | 0 |
| [Pirate Proxy](https://pirateproxy.tube/) | 代理入口导航页，没有独立磁力检索 | 0 |
| [BT蚂蚁磁力](https://btmayi.cc/) | 导航站站内检索已触发，未验证后续索引站 | 0 |
| [磁力搜索神器](https://cilishenqi.me/) | 导航站站内检索已触发，未验证后续索引站 | 0 |
| [迅雷下载天堂](https://xunleis.pro/) | 浏览器跳转为空白，未完成独立搜索 | 0 |

从 Anime Garden、Nyaa、Nyaa 中文站取得 4 条样本（3 个不同哈希），包含 Base32、十六进制、转义名称及多个 tracker。Soulo 的 `PeerDownloadLink` 和实际 `SLTorrentEngine.inspectMagnet` 均保留正确哈希。样本见测试资源 `SouloTests/ReadingFixtures/magnet-source-links.json`。

这些样本是旧版 Ubuntu/Koha 光盘资源。独立 libtorrent 2.0.11 工具进行 60 秒元数据检查，3 个不同哈希均未找到在线节点；同一会话的 Debian 对照获得元数据。这说明本轮样本可解析，但没有取得其可下载性证据，不能把 0% 归为解析错误，也不能据此声称站点所有资源无效。Soulo 的实际传输、选文件、断点恢复由真实 libtorrent 2.0.15 本机对等节点测试另外覆盖。

用户指定的 `065b4837e21de636289f83b7a99d10852feaa1c5` 已获得元数据及在线节点，独立检查到 MP4/4K HEVC Main、hev1、AAC，首个视频约 4.09 Mb/s，播放索引位于文件末尾且约 1.61 MB。仅抓取有界头尾分片诊断，没有下载完整影片。播放器兼容和暂停恢复的修改见 [本轮 App 检查](2026-11-01-install-and-browsing-audit.md)。

原始状态、查询 URL、响应、浏览器补测与元数据诊断保存在 `/tmp/soulo-install-browsing-audit-20261101/`。结果是本次网络条件下的记录，不代表网站永久可用性或任意资源都有做种。
