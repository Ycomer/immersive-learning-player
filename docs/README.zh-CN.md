# 沉浸式学习播放器 · Immersive Learning Player

在 Mac 本地播放视频，同时学习日语或英语对白。原文识别、中文字幕翻译和语境解释均在本机完成，无需云端推理 API。

目前是**开发预览版**，需要从源码构建，界面为简体中文。尚未提供签名安装包，也不承诺 98% 的原文或翻译准确率。

## 功能

- 打开本地 MP4/MOV，立即开始播放，同时在后台准备附近片段的字幕。
- 从音频识别原文，再翻译成中文；不是从画面里的中文字幕反推日文。
- 双语字幕直接叠加在视频中；可拖动和缩放遮挡区，把新字幕放在原有硬字幕的位置。
- 播放控制区可移动、调整透明度，并在鼠标静止后自动隐藏。
- 支持按句跳转、单句循环、导入/导出 SRT、修改原文、分别记住每个视频的识别语言。
- 点选字幕单词，结合前后对白解释用词，比较指定近义词替换后的差别。
- 识别与翻译结果缓存在本机，再次观看可复用。

## 准备和运行

当前参考环境是 Apple Silicon Mac、24 GB 统一内存、macOS 14 及以上。需安装 Xcode、Python、FFmpeg 和 Ollama；完整模型、环境、构建产物与缓存应预留约 **25–35 GB 或更多空间**。

```sh
git clone https://github.com/Ycomer/immersive-learning-player.git
cd immersive-learning-player
xcodebuild -project SubtitleStudy.xcodeproj -scheme SubtitleStudy \
  -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/Immersive Learning Player.app"
```

只构建源码可播放视频和导入字幕；自动识别、翻译需要按 [安装指南](SETUP.md) 另外准备模型。项目内部 scheme 名仍为 `SubtitleStudy`。

当前模型组合：Qwen3-ASR 1.7B 8bit 负责原文识别，ForcedAligner 0.6B 8bit 负责时间对齐，Silero 负责人声检测，Whisper large-v3 辅助复核；TranslateGemma 12B 负责中文翻译，Qwen3 4B Instruct 负责语境学习及部分翻译兜底。权重不随源码发布。

默认优先连续播放，首次观看可能还没生成到当前字幕。如需等字幕准备好再播放，可开启“等待字幕再播放（学习模式）”。后台分段处理不能保证在所有电脑上实时完成。

## 使用和排查

- **⌘O** 打开视频；**⌘I** 导入字幕；空格播放/暂停；**⌘← / ⌘→** 切换句子；**⌘R** 单句循环。
- 明显说话却没有原文时，先核对当前视频识别语言、音轨以及设置里的 Python/模型/工具路径。低可信度语音会被标记为未确认，不能把这种情况理解为视频一定没人在说话。
- 没有中文时，检查本地 Ollama 是否启动，以及设置中的模型是否已经下载。
- 视频画面内的硬字幕只能遮挡，不能恢复被原字幕覆盖的画面。
- 小声、多人重叠、音乐、俗语和省略句仍可能识别或解释错误。发现问题请提供可公开的短样本、时间点、模型配置和复现步骤。

运行 `sh scripts/check.sh` 可执行基础回归与构建，不会下载模型或调用模型推理。更多说明见 [测试指南](TESTING.md)。

字幕、译文和修改保存在 `~/Library/Application Support/SubtitleStudy`；设置沿用 `com.local.SubtitleStudy`。运行时语音识别禁止联网，翻译只接受本机回环地址。依赖安装及模型下载需要联网。

项目源码使用 [MIT 许可证](../LICENSE)；模型、第三方工具和视频素材使用各自许可证，详见 [第三方说明](../THIRD_PARTY_NOTICES.md)。
