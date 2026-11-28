# 更新日志

本仓库是 [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) 的 fork。
版本号沿用 `main.lua` 中的 `VERSION`，格式为 `上游版本.修订号`。

## [2.2.0.7] - 2026-11-28

- 示例配置启用 `vf_fps_keep`，在启播阶段准备适用片源的弹幕滤镜。
- 将透明度设置移到弹幕显示参数一组。

## [2.2.0.6] - 2026-11-28

- 移除强制转 HDR10 的兼容模式。新增 `vf_fps_dolby_vision`，默认跳过 Dolby Vision 片源的弹幕 fps 滤镜，避免挂载滤镜时发生偏色、闪烁或停顿。设为 `yes` 可按通用配置启用滤镜。

## [2.2.0.5] - 2026-11-28

- 所有片源统一在启播约 1 秒后读取和显示本地弹幕缓存，错开启播时的视频滤镜配置与 XML 解析。

## [2.2.0.4] - 2026-11-28

- `vf_fps_keep` 在启播阶段配置滤镜，避免首次显示弹幕时重建视频滤镜链造成短暂停顿。
- 新增默认开启的 `vf_fps_dolby_vision_hdr10`。有 HDR10 兼容层的 Dolby Vision 片源可固定以 HDR10 输出并保留高帧率弹幕，避免色彩参数反复切换造成闪烁。开启时会改用 HDR10，Dolby Vision 动态元数据不会生效。

## [2.2.0.3] - 2026-11-27

基于上游 `2.2.0`（`Tony15246/uosc_danmaku` @ `74ade6c`）同步后的首个发行版。
上游已包含的功能（搜索历史、屏蔽词可视化菜单、`title_replace`、多 `api_server`
有序列表、`mp.input` 无 uosc 菜单等）不再重复列出，以下仅列本仓库相对该基线的改动。

### 新增

- 自动匹配总开关 `auto_matching`：状态持久化到历史文件，跨文件与重启保持；
  可绑定快捷键（`auto_matching_keyboard_key`）并通过 uosc 控件切换
- `auto_match_ambiguous_action`：自动匹配命中多集且标题无明确集数时，
  可选 `skip`（默认，仅提示）/ `menu`（打开剧集列表）/ `first`（旧行为）
- `show_danmaku_default`：弹幕显示开关的初始状态（历史文件存在时以历史为准）
- `vf_fps_keep`：播放期间保留 fps 滤镜，关闭弹幕不再重建滤镜链，避免高负载片源卡顿
- `save_danmaku_local_mode`：普通本地视频可选保存到视频同目录或 `save_danmaku_path`
- 完整示例配置 `uosc_danmaku.conf` 与 `title_replace.example.json`

### 变更

- 自动匹配流程不再把“空结果 / 全部源被屏蔽”当作加载成功：
  空结果提示“自动匹配未找到弹幕”，全屏蔽源时静默隐藏，均不改变显示开关状态
- B 站 cid 获取统一走 `track-list` 与站点 API 反查，移除 ytdl JSON 兜底逻辑
- 爱奇艺临时文件清理逻辑简化，避免多实例互相删除临时文件
- 屏蔽词 JSON 读取容忍 UTF-8 BOM
- 移除 `auto_fallback_search`，其场景由 `auto_match_ambiguous_action` 覆盖

### 修复

- `message_alignment` 选项拼写错误（原为 `message_aligment`）
- 字幕/弹幕开关在自动匹配场景下的显示状态判断

### 移除

- 内置脚本自动更新 / 检查更新（`check-update` 与 `modules/update.lua`），
  避免被上游发行版覆盖本 fork 的修改；更新请手动拉取本仓库

### 仓库

- 新增 `.gitattributes`（统一 LF）与 `.gitignore`
- 新增 `CHANGELOG.md`，补齐 GitHub Release 与安装文档
