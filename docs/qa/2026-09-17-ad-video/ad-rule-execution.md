# 广告规则执行回归（2026-09-18）

真实下载 7 个已启用订阅，合并 152,007 条网络规则、79,061 条元素规则、3,108 条元素例外，全部 12 个 WebKit 批次编译成功。结果：`/tmp/soulo-abp-final-live.xcresult`。

解析与执行：保留 URL 锚点、路径、分隔符、大小写、资源类型和域名限制；网络白名单在每个批次生效；元素例外、document / elemhide / generichide 例外分别处理。取消旧版 4,000 / 2,000 条截断，缓存升级到文件，旧解析版本失效并安排刷新。未知选项和不支持语法整条跳过，避免扩大范围误杀。

限制：不是完整 uBlock 引擎。脚本片段、重定向、原始正则和部分资源类型选项不执行；WebKit 无法组合多个域名条件时保守跳过有歧义的分支。badfilter 仅处理同一订阅中的对应规则。

本地原生 WebKit 请求、CSS、跨批次例外以及既有手工标记用例已验证；此前 68 项回归中最后一个内置规则用例的缓存隔离问题已修正并单独通过。真实 pianbs、yinsuw 每站底部 3 次点击、进入退出标记 2 次，均保持页面且广告未重新显示：`/tmp/soulo-fullrules-real-ui.xcresult`。截图导出 `/tmp/soulo-fullrules-real-shots`。

随后完整相关 216 项回归全部通过，包括上述全部广告用例：`/tmp/soulo-browser-full-regression.xcresult`。
