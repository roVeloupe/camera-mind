# AI 相机 · CameraMind

一台「会看画面的相机」：正常取景，按一下 AI 键，把当前画面 + 全部相机参数发给多模态模型，
模型的思考过程实时流式显示，返回**纯 JSON** 的完整参数方案，直接落到硬件与渲染管线，画面立刻变样。

---

## 快速开始

```bash
cd CameraMind
brew install xcodegen        # 若未安装
xcodegen generate            # 生成 CameraMind.xcodeproj
open CameraMind.xcodeproj
```

不想装 XcodeGen 的话：新建一个 iOS App 工程（SwiftUI，iOS 17+），把 `CameraMind/` 下所有
`.swift` 拖进去，并在 Info 里加 `NSCameraUsageDescription` 即可。

真机运行（模拟器没有摄像头）。

## 配置接口

App 内右上角齿轮：

| 字段 | 示例 |
|---|---|
| Base URL | `http://cheap-host1.cheapyun.com:20033/v1` |
| API Key | `wbk_...` |
| 模型 | `hy4free` |
| 思考模式 | 该网关默认返回 `reasoning_content`，选「关闭」即可（发送 `chat_template_kwargs` 可能被上游拒绝） |

思考必须由服务端开启，客户端只能"请求"。选错不会报错，只是思考面板为空——JSON 依然正常流式返回。
若服务端拒绝 `response_format: json_object`（部分多模态接口不支持），客户端会自动去掉该字段重试一次。

### 模型要求（重要）

这个 App 依赖模型输出**结构化参数**。实测 `hy4free` 是 `only_reasoning` 模型：`content` 里装的是思维链，
既不会调工具，也不肯只输出 JSON（纯提示词、`response_format`、`json_object` 都试过）。
客户端已做四层降级（tool call → assistant 预填 `{` → json_object → 纯文本），并会修复模板残留与全角标点，
但**换成支持结构化输出的视觉模型（Qwen-VL / GLM-4.6V / Gemini Flash 等）才能稳定工作**。

### 该网关的实测特性（2026-11-11）

- 图片必须用 **base64 data URI**，传公网 URL 会被上游以 `400 invalid_request / 11133` 拒绝。
- 模型 `hy4free` 是 `only_reasoning`，正文里会混入推理文本，所以解析器会在整段文本里**从后往前**找合法的 JSON 对象。
- 流式粒度很粗：一次请求通常只推 1–2 个 content chunk，思考是逐字来的。所以"参数逐条落下"主要发生在思考通道。
- 512×512 JPEG（22KB）视觉请求 TTFB 约 1.9s、整体约 7s；100KB 级大图曾出现 >100s 无响应，所以 AI 帧固定按原图 1/4（约 1000px、0.7 质量）上传。

任何 OpenAI 兼容、支持 `image_url` 的服务都能用。模型不支持 thinking 时，思考面板为空，
但 JSON 依然逐字流式解析、参数照样落地。

### 不想烧 token 联调

```bash
python3 server/mock_server.py --port 8787
```

Base URL 填 `http://<电脑IP>:8787/v1`，Key 随意。mock 会先吐 thinking，再把 JSON **故意切碎**
流式吐出，用来验证补全逻辑。

---

## 交互

1. 打开即是实时取景，画面已经是**调色后**的效果（Metal 直渲，30fps）。
2. 底部三键：**手动**（参数面板）、**AI**、**快门**。
3. 按 **AI**：截取当前帧（长边为原图的 1/4，约 1000px、~90KB，仅上传用） → 连同参数快照发给模型 → 思考流实时显示。
   参数**边收边套**到取景画面上，收完后再把硬件参数（ISO/快门/白平衡/变焦）下发给设备。
   **不会拍照**，也不会打断取景。
4. 按 **快门**：按当前硬件 + 调色参数拍一张，套完滤镜存进相册。
5. 所有改动实时持久化（UserDefaults），下次打开直接沿用。

顶部眼睛图标可切换「看原图」，用来对比调色效果。

## 参数覆盖

分两层，共 **58 项**。硬件层走 `AVCaptureDevice`，后期层走 Core Image。

### 硬件（capture，15 项，全部真实生效）

| 参数 | 范围/取值 | 实现 |
|---|---|---|
| lens | ultraWide / wide / tele | 设备支持检测 |
| zoom | 1.0 – maxZoom | `videoZoomFactor` |
| iso | minISO – maxISO | `setExposureModeCustom` |
| shutterSeconds | 1/8000 – 1s | 同上，按 format 夹取 |
| exposureMode | auto / manual | 模式切换 |
| exposureBias | -8 – +8 EV | `setExposureTargetBias` |
| focusMode | auto / locked | `setFocusModeLocked` |
| lensPosition | 0 – 1 | 同上 |
| whiteBalanceMode | auto / locked | `setWhiteBalanceModeLocked` |
| temperature | 2000 – 10000K | 近似换算成 RGB 增益，夹到 `maxWhiteBalanceGain` |
| tint | -150 – +150 | 同上，作用于绿通道 |
| torch | 0 – 1 | `setTorchModeOn(level:)` |
| hdr | bool | format 支持检测 |
| stabilization | off / standard / cinematic | 依设备能力 |
| aspect | 4:3 / 16:9 / 1:1 | 渲染裁剪 |

### 后期（grade，43 项）

