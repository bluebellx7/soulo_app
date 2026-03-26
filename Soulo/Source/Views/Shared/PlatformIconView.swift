import SwiftUI

struct PlatformIconView: View {
    let platform: SearchPlatform
    var size: CGFloat = 28
    var showLabel: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            if UIImage(named: platform.iconName) != nil {
                Image(platform.iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            } else if platform.faviconURL != nil || platform.isCustom {
                // Custom platform — fetch favicon from site
                let urlStr = platform.homeURL.isEmpty ? platform.searchURLTemplate : platform.homeURL
                BookmarkFaviconView(urlString: urlStr, size: size)
            } else {
                sfSymbolFallback
            }

            if showLabel {
                Text(LanguageManager.shared.localizedString(platform.name))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var sfSymbolFallback: some View {
        Image(systemName: platformSFSymbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    private var platformSFSymbol: String {
        switch platform.iconName {
        case "icon_deepseek":    return "brain.head.profile"
        case "icon_qianwen":     return "sparkles"
        case "icon_yuanbao":     return "brain"
        case "icon_doubao":      return "bubble.left.and.text.bubble.right.fill"
        case "icon_bing":        return "magnifyingglass"
        case "icon_duckduckgo":  return "shield.checkered"
        case "icon_github":      return "chevron.left.forwardslash.chevron.right"
        case "icon_wikipedia":   return "book.closed.fill"
        case "icon_perplexity":  return "sparkle.magnifyingglass"
        case "icon_instagram":   return "camera.fill"
        case "icon_linkedin":    return "briefcase.fill"
        case "icon_pinterest":   return "pin.fill"
        case "icon_ebay":        return "cart.fill"
        case "icon_stackoverflow":return "text.bubble.fill"
        case "icon_scholar":     return "graduationcap.fill"
        case "icon_sogou":       return "magnifyingglass"
        case "icon_360":         return "shield.fill"
        case "icon_toutiao":     return "newspaper.fill"
        case "icon_youku":       return "play.rectangle.fill"
        case "icon_iqiyi":       return "play.tv.fill"
        case "icon_netease_music":return "music.note"
        case "icon_csdn":        return "chevron.left.forwardslash.chevron.right"
        case "icon_juejin":      return "diamond.fill"
        case "icon_rakuten":     return "bag.fill"
        case "icon_niconico":    return "play.circle.fill"
        case "icon_douyin", "icon_tiktok": return "play.circle.fill"
        case "icon_bilibili":    return "play.tv.fill"
        case "icon_xiaohongshu": return "heart.text.square.fill"
        case "icon_weibo":       return "bubble.left.fill"
        case "icon_zhihu":       return "questionmark.circle.fill"
        case "icon_baidu":       return "magnifyingglass.circle.fill"
        case "icon_taobao", "icon_amazon", "icon_jd": return "cart.fill"
        case "icon_wechat":      return "message.fill"
        case "icon_kimi":        return "moon.stars.fill"
        case "icon_metaso":      return "sparkle.magnifyingglass"
        case "icon_tiangong":    return "sparkles"
        case "icon_phind":       return "chevron.left.forwardslash.chevron.right"
        case "icon_you":         return "magnifyingglass.circle.fill"
        case "icon_google":      return "globe"
        case "icon_youtube":     return "play.rectangle.fill"
        case "icon_twitter":     return "at.circle.fill"
        case "icon_reddit":      return "bubble.left.and.bubble.right.fill"
        case "icon_yahoo_jp":    return "y.circle.fill"
        case "icon_yandex":      return "magnifyingglass"
        case "icon_vk":          return "person.2.fill"
        default:                 return "globe"
        }
    }
}

// MARK: - Platform Text Label
struct PlatformLabel: View {
    let name: String
    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Text(languageManager.localizedString(name))
    }
}
