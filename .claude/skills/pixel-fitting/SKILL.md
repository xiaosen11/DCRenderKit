---
description: 像素级拟合图像处理算法。Use when implementing or tuning image filters (exposure, contrast, whites, blacks, highlights, shadows, etc.) by fitting mathematical models to reference output images (e.g., Lightroom exports).
---

# 像素级拟合图像处理算法

## 触发条件

当需要实现或调优图像处理滤镜，且有参考图像（如 Lightroom/Snapseed/Apple Photos 的导出）可对比时使用。

## 前置材料

用户需要提供：

1. **原图** — 未经处理的基准图（JPEG/PNG）
2. **参考图** — 目标软件导出的效果图，每张只调一个参数
   - **必须**：极值 ±100
   - **推荐**：多个中间值（±25, ±50, ±75）— 用于验证插值函数
3. **精确的 slider 值** — 每张参考图对应的参数值（不要只说"正向/负向"）
4. **2-3 种不同场景**（**必须**）— 验证模型泛化性和参数自适应性
   - 至少 3 张不同亮度分布的原图（如：亮调日落、暗调夜景、中间调风景）
   - 每张只需原图 + 极值 ±100 = 6 张额外图
   - **教训（对比度）**：单图拟合 per-channel 参数 MSE=70 看似很好，跨场景直接崩到 MSE=116。单图过拟合是最大的坑

命名规范：`原图.jpg`、`曝光+100.jpg`、`曝光+50.jpg`、`曝光-25.jpg` 等。

直方图和频谱由分析脚本自动生成（依赖 numpy + scipy + matplotlib + Pillow）。

## 分析流程

### Step 1: 自动化直方图 + 频谱分析（定性判断）

从原图和参考图自动生成直方图和频谱，判断效果类别。**不需要用户手动截图。**

```python
import numpy as np
from PIL import Image
import matplotlib.pyplot as plt
from scipy.fft import fft2, fftshift

def analyze_image_pair(orig_path, ref_path, output_dir, label):
    """生成直方图对比 + 频谱对比 + 差异热力图"""
    orig = np.array(Image.open(orig_path)).astype(np.float32)
    ref = np.array(Image.open(ref_path)).astype(np.float32)
    
    # ── 1a. RGB 直方图对比 ──
    fig, axes = plt.subplots(2, 1, figsize=(12, 6))
    for ch, color in enumerate(['red', 'green', 'blue']):
        axes[0].hist(orig[:,:,ch].ravel(), bins=256, range=(0,255),
                     alpha=0.5, color=color, label=f'原图 {color[0].upper()}')
        axes[1].hist(ref[:,:,ch].ravel(), bins=256, range=(0,255),
                     alpha=0.5, color=color, label=f'{label} {color[0].upper()}')
    axes[0].set_title('原图直方图'); axes[0].legend()
    axes[1].set_title(f'{label} 直方图'); axes[1].legend()
    plt.tight_layout()
    plt.savefig(f'{output_dir}/histogram_{label}.png', dpi=100)
    plt.close()
    
    # ── 1b. 亮度直方图叠加对比 ──
    luma_orig = 0.2126*orig[:,:,0] + 0.7152*orig[:,:,1] + 0.0722*orig[:,:,2]
    luma_ref  = 0.2126*ref[:,:,0]  + 0.7152*ref[:,:,1]  + 0.0722*ref[:,:,2]
    fig, ax = plt.subplots(figsize=(12, 4))
    ax.hist(luma_orig.ravel(), bins=256, range=(0,255), alpha=0.6, label='原图', color='gray')
    ax.hist(luma_ref.ravel(), bins=256, range=(0,255), alpha=0.6, label=label, color='orange')
    ax.set_title(f'亮度直方图对比: 原图 vs {label}'); ax.legend()
    plt.tight_layout()
    plt.savefig(f'{output_dir}/luma_histogram_{label}.png', dpi=100)
    plt.close()
    
    # ── 1c. 频谱分析（2D FFT 幅值谱）──
    # 判断效果是否涉及空间频率变化（如清晰度/锐化/模糊 vs 纯色调操作）
    gray_orig = np.mean(orig, axis=2)
    gray_ref  = np.mean(ref, axis=2)
    fft_orig = fftshift(np.abs(fft2(gray_orig)))
    fft_ref  = fftshift(np.abs(fft2(gray_ref)))
    # 径向平均频谱（1D 功率谱）
    h, w = gray_orig.shape
    Y, X = np.ogrid[-h//2:h//2, -w//2:w//2]
    R = np.sqrt(X*X + Y*Y).astype(int)
    max_r = min(h, w) // 2
    radial_orig = np.array([fft_orig[R == r].mean() for r in range(max_r)])
    radial_ref  = np.array([fft_ref[R == r].mean() for r in range(max_r)])
    
    fig, ax = plt.subplots(figsize=(12, 4))
    freqs = np.arange(max_r)
    ax.semilogy(freqs[1:], radial_orig[1:], label='原图', alpha=0.7)
    ax.semilogy(freqs[1:], radial_ref[1:], label=label, alpha=0.7)
    ax.set_xlabel('空间频率（像素⁻¹）')
    ax.set_ylabel('幅值（log）')
    ax.set_title(f'径向功率谱: 原图 vs {label}')
    ax.legend()
    plt.tight_layout()
    plt.savefig(f'{output_dir}/spectrum_{label}.png', dpi=100)
    plt.close()
    
    # ── 1d. 定性判断 ──
    hist_shift = np.median(luma_ref) - np.median(luma_orig)
    hist_std_ratio = np.std(luma_ref) / max(np.std(luma_orig), 0.01)
    spectrum_ratio = np.mean(radial_ref[1:max_r//4]) / max(np.mean(radial_orig[1:max_r//4]), 0.01)
    
    print(f"\n{'='*60}")
    print(f"定性分析: {label}")
    print(f"{'='*60}")
    print(f"  亮度中位数偏移: {hist_shift:+.1f} ({'提亮' if hist_shift > 5 else '压暗' if hist_shift < -5 else '不变'})")
    print(f"  直方图宽度比: {hist_std_ratio:.2f} ({'展宽=加对比' if hist_std_ratio > 1.1 else '收窄=减对比' if hist_std_ratio < 0.9 else '不变'})")
    print(f"  低频能量比: {spectrum_ratio:.2f} ({'低频增强' if spectrum_ratio > 1.2 else '低频减弱' if spectrum_ratio < 0.8 else '不变'})")
    
    # 判断效果类型
    is_spatial = abs(spectrum_ratio - 1.0) > 0.15  # 频谱变化 > 15% = 空间操作
    if is_spatial:
        print(f"  → 涉及空间频率变化（可能是锐化/模糊/清晰度/高光阴影LLF）")
    elif abs(hist_shift) > 20:
        print(f"  → 全局亮度偏移（曝光类）")
    elif abs(hist_std_ratio - 1.0) > 0.15:
        print(f"  → 对比度变化（S 曲线类）")
    else:
        print(f"  → 微小端点调整（白色/黑色类）")
    
    return {
        'hist_shift': hist_shift,
        'hist_std_ratio': hist_std_ratio,
        'spectrum_ratio': spectrum_ratio,
        'is_spatial': is_spatial,
    }
```

