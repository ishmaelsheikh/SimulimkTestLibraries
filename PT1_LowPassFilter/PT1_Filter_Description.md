# PT1 Filter (Forward Euler) – Block Description

| Item       | Value                                   |
|------------|-----------------------------------------|
| Model      | `PT1_Filter_Demo.slx` → `PT1_Filter`    |
| Version    | `<x.y>`                                 |
| Author     | `<name>`                                |
| Date       | `<yyyy-mm-dd>`                          |

## 1. Purpose
Discrete 1st-order low-pass filter (PT1) that smooths a noisy signal with an adjustable filter time.

## 2. Interface

| Port / Param | Type   | Unit | Description                                              |
|--------------|--------|------|----------------------------------------------------------|
| `u`   (In1)  | double | `<>` | Signal to be filtered                                    |
| `reset` (In2)| double/boolean | – | `≠ 0` → output set to input (`y = u`)           |
| `T_filt` (In3)| double | s   | Filter time constant                                     |
| `y`   (Out1) | double | `<>` | Filtered signal                                          |
| `Ts`  (mask) | double | s    | Task time (sample time), must be > 0                     |
| `y0`  (mask) | double | `<>` | Initial output                                           |

## 3. Algorithm
Continuous model: `T · dy/dt + y = u`

Forward Euler discretisation, executed every task `k`:

```
K    = Ts / max(T_filt, Ts)
y[k] = (u[k] − y[k−1]) · K + y[k−1]      if reset = 0
y[k] = u[k]                              if reset ≠ 0
```

## 4. Protection

| Condition          | Behaviour                      |
|--------------------|--------------------------------|
| `T_filt < Ts`      | `K = 1` → pass-through (`y = u`) |
| `T_filt = 0`       | `K = 1` → no division by zero  |
| `T_filt < 0`       | `K = 1` → pass-through         |

`K` is limited to `0 < K ≤ 1`, so the filter can't overshoot or become unstable (pole `z = 1 − K` lies in [0, 1)).

## 5. Characteristics
- Step response reaches ≈ 63 % after `T_filt`, ≈ 99 % after `5 · T_filt`
- Cut-off frequency: `f_c ≈ 1 / (2π · T_filt)`
- Accuracy: forward Euler responds slightly faster than the ideal PT1; the error is ≈ 1 % at `T_filt/Ts = 100` and ≈ 5 % at `T_filt/Ts = 10`
- Recommended: `T_filt ≥ 10 · Ts`

## 6. Reset and Initialisation
- At start: `y[−1] = y0`
- `reset ≠ 0`: output follows the input directly; filtering restarts from the current input value when reset is released (no transient)

## 7. Verification
| Test                                  | Result     |
|---------------------------------------|------------|
| Model vs. formula, sample by sample   | `<error 0>`|
| Output after `T_filt` (ideal 0.632)   | `<0.6376>` |
| `T_filt = 0`, `< Ts`, `< 0`           | `<y = u>`  |
| Reset active                          | `<y = u>`  |

## 8. Limitations / Notes
- `<add project-specific notes, e.g. data type, fixed-point scaling, code-generation settings>`
