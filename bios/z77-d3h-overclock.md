# Разгон GA-Z77-D3H + i7-3770K + 4 планки DDR3-1866

Настройки, на которых машина из статьи живёт после прошивки F22 с модулем NVMe. Файлом профиля BIOS не делюсь сознательно: профиль Gigabyte привязан к версии прошивки, и профиль от F18, загруженный в F22, у меня отключил USB в BIOS. Вбивайте руками.

Железо: Core i7-3770K, память 2×4 ГБ Corsair Vengeance CMZ8GX3M2A1866C9 (1866 CL9) + 2×8 ГБ Kingston HyperX KHX1866C10D3/8G (1866 CL10), воздушный кулер. Стабильность: 60 минут Prime95 torture test на 8 потоках без ошибок, WHEA 0. Ваш процессор и ваша память могут не повторить.

## M.I.T. → Advanced Frequency Settings
- CPU Clock Ratio: **44** (4,4 ГГц)
- System Memory Multiplier: **18.66** (1866 МГц)

## M.I.T. → Advanced Frequency Settings → Advanced CPU Core Features
- Turbo Ratio 1/2/3/4-Core Active: **44** все четыре
- Turbo Power Limit (Watts): **200**
- Core Current Limit (Amps): **200**
- C3/C6 State Support: **Disabled**
- CPU EIST Function: **Disabled**
- Остальное: Auto / Enabled по умолчанию

## M.I.T. → Advanced Memory Settings
- Performance Enhance: **Turbo**
- DRAM Timing Selectable: **Expert**
- Channel A и Channel B Timing Settings: CAS **10**, tRCD **10**, tRP **10**, tRAS **30**, остальное Auto

Тайминги взяты по самой медленной планке (Kingston CL10). На таймингах Corsair (9-9-9-24) смешанный комплект не стартует.

## M.I.T. → Advanced Voltage Settings
- 3D Power Control: Vcore Loadline Calibration **High**, Vcore Current Protection **High**
- CPU Core Voltage Control: CPU Vcore **1.330 V**, CPU PLL **1.700 V**, остальное Auto
- DRAM Voltage Control: DRAM Voltage **1.580 V** (с 1,560 память после полного сброса питания переставала проходить тренировку)

## Не забыть после сброса настроек
- Peripherals → SATA Mode: **AHCI**
- BIOS Features → Boot Option #1: **UEFI: Hard Drive** (так называется UEFI-загрузчик NVMe), `PATA SS:` → Disabled