**定性判断决策表**：

| 指标 | 阈值 | 判定 | 候选模型方向 |
|------|------|------|------------|
| 亮度中位数偏移 > 20 | 全局提亮/压暗 | 曝光类 | 线性增益 / Reinhard / power |
| 直方图宽度比 > 1.1 或 < 0.9 | 对比度变化 | S 曲线类 | Bezier / NURBS / power pivot |
| 低频能量比偏离 1.0 > 15% | 空间频率变化 | 空间操作 | 不适合纯 1D 曲线，需要多 pass（LLF/清晰度） |
| 以上均不显著 | 端点微调 | 白色/黑色 | headroom/floor + mask |

**频谱分析的关键作用**：区分**纯色调操作**和**空间操作**，决定走哪个分支。

---

### ⚡ 分支判断：Branch A（色调）vs Branch B（空间）

频谱分析后立即做分支判断：

| 判据 | Branch A（色调） | Branch B（空间） |
|------|----------------|----------------|
| 频谱形状 | 不变（幅值缩放） | 显著改变 |
| 典型效果 | 曝光/对比度/白色/黑色 | 高光/阴影/清晰度/锐化/去雾 |
| 核心问题 | "input→output 的曲线是什么？" | "改了 base/detail/边缘中的哪一层？" |
| 算法确定方式 | 从数据拟合（候选模型 curve_fit） | **先选行业通用算法框架，再用像素拟合调参** |

**Branch A** → 继续下面的 Step 2-8（1D 曲线拟合流程）。

**Branch B** → 跳转到下面的"Branch B: 空间效果流程"。

---

### Branch B: 空间效果流程

**核心原则：先选架构再调参。已知效果直接查表选算法，不需要先跑 1D 来"确认是不是空间效果"。**

#### B1. 确定行业通用算法框架

已知效果直接查表：

| 效果类型 | 行业通用算法 | 复杂度 |
|---------|------------|--------|
| 高光/阴影 | Guided Filter base/detail 或 Local Laplacian | 中 |
| 清晰度 | Guided Filter base + detail 增强，或 Laplacian 金字塔中频缩放 | 中 |
| 锐化 | Laplacian unsharp mask（4 邻域） | 低 |
| 去雾 | Dark Channel Prior (He et al. 2009) 或 guided filter | 中 |
| 纹理 | 多尺度 detail 分解 | 中-高 |

