# Strix-Turbo Work Item Prioritization
## RICE, Kano, WSJF, Cost, and Cost of Delay Analysis

---

## Scoring Frameworks Explained

| Framework | Components | Scale |
|-----------|------------|-------|
| **RICE** | Reach × Impact × Confidence / Effort | Higher = Better |
| **Kano** | B=Basic, P=Performance, E=Excitement | E > P > B |
| **WSJF** | (Value + Criticality + Risk) / Size | Higher = Do First |
| **$** | Development Cost | 1=Low, 10=Very High |
| **CoD** | Cost of Delay (weekly value lost) | 1=Low, 10=Critical |

---

## Priority Tier 1: Do Immediately (Score 80+)

| # | Work Item | RICE | Kano | WSJF | $ | CoD | **Total** | Notes |
|---|-----------|------|------|------|---|-----|-----------|-------|
| 1 | **.wslconfig mirrored networking** | R:10 I:9 C:10 E:1 = **900** | B | 27/1=**27** | 1 | 9 | **96** | Already built, just apply |
| 2 | **Windows Defender exclusions** | R:10 I:7 C:10 E:1 = **700** | B | 21/1=**21** | 1 | 7 | **92** | 20-40% I/O gain instantly |
| 3 | **Git fsmonitor + config** | R:9 I:8 C:10 E:1 = **720** | P | 24/1=**24** | 1 | 8 | **94** | 5-10x git status speedup |
| 4 | **Parasitic Batching (LD_PRELOAD)** | R:8 I:9 C:8 E:2 = **288** | E | 24/2=**12** | 3 | 9 | **85** | 50-100x VM exit reduction |
| 5 | **I/O scheduler tuning** | R:10 I:5 C:10 E:1 = **500** | B | 15/1=**15** | 1 | 5 | **82** | Low effort, moderate gain |

### Tier 1 Summary
```
┌─────────────────────────────────────────────────────────────────────────┐
│ WEEK 1 ACTION ITEMS (Do Today)                                          │
├─────────────────────────────────────────────────────────────────────────┤
│ 1. Run install-strix-turbo.ps1 (applies items 1, 2, 3, 5)              │
│ 2. Build LD_PRELOAD batching library (item 4)                          │
│                                                                         │
│ Expected combined gain: 3-5x immediately                                │
│ Total cost: ~$500 (2 days dev time)                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Priority Tier 2: Do This Week (Score 60-79)

| # | Work Item | RICE | Kano | WSJF | $ | CoD | **Total** | Notes |
|---|-----------|------|------|------|---|-----|-----------|-------|
| 6 | **NVMe Passthrough Setup** | R:6 I:10 C:9 E:3 = **180** | E | 27/3=**9** | 4 | 10 | **79** | Eliminates VHDX forever |
| 7 | **NPU Bridge (Windows-side)** | R:5 I:8 C:7 E:4 = **70** | E | 21/4=**5** | 5 | 8 | **72** | Enables NPU from WSL2 |
| 8 | **Predictive Teleportation** | R:7 I:9 C:6 E:5 = **76** | E | 24/5=**5** | 6 | 9 | **74** | NPU prefetches /mnt/c |
| 9 | **Custom Zen 5 Kernel** | R:8 I:7 C:8 E:4 = **112** | P | 21/4=**5** | 5 | 7 | **70** | io_uring + AVX-512 |
| 10 | **Shared Memory IPC** | R:7 I:10 C:7 E:6 = **82** | E | 27/6=**5** | 7 | 10 | **68** | Replace 9p protocol |

### Tier 2 Summary
```
┌─────────────────────────────────────────────────────────────────────────┐
│ WEEK 2-3 ACTION ITEMS                                                   │
├─────────────────────────────────────────────────────────────────────────┤
│ 1. Set up NVMe passthrough partition (item 6)                          │
│ 2. Deploy NPU Bridge service (item 7)                                  │
│ 3. Build custom Zen 5 kernel (item 9)                                  │
│ 4. Start Shared Memory IPC implementation (item 10)                    │
│                                                                         │
│ Expected combined gain: 5-8x                                            │
│ Total cost: ~$3,000 (1-2 weeks dev time)                               │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Priority Tier 3: Do This Month (Score 40-59)

