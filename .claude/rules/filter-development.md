---
description: 新图像滤镜开发规则。添加 Pipeline/Effects 下新滤镜时必须先完成算法选型 + 业界参考调研，再写代码
globs:
  - "**/Pipeline/Effects/**/*.metal"
  - "**/Pipeline/Effects/**/*.swift"
---

# 滤镜开发规则

## 核心原则：算法选型先于实现

写任何新滤镜前，**必须**先回答以下 3 个问题并得到用户批准。不得跳过这步直接写代码。

## 第 1 步：维度分类

| 类型 | 特征 | 示例 | 算法选型规则 |
|------|------|------|------------|
| **1D 逐像素** | 一个像素值 → 一个像素值 | 曝光、对比度、饱和度、白色、黑色、曲线 | 必须先列 ≥2 个原理派算法候选 |
| **2D 邻域** | 需要邻居像素 | 锐化、模糊、边缘检测 | 必须基于有明确来源的教科书算法 |
| **多尺度** | 需要不同分辨率信息 | Bloom、高光阴影、清晰度 | 必须多 pass 金字塔 / guided filter / 同类架构 |

## 第 2 步：算法候选清单

根据分类，列出候选：

- **1D 逐像素**：列 ≥2 个原理派（S 曲线 / 幂律 / 对数曲线 / Extended Reinhard / 参数化 Tone Curve / Filmic 曲线...），**经验拟合是最后手段**
- **2D 邻域**：指名具体算法（Laplacian unsharp mask / Sobel / Gaussian / Bilateral / Guided Filter / Kuwahara...）
- **多尺度**：指名结构（Dual Kawase / Laplacian Pyramid / Mip Chain / Gaussian Pyramid / Local Laplacian...）

## 第 3 步：业界参考验证

用 WebSearch 至少检索 1 个业界实现（论文 / 开源项目 / 官方教程），**确认你选的算法是该类问题的常见解**，不是自创的经验公式。

候选来源优先级：
1. SIGGRAPH / ACM 论文
2. LearnOpenGL / NVIDIA GPU Gems
3. darktable / RawTherapee / GIMP 开源代码
4. Adobe / DaVinci Resolve / Apple 官方文档
5. 个人博客（最低优先级，仅作辅助参考）

## 第 4 步：Doc comment 必须包含模型形式理由

```swift
/// Model form justification:
///   - 类型：[1D逐像素 | 2D邻域 | 多尺度]
///   - 选用算法：[具体算法名 + 论文/教程引用]
///   - 为什么不用 [替代方案]：[理由]
```

**红旗信号**：如果理由写"因为拟合 MSE 最低"、"这个公式试出来效果最好"、"自己拟合了几个模型挑了最好的" —— 重新回到第 2 步列原理派候选。

## 像素级拟合的正确定位

`.claude/skills/pixel-fitting/` 是**验证工具**，不是**选型工具**：

| | 做法 | 评估 |
|--|------|------|
| ✅ 正确 | 先选原理派算法 → 实现 → 用像素级拟合**验证**输出是否接近竞品 | 算法 principled，数值达标 |
| ❌ 错误 | 列 5 个经验公式 → 挑 MSE 最低的作为最终方案 | 算法无原理，代码不可维护 |

原理派算法如果拟合不上竞品：
1. 先尝试加修正项（例如：曝光 = 线性 gain + Reinhard rolloff，而非纯经验曲线）
2. 修正项也救不回来时，才考虑纯经验 — 并在 doc comment 中记录"试过哪些原理派、差距多少、为什么放弃"

## 为什么这条规则存在

### 1D 滤镜的经验拟合陷阱

Weierstrass 近似定理：2-3 参数的平滑函数家族几乎能拟合任何 1D 单调函数。因此：

- MSE 低 ≠ 算法对
- 任何经验公式都能"看起来很准"
- 但换场景 / 换维度 / 联合使用时会暴露问题

### 2D/多尺度的暗雷

维度一上升，经验拟合立刻失效。但开发者容易**用低质量近似代替教科书算法**（例：用 25 采样稀疏伪 bloom 代替多 pass 金字塔）。这条规则要求必须指名具体算法，防止此类偷懒。

## 适用范围

- ✅ 新增滤镜
- ✅ 重构已有滤镜的核心算法
- ⚠️ 调整滤镜参数（极值压缩 / 默认值）不需要走完整流程，但仍应遵循第 4 步 doc comment 要求

---

## 🔴 SDK 输出契约（硬约束）

**Why 这条是硬的**：用户编辑预览出现"脏黑斑 / blob"的真凶就是 Sat/Vib 漏掉这条契约——上游 WhiteBalance 在 perceptual 模式下输出含负值的 gamma 像素，OKLab 滤镜没做 sanitisation 直接喂给 `pow(abs(x), 1/3)`，gamut clamp 收敛到错误的 L → 黑斑。这类 bug 不会 crash，只会把视觉结果污染，且穿过整条 chain 才暴露——**必须在源头阻止**。

### C.1 输出非负契约

**每个 filter body 的 `return half3(...)` 输出必须满足 `r, g, b ≥ 0`**（HDR `> 1` 允许保留）。