**不要自创算法。** 先从已有的、被验证的算法库中选，再根据产品需求和性能预算做取舍。

未知/自定义效果才需要先跑 1D baseline 诊断空间成分占比。

#### B2. 实现算法框架 + 用像素拟合调参

选定算法框架后，用参考图做参数调优：
1. 实现算法的 Python 模拟版（numpy，不是 Metal）
2. 对参考图跑模拟，用 MSE 比较
3. 网格搜索 / scipy.optimize 调参（eps, radius, strength, threshold 等）
4. 跨场景验证参数稳定性（同 Branch A）

**验证指标不同于 Branch A**：
- 不能只看全图 MSE（高光区完美但阴影区差，全图 MSE 可能还不错）
- 必须分区统计：高光 MSE / 阴影 MSE / 边缘 MSE / 平坦区 MSE
- 边缘保序性：边缘附近有没有 halo / 色阶断裂 / 波纹
- 感知连续性：slider 从 0 缓慢增加时效果是否平滑

#### B3. Metal Shader 实现 + 回归验证

同 Branch A 的 Step 7-8，但额外检查：
- 多 dispatch 的中间纹理格式（rgba16Float for signed values）
- 边缘处的视觉质量（放大看 2x-4x）
- 性能：dispatch 次数、纹理读取量、中间纹理内存

#### 经验教训（高光/阴影 + 清晰度迭代沉淀）

1. **不要试图用 1D 曲线替代空间操作**。高光/阴影用 1D ratio → 效果 ≈ 全局曲线，局部性为零
2. **remap 函数的作用位置至关重要**。作用在 detail 上 → 效果像清晰度/锐化；作用在 base 上 → 才是高光/阴影
3. **Gaussian base 跨边缘是最大画质短板**。必须用 edge-aware 方法（guided filter / bilateral）
4. **金字塔重建有波纹风险**。bilinear upsample 和 Gaussian downsample 不匹配时，Laplacian 重建产生系统性纹理
5. **单 kernel bilateral 是 guided filter 的实用近似**。48 点多尺度 bilateral 约等于 guided filter 的 80% 质量，1 dispatch
6. **CombinationBase 兼容性**。Harbeth 的 CombinationBase 对某些 filter 不稳定（ClarityFilter 崩溃），复用已验证的 sub-kernel 更安全
7. **参数必须解耦**。共享的 kernel 函数的参数（radius, eps）必须由调用方传入，不能写死常量

---

### Step 2: 像素级传输曲线提取 + 可视化（Branch A 继续）

用 numpy + matplotlib 提取并可视化传输曲线：

```python
def extract_transfer_curve(orig_path, ref_path, output_dir, label):
    """提取 input→output 映射并生成传输曲线图"""
    orig = np.array(Image.open(orig_path)).astype(np.float32)
    ref = np.array(Image.open(ref_path)).astype(np.float32)
    
    # 亮度映射
    luma_orig = 0.2126*orig[:,:,0] + 0.7152*orig[:,:,1] + 0.0722*orig[:,:,2]
    luma_ref  = 0.2126*ref[:,:,0]  + 0.7152*ref[:,:,1]  + 0.0722*ref[:,:,2]
    
    luma_in  = luma_orig.ravel()
    luma_out = luma_ref.ravel()
    
    # 逐亮度值统计（排除 JPEG 噪声区 0-19 和 246-255）
    avg_map = {}
    for i in range(len(luma_in)):
        k = int(luma_in[i])
        if 20 <= k <= 245:
            if k not in avg_map:
                avg_map[k] = []
            avg_map[k].append(luma_out[i])
    
    # 取平均（样本量 > 20 才纳入）
    curve_x, curve_y = [], []
    for k in sorted(avg_map.keys()):
        if len(avg_map[k]) > 20:
            curve_x.append(k)
            curve_y.append(np.mean(avg_map[k]))
    
    curve_x = np.array(curve_x)
    curve_y = np.array(curve_y)
    
    # ── 传输曲线图 ──
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    
    # 左：传输曲线
    axes[0].plot([0, 255], [0, 255], 'k--', alpha=0.3, label='identity')
    axes[0].plot(curve_x, curve_y, 'b-', linewidth=2, label=label)
    axes[0].set_xlabel('Input luminance')
    axes[0].set_ylabel('Output luminance')
    axes[0].set_title(f'传输曲线: {label}')
    axes[0].legend()
    axes[0].set_xlim(0, 255)
    axes[0].set_ylim(0, 255)
    axes[0].set_aspect('equal')
    axes[0].grid(True, alpha=0.3)
    
    # 右：ratio 曲线
    ratio = curve_y / np.maximum(curve_x, 1)
    axes[1].plot(curve_x, ratio, 'r-', linewidth=2)
    axes[1].axhline(y=1.0, color='k', linestyle='--', alpha=0.3)
    axes[1].set_xlabel('Input luminance')
    axes[1].set_ylabel('Output / Input ratio')
    axes[1].set_title(f'Ratio 曲线: {label}')
    axes[1].set_xlim(0, 255)
    axes[1].grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/transfer_{label}.png', dpi=100)
    plt.close()
    
    # 打印关键点
    print(f"\n传输曲线关键点 ({label}):")
    for target in [25, 50, 75, 100, 128, 150, 175, 200, 220, 240]:
        idx = np.argmin(np.abs(curve_x - target))
        if abs(curve_x[idx] - target) <= 3:
            r = curve_y[idx] / max(curve_x[idx], 1)
            print(f"  input {curve_x[idx]:>3.0f} → output {curve_y[idx]:>6.1f}  ratio={r:.3f}")
    
    return curve_x, curve_y
```