| # | Work Item | RICE | Kano | WSJF | $ | CoD | **Total** | Notes |
|---|-----------|------|------|------|---|-----|-----------|-------|
| 11 | **Inverse VHDX** | R:6 I:8 C:5 E:7 = **34** | E | 21/7=**3** | 7 | 8 | **58** | Requires VHDX driver mod |
| 12 | **Strix-FUSE filesystem** | R:6 I:9 C:6 E:7 = **46** | E | 24/7=**3** | 7 | 9 | **56** | High-perf /mnt/c |
| 13 | **AVX-512 SIMD paths** | R:4 I:6 C:9 E:3 = **72** | P | 18/3=**6** | 4 | 6 | **54** | 4-15x path parsing |
| 14 | **Plugin Architecture PRs** | R:10 I:6 C:5 E:6 = **50** | P | 18/6=**3** | 6 | 6 | **52** | Upstream acceptance |
| 15 | **SPDK Integration** | R:3 I:10 C:5 E:8 = **19** | E | 27/8=**3** | 8 | 10 | **48** | User-space NVMe |

### Tier 3 Summary
```
┌─────────────────────────────────────────────────────────────────────────┐
│ MONTH 1 ACTION ITEMS                                                    │
├─────────────────────────────────────────────────────────────────────────┤
│ 1. Complete Strix-FUSE implementation (item 12)                        │
│ 2. Submit Plugin Architecture PR to microsoft/WSL (item 14)           │
│ 3. Integrate AVX-512 SIMD into plan9 client (item 13)                 │
│ 4. Prototype Inverse VHDX (item 11)                                    │
│                                                                         │
│ Expected combined gain: 8-12x                                           │
│ Total cost: ~$10,000 (3-4 weeks dev time)                              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Priority Tier 4: Do This Quarter (Score 20-39)

| # | Work Item | RICE | Kano | WSJF | $ | CoD | **Total** | Notes |
|---|-----------|------|------|------|---|-----|-----------|-------|
| 16 | **NPU-as-a-Service (VSP/VSC)** | R:3 I:9 C:4 E:9 = **12** | E | 24/9=**3** | 9 | 9 | **38** | Full NPU in WSL2 |
| 17 | **GPU Mode Switching** | R:4 I:10 C:3 E:10 = **12** | E | 27/10=**3** | 10 | 10 | **36** | SR-IOV dynamic |
| 18 | **ROCm gfx1151 PRs** | R:5 I:7 C:4 E:7 = **20** | P | 18/7=**3** | 7 | 7 | **34** | Upstream ROCm |
| 19 | **TheRock Build PRs** | R:6 I:5 C:6 E:5 = **36** | P | 15/5=**3** | 5 | 5 | **32** | ROCm build system |
| 20 | **Linux Kernel Patches** | R:10 I:5 C:3 E:8 = **19** | P | 15/8=**2** | 8 | 5 | **28** | LKML process |

### Tier 4 Summary
```
┌─────────────────────────────────────────────────────────────────────────┐
│ QUARTER 1 ACTION ITEMS                                                  │
├─────────────────────────────────────────────────────────────────────────┤
│ 1. Prototype NPU VSP/VSC driver (item 16)                              │
│ 2. Investigate SR-IOV GPU switching (item 17)                          │
│ 3. Submit ROCm PRs for gfx1151 (item 18)                              │
│ 4. Contribute to TheRock build (item 19)                               │
│                                                                         │
│ Expected combined gain: 10-20x                                          │
│ Total cost: ~$30,000 (2-3 months dev time)                             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Priority Tier 5: Strategic / Long-term (Score <20)

