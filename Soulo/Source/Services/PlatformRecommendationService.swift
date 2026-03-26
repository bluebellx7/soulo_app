import Foundation

struct PlatformRecommendationService {
    // Category keywords in both English and Chinese
    private static let categories: [(name: String, keywords: [String], platforms: [String])] = [
        ("shopping", ["buy", "price", "cheap", "deal", "product", "shop", "store", "order", "买", "价格", "便宜", "商品", "购买", "下单", "打折", "优惠"],
         ["platform_taobao", "platform_jd", "platform_amazon"]),
        ("video", ["video", "watch", "clip", "movie", "film", "episode", "mv", "vlog", "tutorial", "视频", "看", "电影", "剧", "番", "教程", "直播"],
         ["platform_youtube", "platform_bilibili", "platform_douyin", "platform_tiktok"]),
        ("social", ["post", "tweet", "trending", "news", "comment", "帖子", "热搜", "新闻", "评论", "八卦", "吃瓜"],
         ["platform_weibo", "platform_twitter", "platform_reddit", "platform_xiaohongshu"]),
        ("knowledge", ["how to", "why", "what is", "explain", "review", "compare", "vs", "怎么", "为什么", "是什么", "教程", "评测", "对比", "推荐"],
         ["platform_zhihu", "platform_google", "platform_baidu", "platform_reddit"])
    ]

    @MainActor static func recommend(for keyword: String) -> [SearchPlatform] {
        let lower = keyword.lowercased()
        var scores: [String: Int] = [:] // platform name -> score

        for category in categories {
            let matchCount = category.keywords.filter { lower.contains($0) }.count
            if matchCount > 0 {
                for platform in category.platforms {
                    scores[platform, default: 0] += matchCount
                }
            }
        }

        guard !scores.isEmpty else { return [] }

        let allPlatforms = PlatformDataStore.shared.allPlatforms()
        let sorted = scores.sorted { $0.value > $1.value }

        return sorted.prefix(4).compactMap { entry in
            allPlatforms.first { $0.name == entry.key && $0.isVisible }
        }
    }
}