### Step 2.5: Per-channel 传输曲线诊断

对极值（±100）提取 R/G/B 各通道独立传输曲线，判断效果的颜色空间行为：

```python
def extract_per_channel_curves(orig, ref):
    """提取 R/G/B 独立传输曲线"""
    results = {}
    for ch, name in enumerate(['R', 'G', 'B']):
        avg_map = {}
        o = orig[:,:,ch].ravel(); r = ref[:,:,ch].ravel()
        for i in range(len(o)):
            k = int(o[i])
            if 5 <= k <= 250:
                if k not in avg_map: avg_map[k] = []
                avg_map[k].append(r[i])
        cx = [k for k in sorted(avg_map) if len(avg_map[k]) >= 20]
        cy = [np.mean(avg_map[k]) for k in cx]
        results[name] = (np.array(cx), np.array(cy))
    return results
```

**判断决策表：**

| R/G/B 曲线关系 | 判定 | Shader 实现方式 |
|---------------|------|----------------|
| 三通道完全一致 | 纯亮度操作 | 亮度空间（compute luma → apply → scale RGB by ratio） |
| 三通道形状相同但 k/pivot 不同 | RGB 空间逐通道 | 同一模型逐通道独立应用 |
| 三通道差异大且散点大 | 可能在 Lab/其他空间 | 需测试多种颜色空间方案 |

**教训（对比度）：**
- 假设1"Lightroom 在亮度空间操作" → 亮度比例法 B 通道 MSE=1200，❌
- 假设2"在 Lab L 通道操作" → Lab 重建 MSE=510，比 sRGB 还差，❌
- 实际最优：sRGB 逐通道独立应用同一曲线（MSE=70 单图 / 52 跨场景）
- **不要猜颜色空间，用数据验证**

### Step 3: 候选模型设计

**不要凑模型。** 基于 Step 1 的定性判断和 Step 2 的传输曲线形状，从已知图像处理算法库中选取候选：

| 曲线特征 | 候选模型 | 参数 |
|---------|---------|------|
| 恒定 ratio | 线性增益 `y = k*x` | k |
| 递减 ratio（亮→压缩） | Extended Reinhard `y*(1+y/w²)/(1+y)` | gain, white |
| 递增 ratio（暗→压缩） | Power law `A*pow(x,g)` | A, gamma |
| 递增 ratio + 暗部抬升 | Power + linear `A*pow(x,g)+B*x` | A, gamma, B |
| S 形（对比度类） | **CubicPivot** `y = x + k*x*(1-x)*(x-pivot)` | k, pivot |
| S 形（通用） | Bezier / NURBS 曲线 | 控制点 |
| 端点微调 | Headroom/floor 缩放 + mask | strength, mask 范围 |

**CubicPivot 特别推荐用于对比度/S 曲线类效果：**
- f(0)=0, f(1)=1 端点自动保留
- k=0 时精确 identity（零误差）
- k 与 slider 近乎完美线性关系
- pivot 控制 S 曲线交叉点（不对称支点）
- 单调性由 clamp 保证
- 对比度实测：5 个候选中全面胜出（MSE 0.07~1.79 亮度级别）

**线性空间 vs 显示空间**：如果参考软件在线性光空间处理（如 Lightroom 正向曝光），模型应包含 sRGB decode/encode roundtrip：
```
f(x) = pow( model(pow(x, 2.2) * gain), 1/2.2 )
```

### Step 4: 自动化拟合（scipy.optimize.curve_fit + 网格搜索）

优先使用 `scipy.optimize.curve_fit`（基于 Levenberg-Marquardt），比手写网格搜索更快更精确。网格搜索作为兜底（curve_fit 对初始值敏感时）。

