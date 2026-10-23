# Monitor růstu adresářů ve Windows

Skript [disk-space-monitor.ps1](./disk-space-monitor.ps1) používá počáteční CSV snapshot a USN Journal. Při týdenním reportu nepřepočítává všechny sledované adresáře, ale pouze adresáře, pod kterými USN Journal hlásí změnu.

## Použití

PowerShell spusťte jako správce:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\disk-space-monitor.ps1 -Action Initialize -Roots C:\Users,C:\Data -Depth 2
```

Po týdnu:

```powershell
.\disk-space-monitor.ps1 -Action Report -StateDirectory .\disk-monitor-state -OutputCsv .\disk-growth-report.csv
```

`Depth 2` znamená kořen, jeho přímé podadresáře a podadresáře druhé úrovně. Report je seřazený podle `GrowthGB` sestupně. Pokud je journal resetovaný nebo záznamy už nejsou dostupné, skript skončí s požadavkem na nový `Initialize`, aby nevznikl neúplný report.

## Ostatní utilitární nástroje

### plmaker.cmd
Create M3U play list from MP3 files in work directory

### mikrotik_wg.cmd
Create news peers on mikrotik and config files for clients devices