| # | Work Item | RICE | Kano | WSJF | $ | CoD | **Total** | Notes |
|---|-----------|------|------|------|---|-----|-----------|-------|
| 21 | **dxgkrnl improvements** | R:10 I:8 C:1 E:10 = **8** | P | 24/10=**2** | 10 | 8 | **18** | Microsoft internal |
| 22 | **GPU-PV protocol changes** | R:10 I:10 C:1 E:10 = **10** | P | 30/10=**3** | 10 | 10 | **16** | Closed source |
| 23 | **NPU WSL2 native driver** | R:5 I:10 C:1 E:10 = **5** | E | 27/10=**3** | 10 | 10 | **12** | Architecture blocker |

### Tier 5 Summary
```
┌─────────────────────────────────────────────────────────────────────────┐
│ STRATEGIC ITEMS (Advocacy Required)                                     │
├─────────────────────────────────────────────────────────────────────────┤
│ These require Microsoft/AMD internal work. Our role:                   │
│ 1. File feature requests with detailed justification                   │
│ 2. Demonstrate demand through community engagement                     │
│ 3. Provide workarounds that prove the value                            │
│ 4. Engage with product teams at conferences                            │
│                                                                         │
│ Timeline: 6-24 months (depends on vendor priorities)                   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Master Prioritization Matrix

| Rank | Item | RICE | Kano | WSJF | $ | CoD | Score | ROI |
|------|------|------|------|------|---|-----|-------|-----|
| **1** | .wslconfig mirrored | 900 | B | 27 | 1 | 9 | **96** | ∞ |
| **2** | Git fsmonitor | 720 | P | 24 | 1 | 8 | **94** | ∞ |
| **3** | Defender exclusions | 700 | B | 21 | 1 | 7 | **92** | ∞ |
| **4** | Parasitic Batching | 288 | E | 12 | 3 | 9 | **85** | 28x |
| **5** | I/O scheduler | 500 | B | 15 | 1 | 5 | **82** | 82x |
| **6** | NVMe Passthrough | 180 | E | 9 | 4 | 10 | **79** | 20x |
| **7** | Predictive Teleport | 76 | E | 5 | 6 | 9 | **74** | 12x |
| **8** | NPU Bridge | 70 | E | 5 | 5 | 8 | **72** | 14x |
| **9** | Zen 5 Kernel | 112 | P | 5 | 5 | 7 | **70** | 14x |
| **10** | Shared Memory IPC | 82 | E | 5 | 7 | 10 | **68** | 10x |
| **11** | Inverse VHDX | 34 | E | 3 | 7 | 8 | **58** | 8x |
| **12** | Strix-FUSE | 46 | E | 3 | 7 | 9 | **56** | 8x |
| **13** | AVX-512 SIMD | 72 | P | 6 | 4 | 6 | **54** | 14x |
| **14** | Plugin PRs | 50 | P | 3 | 6 | 6 | **52** | 9x |
| **15** | SPDK | 19 | E | 3 | 8 | 10 | **48** | 6x |
| **16** | NPU VSP/VSC | 12 | E | 3 | 9 | 9 | **38** | 4x |
| **17** | GPU Mode Switch | 12 | E | 3 | 10 | 10 | **36** | 4x |
| **18** | ROCm PRs | 20 | P | 3 | 7 | 7 | **34** | 5x |
| **19** | TheRock PRs | 36 | P | 3 | 5 | 5 | **32** | 6x |
| **20** | Kernel Patches | 19 | P | 2 | 8 | 5 | **28** | 4x |

---

## Cost Breakdown ($)

| Category | Items | Est. Cost | Est. Time |
|----------|-------|-----------|-----------|
| **Tier 1** | Config changes | $0 | 1 hour |
| **Tier 1** | Parasitic Batching | $500 | 2 days |
| **Tier 2** | NVMe + NPU + Kernel | $3,000 | 2 weeks |
| **Tier 3** | FUSE + IPC + PRs | $10,000 | 1 month |
| **Tier 4** | VSP/VSC + SR-IOV | $30,000 | 3 months |
| **Total** | All items | **~$45,000** | **~4 months** |

---

## Cost of Delay Analysis

| Item | Weekly Value Lost | 3-Month CoD | Priority |
|------|-------------------|-------------|----------|
| NVMe Passthrough | $200/wk (time) | $2,600 | **High** |
| Shared Memory IPC | $300/wk (time) | $3,900 | **High** |
| GPU Mode Switch | $400/wk (perf) | $5,200 | **Critical** |
| NPU Access | $250/wk (capability) | $3,250 | **High** |
| VHDX Management | $100/wk (time) | $1,300 | **Medium** |

---

## Kano Model Visualization

```
SATISFACTION
     ▲
     │                              ★ GPU Mode Switch
     │                           ★ NPU-as-a-Service
     │                        ★ Predictive Teleport
     │                     ★ Inverse VHDX
     │                  ★ SPDK Integration
     │               ★ Shared Memory IPC          EXCITEMENT
     │            ★ NVMe Passthrough              (Delighters)
     │         ★ Parasitic Batching
     │
     │    ────────────────────────────────────────────────────
     │                                              PERFORMANCE
     │         ★ Zen 5 Kernel                      (Satisfiers)
     │      ★ AVX-512 SIMD
     │   ★ Plugin PRs
     │