```python
from scipy.optimize import curve_fit

def fit_models(curve_x, curve_y, label):
    """对传输曲线自动拟合多个候选模型"""
    x = curve_x / 255.0
    y = curve_y / 255.0
    
    results = []
    
    # ── 模型 1: 线性增益 y = k*x ──
    def linear(x, k): return k * x
    try:
        popt, _ = curve_fit(linear, x, y, p0=[1.0])
        pred = linear(x, *popt) * 255
        mse = np.mean((pred - curve_y)**2)
        results.append(('线性增益', mse, f'k={popt[0]:.4f}', lambda x, p=popt: linear(x, *p)))
    except: pass
    
    # ── 模型 2: A * pow(x, gamma) ──
    def power(x, A, g): return A * np.power(np.maximum(x, 1e-10), g)
    try:
        popt, _ = curve_fit(power, x, y, p0=[0.5, 1.5], bounds=([0, 0.5], [2, 5]))
        pred = power(x, *popt) * 255
        mse = np.mean((pred - curve_y)**2)
        results.append(('A*pow(x,g)', mse, f'A={popt[0]:.3f}, g={popt[1]:.3f}', lambda x, p=popt: power(x, *p)))
    except: pass
    
    # ── 模型 3: A * pow(x, g) + B * x ──
    def power_linear(x, A, g, B): return A * np.power(np.maximum(x, 1e-10), g) + B * x
    try:
        popt, _ = curve_fit(power_linear, x, y, p0=[0.3, 2.0, 0.1], bounds=([0, 1, 0], [1, 5, 1]))
        pred = power_linear(x, *popt) * 255
        mse = np.mean((pred - curve_y)**2)
        results.append(('A*pow(x,g)+B*x', mse, f'A={popt[0]:.3f}, g={popt[1]:.3f}, B={popt[2]:.3f}', lambda x, p=popt: power_linear(x, *p)))
    except: pass
    
    # ── 模型 4: Extended Reinhard（线性空间）──
    def ext_reinhard(x, gain, white):
        linear = np.power(np.maximum(x, 1e-10), 2.2)
        gained = linear * gain
        w2 = white * white
        mapped = gained * (1 + gained / w2) / (1 + gained)
        return np.power(np.clip(mapped, 0, 1), 1/2.2)
    try:
        popt, _ = curve_fit(ext_reinhard, x, y, p0=[5.0, 5.0], bounds=([1, 1], [100, 100]))
        pred = ext_reinhard(x, *popt) * 255
        mse = np.mean((pred - curve_y)**2)
        results.append(('ExtReinhard(线性)', mse, f'gain={popt[0]:.1f}, white={popt[1]:.1f}', lambda x, p=popt: ext_reinhard(x, *p)))
    except: pass
    
    # 排序输出
    results.sort(key=lambda r: r[1])
    print(f"\n{'='*60}")
    print(f"模型拟合排名: {label}")
    print(f"{'='*60}")
    for rank, (name, mse, params, _) in enumerate(results, 1):
        marker = ' ← 最佳' if rank == 1 else ''
        print(f"  {rank}. {name}: MSE={mse:.2f}, {params}{marker}")
    
    # 最佳模型逐点验证
    if results:
        best_name, best_mse, best_params, best_func = results[0]
        print(f"\n最佳模型逐点验证 ({best_name}):")
        for target in [25, 50, 100, 150, 200, 240]:
            idx = np.argmin(np.abs(curve_x - target))
            if abs(curve_x[idx] - target) <= 3:
                pred = best_func(curve_x[idx]/255) * 255
                actual = curve_y[idx]
                print(f"  input {curve_x[idx]:>3.0f}: actual={actual:.1f}, pred={pred:.1f}, diff={actual-pred:+.1f}")
    
    # 生成拟合对比图
    if results:
        fig, ax = plt.subplots(figsize=(10, 8))
        ax.plot([0, 255], [0, 255], 'k--', alpha=0.3, label='identity')
        ax.scatter(curve_x, curve_y, s=3, alpha=0.3, label='Lightroom 实测', zorder=5)
        plot_x = np.linspace(20, 245, 200) / 255
        for name, mse, params, func in results[:3]:  # 画前 3 名
            plot_y = func(plot_x) * 255
            ax.plot(plot_x * 255, plot_y, linewidth=2, label=f'{name} (MSE={mse:.1f})')
        ax.set_xlabel('Input'); ax.set_ylabel('Output')
        ax.set_title(f'模型拟合对比: {label}')
        ax.legend(); ax.grid(True, alpha=0.3)
        ax.set_xlim(0, 255); ax.set_ylim(0, 255)
        plt.tight_layout()
        plt.savefig(f'{output_dir}/fitting_{label}.png', dpi=100)
        plt.close()
    
    return results
```