理由：
- OKLab 数学（Sat/Vib/未来基于 OKLab 的滤镜）只对 non-negative linear sRGB 有定义；
- `bgra8Unorm` 写到 8-bit 显示面时负值被静默 clamp 到 0 → "黑斑"；
- 物理意义：负光 = 没有定义。

**机制化执行**：`Tests/DCRenderKitTests/Contracts/SDKFilterOutputContractTests.swift` 对每个 SDK 滤镜跑非负检查。**新增滤镜必须加一个 `test<FilterName>AtExtremesIsNonNegative()` 方法**，覆盖：
- 5 个代表性输入 patch（grey / skin / 三原色 / saturated near-edge）
- ≥ 2 个极端参数组合（slider 极值 + 反向极值）

测试模板：
```swift
func testYourFilterAtExtremesIsNonNegative() throws {
    for probe in probes {
        for v in [Float(-100), Float(+100)] {  // 适配你的 slider 范围
            let source = try makeSinglePatchTexture(probe)
            let output = try runFilter(source: source, filter: YourFilter(slider: v))
            let p = try readCentrePixel(output)
            assertOutputNonNegative(p, filter: "YourFilter", input: probe, params: "v=\(v)")
        }
    }
}
```

**实现侧守则**：filter body 内做必要的 `clamp` / `max(c, 0)` / 边界裁剪。不要假设上游不会喂 OOG，因为：
1. 别的 filter 的极端参数可能在内部产生 OOG（YIQ 矩阵、Sharpen 的 Laplacian 等）；
2. SDK 是 HDR-aware 的，中间 `rgba16Float` 可以承载 OOG 值，但你这一站要把它消化掉。

### C.2 colorSpace 参数契约

**每个对 RGB 几何敏感的 filter（OKLab / log / 任何非线性曲线）必须接受 `colorSpace: DCRColorSpace` 参数**，并在 body 里据此做 gamma↔linear 转换。

理由：
- SDK 支持 `.linear` 和 `.perceptual` 两种 pipeline 模式（DCRenderKit.defaultColorSpace 切换）；
- 在 perceptual 模式下源纹理装的是 sRGB-gamma encoded bytes，filter body 拿到的就是 gamma 值；
- 任何对"linear sRGB 数值"敏感的数学（OKLab、log-slope 对比度、Reinhard tonemap、guided filter）在 gamma 值上跑就是错的；
- 12 个内建滤镜里只有 Saturation / Vibrance 漏了这条契约——结果用户在 perceptual 编辑预览里就看到了黑斑。

**实施模板**（mirror Exposure / Contrast / WhiteBalance 的标准）：

```swift
public struct YourFilter: FilterProtocol {
    public var slider: Float
    public var colorSpace: DCRColorSpace

    public init(
        slider: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) { ... }

    public var uniforms: FilterUniforms {
        FilterUniforms(YourUniforms(
            slider: slider,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }
}

struct YourUniforms {
    var slider: Float
    var isLinearSpace: UInt32     // 必须是 UInt32（Metal `uint` 对齐）
}
```

shader body：

```metal
struct YourUniforms {
    float slider;
    uint  isLinearSpace;
};

inline half3 DCRYourBody(half3 rgbIn, constant YourUniforms& u) {
    const bool isLinear = (u.isLinearSpace != 0u);
    
    // C.1 sanitisation + C.2 gamma→linear 二合一
    const float3 sanitised = max(float3(rgbIn), 0.0f);
    const float3 rgbLinear = isLinear ? sanitised : float3(
        DCRSRGBGammaToLinear(sanitised.x),
        DCRSRGBGammaToLinear(sanitised.y),
        DCRSRGBGammaToLinear(sanitised.z)
    );
    
    // ... 你的 linear-domain 数学 ...
    
    // 出口对应转回 gamma
    if (isLinear) return half3(rgbOut);
    return half3(
        DCRSRGBLinearToGamma(rgbOut.x),
        DCRSRGBLinearToGamma(rgbOut.y),
        DCRSRGBLinearToGamma(rgbOut.z)
    );
}
```

**FusionHelperSource 注册**：在 `helpersForBody(named:)` 加入 `srgbGamma` helper（如果没用 OKLab 则可省）。

**FusionBody.wantsLinearInput 设为 `false`**——这是 fusion 的 metadata，告诉 VerticalFusion "我能与同样自处理 colorSpace 的兄弟节点融成一个 cluster"，不是说 body 真想要 gamma 输入。所有内建 tone/colour 滤镜都用 `false`，让它们彼此之间能融合。

### C.3 自检 checklist（merge 前过一遍）

写完新 filter，在 PR 描述里勾完：

- [ ] body 入口对 OOG/负输入做了 sanitisation（C.1）
- [ ] 如对线性 RGB 几何敏感，加了 `colorSpace` 参数 + isLinearSpace 分支（C.2）
- [ ] `Tests/DCRenderKitTests/Contracts/SDKFilterOutputContractTests.swift` 加了 `test<FilterName>AtExtremesIsNonNegative` 测试方法
- [ ] linear/perceptual 两种模式都跑通，identity 在两种模式下都成立
- [ ] `swift test` 全绿，零 warning