| 分类 | 参数 | 实现方式 |
|---|---|---|
| 影调 | exposureEV | `CIExposureAdjust` |
| | brightness / contrast / saturation | `CIColorControls` |
| | highlights / shadows | `CIHighlightShadowAdjust` |
| | blacks / whites / curveShadows / curveMidtones / curveHighlights / fade | 自建 3D LUT |
| | gamma | `CIGammaAdjust` |
| | clarity / texture | `CIUnsharpMask`（双半径模拟中/高频） |
| | dehaze | 对比 + 饱和近似 |
| 色彩 | temperature / tint | `CITemperatureAndTint` |
| | vibrance | `CIVibrance` |
| | hueShift / monochromeMix / splitShadow* / splitHighlight* | 自建 3D LUT |
| | hsl（8 色带 × hue/sat/lum） | 自建 3D LUT |
| 细节 | sharpness | `CISharpenLuminance` |
| | noiseReduction / noiseReductionDetail | `CINoiseReduction` |
| | grain / grainSize | `CIRandomGenerator` + 柔光叠加 |
| 光学 | vignette / vignetteFeather | `CIVignette` |
| | bloom | `CIBloom` |
| | halation / chromaticAberration | 已入协议，渲染近似（见"已知限制"） |
| 几何 | straightenAngle / cropZoom / rotate90 | 仿射 + 裁剪 |
| | perspectiveVertical / perspectiveHorizontal | `CIPerspectiveCorrection` |
| 风格 | style / styleStrength | 语义标签，影响提示词与默认强度 |

**3D LUT 的意义**：曲线、分色、分离色调、黑白混合这十几项如果逐条挂滤镜，会互相打架且层数爆炸。
这里一次性生成 32³ 的查找表（约 52 万浮点），一次 `CIColorCubeWithColorSpace` 全部套上，且按参
数 hash 缓存，调参不会重复计算。

---

## 提示词设计

三处刻意的约束，决定了成品率：

1. **思考只在模型自己的 reasoning 通道**。system prompt 明确要求"不要在正文写思考"，
   客户端读 `reasoning_content` / `reasoning` / `thinking` 三个字段，谁有读谁。
2. **正文是纯 JSON**。禁止围栏、禁止前后缀，同时请求带 `response_format: json_object`；
   解析侧仍然做了防御（剥围栏、截断补全），因为不是所有服务都遵守。
3. **字段必须完整**。capture 和 grade 都要给全，避免"只返回一个 contrast"这种没法用的情况；
   同时 rationale 强制覆盖 8 个字段，方便你判断它是不是在瞎猜。

`userText` 里除了当前参数，还塞了 `SceneProbe` 算出的客观指标：平均亮度、亮度标准差、高光溢出
比例、暗部死黑比例、色偏。这些数字比让模型"看图猜曝光"准得多。

## 流式解析

模型吐出来的 JSON 在收完前都是残缺的。`StreamingJSON.balance()` 会：

- 剥掉 markdown 围栏与前缀废话
- 补全未闭合的字符串、数组、对象
- 删掉悬空的尾逗号与半截 key
- 忽略字符串内的括号，避免误判

所以参数是"一条条落下"的，不是等全部收完才显示。

## 已知限制

- 实时预览用 16³ LUT + 跳过颗粒/降噪/光晕，保证 30fps；**导出/拍照时用 32³ LUT 跑全链路**。
- 白平衡开尔文换算是近似（Tanner Helland 算法 + 归一化），与专业色温计有偏差。
- **halation / chromaticAberration** 已在协议与 UI 中，渲染目前是近似实现，后续可换成
  自写 Metal kernel。
- **白平衡开尔文换算是近似**（Tanner Helland 算法 + 归一化），与专业色温计有偏差；
  精确做法是走 `deviceWhiteBalanceGains` 的实测标定。
- 参数合法性靠三层兜底：提示词给范围 → `clamped()` 夹取 → 设备侧再按 `activeFormat` 夹一次。
- mock server 不校验图片，只用于联调链路。

## 目录

```
CameraMind/
├── project.yml                     # XcodeGen 工程描述
├── CameraMind/
│   ├── App/CameraMindApp.swift
│   ├── Camera/CameraController.swift    # 取景、手动参数、抓帧、快门
│   ├── Camera/CameraStore.swift         # 参数状态 + 持久化
│   ├── Model/CameraParameters.swift     # 49 项参数模型
│   ├── Model/AdjustmentParser.swift     # JSON → 结构体（含越界保护）
│   ├── Model/SceneProbe.swift           # 画面客观指标
│   ├── AI/VisionClient.swift            # SSE 流式 + 截断 JSON 补全
│   ├── AI/PromptBuilder.swift           # system prompt / user payload
│   ├── AI/AISession.swift               # 流状态机
│   ├── Render/GradeRenderer.swift       # LUT + 滤镜链（32³ / 16³ 快慢两档）
│   ├── Render/MetalCameraPreview.swift  # Metal 实时预览
│   ├── UI/CameraView.swift
│   ├── UI/Panels.swift                  # 思考 / 结果 / 参数 / 设置
│   └── Info.plist
└── server/mock_server.py
```

## 可以继续加的东西

- 实时预览调色（`AVCaptureVideoDataOutput` + Metal，把 LUT 搬到 shader）
- 连拍对比：同一场景存 3 套方案，横滑选
- 参数记忆：按场景类型（人像/夜景/风光）本地保存上次生效的方案
- 语音触发 + 触感反馈