### Step 5: 模型选择

**MSE 排名决定选择**，但需检查：

1. **查看拟合对比图**（`fitting_*.png`）：目视确认曲线形状是否合理
2. **逐点验证**：打印 10 个关键 input 值的 predicted vs actual，检查系统性偏差
3. **暗部/亮部分别检查**：MSE 可能被中间调主导，暗部误差被掩盖
4. **identity 连续性**：参数→0 时模型必须收敛到 `f(x)=x`
5. **单调性**：确认 `f(x)` 单调递增（亮的输入不能产生暗的输出）

### Step 5.5: 散点下限诊断 + 跨场景验证

#### 散点下限（Scatter Floor）

对每个 input level 计算 output 的 std，std² 就是该通道 MSE 的理论下限。模型 MSE 接近此值就不需要换更复杂的模型。

```python
def compute_scatter_floor(orig_ch, ref_ch):
    """计算 per-input-level 散点下限"""
    stds = {}
    for i in range(len(orig_ch.ravel())):
        k = int(orig_ch.ravel()[i])
        if 20 <= k <= 235:
            if k not in stds: stds[k] = []
            stds[k].append(ref_ch.ravel()[i])
    all_std = [np.std(stds[k]) for k in stds if len(stds[k]) >= 50]
    return np.mean(np.array(all_std)**2)  # MSE floor
```

**用途**：区分"模型不够好"和"数据精度的极限"。白色/黑色等微弱效果的信号可能接近 JPEG 量化噪声，scatter floor 会很高。

#### 跨场景验证 + 自适应参数检测

**必须步骤**（不是可选的）。用 2+ 个不同亮度/色彩分布的场景验证参数稳定性。

```python
# 对每个场景独立拟合，检查参数是否一致
for scene in scenes:
    popt = fit_model(scene)
    print(f"{scene.name}: k={popt[0]:.4f}, pivot={popt[1]:.4f}")

# 如果参数随场景变化（如 pivot 跨度 > 0.05），需要建模自适应关系：
# param = a * image_stat + b（image_stat 通常是 luma_mean）
from scipy.optimize import minimize
def adaptive_mse(params):
    a, b, c, d = params  # k = a*mean+b, pivot = c*mean+d
    total = 0
    for scene in scenes:
        k = a * scene.luma_mean + b
        p = c * scene.luma_mean + d
        for ref in [scene.pos, scene.neg]:
            pred = model(scene.orig, k, p)
            total += mse(pred, ref)
    return total
result = minimize(adaptive_mse, x0=[...])
```

**决策树：**

| 参数跨场景变化 | 判定 | 处理方式 |
|-------------|------|---------|
| 变化 < 5% | 固定参数 | 取均值 |
| 变化 > 5% 且与 luma_mean 线性相关 | 自适应参数 | `param = a*luma_mean + b`，CPU 端算 mean 传给 shader |
| 变化大且无明显规律 | 需要更多数据或更好模型 | 增加场景，或换模型形式 |

**教训（对比度）：**
- pivot 跨 3 场景从 0.456 到 0.592（跨度 0.136 = 27%）→ 必须自适应
- k 从 1.48 到 1.98（跨度 34%）→ 也需要自适应
- 单图 per-channel 过拟合的参数套到其他场景 MSE 翻倍 → 多场景联合优化是正确做法

### Step 6: 参数插值设计与验证

拟合得到的是极值（slider=±100）的参数。需要设计 slider 中间值的插值。

**如果有中间值参考图（推荐）**：
1. 对每个中间值（±25, ±50, ±75）分别提取传输曲线
2. 对每个中间值，用极值拟合的模型 + 线性插值参数，计算预测值
3. 比较预测值 vs 实际值的 MSE
4. 如果线性插值的中间值 MSE > 极值 MSE 的 2 倍，换非线性插值

```python
def verify_interpolation(orig_path, ref_paths_with_values, extreme_params, model_func, output_dir, label):
    """验证中间值的插值质量"""
    # ref_paths_with_values: [(slider_val, path), ...] 如 [(25, '曝光+25.jpg'), (50, '曝光+50.jpg')]
    # extreme_params: dict 极值参数 {'A': 0.270, 'gamma': 3.49, 'B': 0.130}
    # identity_params: dict identity 参数 {'A': 0, 'gamma': 1, 'B': 1}
    
    results = []
    for slider_val, ref_path in ref_paths_with_values:
        t = slider_val / 100.0  # 归一化到 [0, 1]
        
        # 线性插值参数
        interp_params = {}
        for key in extreme_params:
            identity_val = identity_params[key]
            extreme_val = extreme_params[key]
            interp_params[key] = identity_val + t * (extreme_val - identity_val)
        
        # 提取该 slider 值的实际传输曲线
        curve_x, curve_y = extract_transfer_curve(orig_path, ref_path, output_dir, f'{label}{slider_val}')
        
        # 用插值参数计算预测值
        pred = model_func(curve_x / 255, **interp_params) * 255
        mse = np.mean((pred - curve_y)**2)
        results.append((slider_val, mse))
        print(f"  slider={slider_val}: 插值 MSE={mse:.2f}")
    
    return results
```