─────┼────────────────────────────────────────────────────────► FUNCTIONALITY
     │
     │   ★ Git fsmonitor        BASIC
     │★ .wslconfig              (Must-haves)
     │★ Defender exclusions
     │★ I/O scheduler
     │
     ▼
DISSATISFACTION
```

---

## WSJF Calculation Details

```
WSJF = (Business Value + Time Criticality + Risk Reduction/Opportunity) / Job Size

Scale: 1-10 for each component

Example: Parasitic Batching
├── Business Value:     9  (major performance gain)
├── Time Criticality:   7  (delays hurt daily productivity)
├── Risk Reduction:     8  (proves io_uring approach works)
├── Job Size:          2  (LD_PRELOAD is well-understood)
└── WSJF = (9+7+8)/2 = 12
```

---

## Recommended Execution Order

```
WEEK 1:  ████████████████████████████████████████████ Tier 1 (Config)
WEEK 2:  ████████████████████████████████░░░░░░░░░░░░ Tier 1 (Batching)
WEEK 3:  ████████████████████████████░░░░░░░░░░░░░░░░ Tier 2 (NVMe)
WEEK 4:  ████████████████████████░░░░░░░░░░░░░░░░░░░░ Tier 2 (NPU Bridge)
WEEK 5:  ████████████████████░░░░░░░░░░░░░░░░░░░░░░░░ Tier 2 (Kernel)
WEEK 6:  ████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ Tier 2 (IPC start)
WEEK 7:  ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ Tier 3 (FUSE)
WEEK 8:  ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ Tier 3 (PRs)
...
MONTH 3: ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ Tier 4 (Advanced)

Progress bar = Cumulative performance gain toward 10x
```

---

## Summary: Top 5 Actions This Week

| Priority | Action | Time | Gain | Cost |
|----------|--------|------|------|------|
| **#1** | Run `install-strix-turbo.ps1` | 10 min | 2-3x | $0 |
| **#2** | Set up NVMe passthrough | 30 min | +50% I/O | $0 |
| **#3** | Build LD_PRELOAD batcher | 2 days | +100% syscall | $500 |
| **#4** | Start NPU Bridge service | 1 day | NPU access | $250 |
| **#5** | Build Zen 5 kernel | 1 day | +20% overall | $250 |

**Week 1 Target: 3-5x improvement for ~$1,000 investment**

---

*Prioritization complete. Execute Tier 1 immediately.*