**常见插值方式**：
```
// 线性插值（默认首选）
param = param_identity + t * (param_extreme - param_identity)

// 指数插值（适合增益类参数，如 A）
param = pow(param_extreme, t)

// 二次插值（如果中间值偏差大，用二次拟合 t→param 的关系）
param = a*t² + b*t + c
```

**必须验证**：
- slider=0 → 所有参数 = identity 值 → f(x) = x
- slider 从 0 缓慢增加 → 效果平滑渐入，无跳变
- 各中间值 MSE 不显著大于极值 MSE
- slider=±100 → 参数 = 拟合值 → 匹配参考图

### Step 7: Metal Shader 实现

将拟合公式写入 `.metal` 文件：

```metal
kernel void EffectFilter(
    texture2d<half, access::write> outputTexture [[texture(0)]],
    texture2d<half, access::read>  inputTexture  [[texture(1)]],
    constant float *paramPtr [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;

    const half4 original = inputTexture.read(gid);
    half3 color = original.rgb;

    const float param = clamp(*paramPtr, -1.0, 1.0);

    // 从 slider 计算拟合参数
    float absP = abs(param);
    float A = ...;      // 插值公式
    float gamma = ...;  // 插值公式

    for (int ch = 0; ch < 3; ch++) {
        float c = float(color[ch]);
        float result = ...; // 拟合模型
        color[ch] = half(clamp(result, 0.0, 1.0));
    }

    outputTexture.write(half4(color, original.a), gid);
}
```

**Shader 注释必须包含**：
- 拟合来源（哪个参考软件、哪张图）
- 候选模型数量和 MSE 排名
- 拟合参数值
- 逐点验证数据（至少 5 个 input→predicted vs actual）

### Step 8: 像素级回归验证

实现后，用原始分析脚本对 shader 输出做回归验证：
- 用 app 导出 shader 处理后的图
- 与参考图做像素级对比
- MSE 应接近拟合时的预测 MSE

## 常见陷阱

### 1. 不要拍脑袋设定参数
所有数值（mask 范围、strength 系数、gamma 值）必须来自数据拟合，不能凭直觉。"看起来差不多"不是依据。

### 2. 不要用 Lightroom RAW 管线处理 sRGB 数据
DNG SDK 的 exposure_ramp / exposure_tone / ACR3 是给线性 RAW 设计的。直接套在 gamma-encoded sRGB 上会导致：
- identity 跳变（ACR3 不是 identity 函数）
- 饱和度丢失（色彩空间假设不匹配）
正确做法：拟合参考软件对 JPEG 的实际输出，不是复制它的内部管线。

### 3. 先验证 identity 再验证效果
任何模型实现后的第一个测试：参数=0 时 output 是否 = input。如果不是，不要继续调效果。

### 4. 正负方向可能需要不同模型
正向曝光（增亮）和负向曝光（压暗）的最佳模型往往不同：
- 正向需要处理高光溢出（Reinhard / log compression）
- 负向需要处理暗部保留（power + linear lift）
分别拟合，不要强求对称。

### 5. 2 参数模型 MSE 有下限
如果最佳 2 参数模型的 MSE 仍然高（如 >8），尝试 3 参数模型（如 `A*pow(x,g)+B*x`）。额外参数通常用于捕捉暗部或亮部的局部偏差。

### 6. 频谱不变 = 纯色调操作
如果频谱分析显示原图和参考图的径向功率谱形状基本一致，说明这是纯色调操作（1D 传输曲线可拟合）。如果频谱形状显著改变，说明涉及空间操作，需要多 pass 方法（如 Local Laplacian），不能用简单曲线拟合。

### 7. 单图 per-channel 过拟合
对单张图片独立拟合 R/G/B 通道参数（如 per-channel k 和 pivot）可能 MSE 很低，但换一张图参数就不适用。原因是 per-channel 参数反映的是该图特有的颜色分布，不是算法的通用特征。
- 对比度实测：铁塔 per-channel MSE=70（好看），套到城堡/小桥 MSE=116（最差）
- 正确做法：多场景联合优化统一参数，或建模参数与图像统计量的关系

### 8. 正负方向可能需要不同应用模式
不仅模型参数可能不同（陷阱 4），应用方式也可能不同：
- 白色实测：正向 per-channel（MSE=54）vs luma-ratio（MSE=111）→ per-channel 好 2x
- 白色实测：负向 per-channel（MSE=89）vs luma-ratio（MSE=50）→ luma-ratio 好 1.8x
- 原因：负向压缩是亮度感知操作，正向提升是通道独立操作
- **不要假设一种应用模式适用于两个方向，用数据验证**

### 9. slider→参数不一定是线性关系
拟合得到 slider=±100 的参数后，中间值不一定是线性插值：
- 白色实测：linear interpolation 中间值 MSE=20，power interpolation (α=1.74) MSE=1.4
- 方法：独立拟合几个中间值的参数，画 slider→param 关系图
- 常见非线性：power law（`param = param_100 * pow(t, alpha)`），二次（`a*t² + b*t`）

### 10. 曲线形状跨场景变化时用 CPU LUT
当参数的线性自适应失败（如 k 与 mean 的关系是非单调的弧线）：
- 不要用二次公式（3 个点的二次插值在 LUT 范围外爆炸）
- 用 **CPU 端 piecewise linear LUT**（根据 lumaMean 查表插值 k, b）
- 边界 clamp 到最近 LUT 点
- 实测：LUT avg MSE=44 vs 线性自适应 MSE=346 vs 二次公式（范围外 k<0 崩溃）

### 11. 不要猜颜色空间，用数据验证
不要假设效果在某个颜色空间操作（Lab/HSL/线性 RGB 等）。用数据验证：
- 提取 per-channel 传输曲线（Step 2.5）
- 尝试多种颜色空间重建，比较 MSE
- 对比度实测："显然应该在 Lab L 操作" → 实际 Lab MSE=510 > sRGB per-channel MSE=70

## 成功案例

### 曝光负向

| 迭代 | 模型 | MSE | 问题 |
|------|------|-----|------|
| v1 | DNG SDK 分段二次 | — | 高光不动（f(1)=1），感觉像调黑色 |
| v2 | 显示空间线性增益 | 168.6 | ratio 恒定，缺对比度 |
| v3 | A*pow(x, gamma) | 10.53 | 暗部偏暗 3 倍 |
| **v4** | **A*pow(x,g)+B*x** | **2.82** | **全区间误差 < 3 levels** |

关键转折：加入 `B*x` 线性项后 MSE 从 10.53 降到 2.82，捕捉了 Lightroom ACR3 S 曲线的暗部抬升效果。

### 对比度

| 阶段 | 方案 | MSE | 教训 |
|------|------|-----|------|
| v1 | RawTherapee Bezier，固定 pivot=0.5 | 未量化 | 无像素级验证，支点错误 |
| v2 | 5 候选模型拟合（单图铁塔） | 1.79 (luma) | CubicPivot 全面胜出 |
| v3 | Per-channel k/pivot（单图） | 70 (RGB) | 看似精确但过拟合 |
| v4 | 跨 3 场景验证 → per-channel 崩溃 | 116 | 单图参数不可泛化 |
| **v5** | **自适应 k+pivot（3 场景联合优化）** | **52 (RGB)** | **k=f(mean), pivot=f(mean)** |

关键转折：从单图过拟合到多场景联合优化。自适应公式 `k = -0.356*mean + 2.289`、`pivot = 0.381*mean + 0.377` 在所有场景表现均匀。

### 白色

| 阶段 | 方案 | MSE | 教训 |
|------|------|-----|------|
| v1 | headroom 压缩 + smoothstep mask | 3945 (RGB) | ad-hoc，不基于像素数据 |
| v2 | 7 候选模型拟合，WeightedParab 胜出 | 1.02 (luma) | 单场景拟合好，但... |
| v3 | 跨 3 场景验证 → 曲线**形状**不同 | 55.8 (luma) | 共享形状+自适应振幅失败 |
| v4 | 1 参数自适应（线性 k=f(mean)） | 346 | 曲线形状变化太大，线性不够 |
| **v5** | **CPU LUT 自适应 (k,b) + power interpolation** | **44.1 (RGB)** | **90x 改善** |

关键发现：
1. **曲线形状随场景变化**，不只是振幅。固定形状+自适应振幅不够（MSE=55 vs LUT=44）
2. **正负方向最佳应用模式不同**：正向 per-channel、负向 luma-ratio
3. **slider→k 不是线性关系**，是 power law (α=1.74)。Linear MSE=20 → Power MSE=1.4（93% 改善）
4. **CPU LUT 插值** 是处理参数非线性跨场景变化的实用方案（仅 3 个 LUT 点）
5. 固定参数（joint optimized）avg MSE=746，LUT avg MSE=44 → 非线性自适应必须
