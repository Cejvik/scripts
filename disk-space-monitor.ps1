[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Initialize', 'Report')]
    [string] $Action,

    [string[]] $Roots = @('C:\'),
    [int] $Depth = 2,
    [string] $StateDirectory = "$PSScriptRoot\disk-monitor-state",
    [string] $OutputCsv = "$PSScriptRoot\disk-growth-report.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-UsnReaderType {
    if ('UsnReader' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class UsnChange {
    public long Usn { get; set; }
    public string Path { get; set; }
    public uint Reason { get; set; }
}

public static class UsnReader {
    const uint FSCTL_QUERY_USN_JOURNAL = 0x000900f4;
    const uint FSCTL_READ_USN_JOURNAL = 0x000900bb;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, FILE_SHARE_DELETE = 4;
    const uint OPEN_EXISTING = 3, FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

    [StructLayout(LayoutKind.Sequential)] public struct JournalData {
        public long UsnJournalId, FirstUsn, NextUsn, LowestValidUsn, MaxUsn;
        public long MaximumSize, AllocationDelta;
    }
    [StructLayout(LayoutKind.Sequential)] struct ReadData {
        public long StartUsn;
        public uint ReasonMask, ReturnOnlyOnClose, Timeout, BytesToWaitFor;
        public long UsnJournalId;
    }
    [StructLayout(LayoutKind.Sequential)] struct FileIdDescriptor {
        public uint Size;
        public byte Type;
        public byte A, B, C;
        public ulong FileId;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr device, uint code, IntPtr input, uint inputSize,
        IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenFileById(IntPtr volume, ref FileIdDescriptor id, uint access,
        uint share, IntPtr security, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(IntPtr handle, StringBuilder path, uint length, uint flags);

    static IntPtr OpenVolume(string drive) {
        return CreateFile("\\\\.\\" + drive.TrimEnd('\\'), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }
    public static JournalData GetJournal(string drive) {
        IntPtr volume = OpenVolume(drive); if (volume == new IntPtr(-1)) throw new Win32Exception();
        try {
            int size = Marshal.SizeOf(typeof(JournalData)); IntPtr p = Marshal.AllocHGlobal(size);
            try { uint got; if (!DeviceIoControl(volume, FSCTL_QUERY_USN_JOURNAL, IntPtr.Zero, 0, p, (uint)size, out got, IntPtr.Zero)) throw new Win32Exception(); return (JournalData)Marshal.PtrToStructure(p, typeof(JournalData)); }
            finally { Marshal.FreeHGlobal(p); }
        } finally { CloseHandle(volume); }
    }
    static string ResolvePath(IntPtr volume, ulong fileId) {
        FileIdDescriptor id = new FileIdDescriptor { Size = (uint)Marshal.SizeOf(typeof(FileIdDescriptor)), Type = 0, FileId = fileId };
        IntPtr file = OpenFileById(volume, ref id, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, FILE_FLAG_BACKUP_SEMANTICS);
        if (file == new IntPtr(-1)) return null;
        try { var sb = new StringBuilder(32768); uint n = GetFinalPathNameByHandle(file, sb, (uint)sb.Capacity, 0); if (n == 0) return null; string path = sb.ToString(); return path.StartsWith(@"\\?\") ? path.Substring(4) : path; }
        finally { CloseHandle(file); }
    }
    public static List<UsnChange> Read(string drive, long startUsn, long journalId) {
        IntPtr volume = OpenVolume(drive); if (volume == new IntPtr(-1)) throw new Win32Exception();
        var result = new List<UsnChange>(); long cursor = startUsn;
        try {
            int inputSize = Marshal.SizeOf(typeof(ReadData)); IntPtr input = Marshal.AllocHGlobal(inputSize); byte[] buffer = new byte[1024 * 1024];
            try {
                while (true) {
                    var request = new ReadData { StartUsn = cursor, ReasonMask = 0xffffffff, UsnJournalId = journalId };
                    Marshal.StructureToPtr(request, input, false); uint got;
                    IntPtr output = Marshal.AllocHGlobal(buffer.Length);
                    try {
                        if (!DeviceIoControl(volume, FSCTL_READ_USN_JOURNAL, input, (uint)inputSize, output, (uint)buffer.Length, out got, IntPtr.Zero)) {
                            int error = Marshal.GetLastWin32Error(); if (error == 38) break; throw new Win32Exception(error);
                        }
                        if (got <= 8) break; Marshal.Copy(output, buffer, 0, (int)got);
                        int offset = 8;
                        while (offset + 60 <= got) {
                            int length = BitConverter.ToInt32(buffer, offset); if (length < 60 || offset + length > got) break;
                            long usn = BitConverter.ToInt64(buffer, offset + 24); ulong fileId = BitConverter.ToUInt64(buffer, offset + 8);
                            uint reason = BitConverter.ToUInt32(buffer, offset + 40); ushort nameLength = BitConverter.ToUInt16(buffer, offset + 56); ushort nameOffset = BitConverter.ToUInt16(buffer, offset + 58);
                            string path = ResolvePath(volume, fileId); if (path != null) result.Add(new UsnChange { Usn = usn, Path = path, Reason = reason });
                            cursor = Math.Max(cursor, usn); offset += length;
                        }
                        cursor = BitConverter.ToInt64(buffer, 0); if (cursor <= startUsn) break;
                    } finally { Marshal.FreeHGlobal(output); }
                }
            } finally { Marshal.FreeHGlobal(input); }
        } finally { CloseHandle(volume); }
        return result;
    }
}
'@
}

function Get-VolumeForPath([string] $Path) {
    return ([System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).Path)).TrimEnd('\')
}

function Get-TrackedDirectories([string[]] $RootPaths, [int] $MaxDepth) {
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $RootPaths) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved.Length -gt 3) { $resolved = $resolved.TrimEnd('\') }
        $result.Add($resolved)
        if ($MaxDepth -gt 0) {
            Get-ChildItem -LiteralPath $resolved -Directory -Force -Recurse -ErrorAction SilentlyContinue |
                Where-Object { (($_.FullName.Substring($resolved.Length).Trim('\') -split '\\').Count) -le $MaxDepth } |
                ForEach-Object { $result.Add($_.FullName.TrimEnd('\')) }
        }
    }
    return $result | Sort-Object -Unique
}

function Get-DirectoryBytes([string] $Path) {
    $sum = [int64]0
    Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { $sum += $_.Length }
    return $sum
}

function Get-JournalState([string] $Drive) {
    Add-UsnReaderType
    $j = [UsnReader]::GetJournal($Drive)
    [pscustomobject]@{ Drive = $Drive; JournalId = $j.UsnJournalId; NextUsn = $j.NextUsn }
}

New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$snapshotPath = Join-Path $StateDirectory 'snapshot.csv'
$checkpointPath = Join-Path $StateDirectory 'checkpoint.json'

if ($Action -eq 'Initialize') {
    $directories = Get-TrackedDirectories $Roots $Depth
    $rows = foreach ($dir in $directories) {
        Write-Progress -Activity 'Skenuji adresáře' -Status $dir
        [pscustomobject]@{ Path = $dir; Bytes = Get-DirectoryBytes $dir; CapturedAt = (Get-Date).ToUniversalTime().ToString('o') }
    }
    $rows | Export-Csv -LiteralPath $snapshotPath -NoTypeInformation -Encoding UTF8
    $drives = $Roots | ForEach-Object { Get-VolumeForPath $_ } | Sort-Object -Unique
    $journals = foreach ($drive in $drives) { Get-JournalState $drive }
    [pscustomobject]@{ CreatedAt = (Get-Date).ToUniversalTime().ToString('o'); Depth = $Depth; Roots = $Roots; Journals = @($journals) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
    Write-Host "Hotovo: $($rows.Count) adresářů, snapshot $snapshotPath"
    exit 0
}

if (!(Test-Path -LiteralPath $snapshotPath) -or !(Test-Path -LiteralPath $checkpointPath)) { throw "Nejprve spusťte Initialize." }
$checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
$oldRows = Import-Csv -LiteralPath $snapshotPath
$tracked = @($oldRows | ForEach-Object { $_.Path })
$changes = foreach ($j in @($checkpoint.Journals)) {
    $current = Get-JournalState $j.Drive
    if ($current.JournalId -ne [int64]$j.JournalId -or $current.NextUsn -lt [int64]$j.NextUsn) { throw "USN Journal na $($j.Drive) byl resetován nebo přetečen; spusťte znovu Initialize." }
    Add-UsnReaderType
    [UsnReader]::Read($j.Drive, [int64]$j.NextUsn, [int64]$j.JournalId)
}
$affected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($change in $changes) {
    foreach ($dir in $tracked) {
        if ($change.Path.Equals($dir, [StringComparison]::OrdinalIgnoreCase) -or $change.Path.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) { [void]$affected.Add($dir) }
    }
}
$report = foreach ($dir in $affected) {
    $old = $oldRows | Where-Object Path -eq $dir | Select-Object -First 1
    $newBytes = Get-DirectoryBytes $dir
    [pscustomobject]@{ Path = $dir; OldGB = [math]::Round(([int64]$old.Bytes / 1GB), 3); NewGB = [math]::Round(($newBytes / 1GB), 3); GrowthGB = [math]::Round((($newBytes - [int64]$old.Bytes) / 1GB), 3); GrowthBytes = $newBytes - [int64]$old.Bytes; MeasuredAt = (Get-Date).ToUniversalTime().ToString('o') }
}
$report | Sort-Object GrowthBytes -Descending | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
$report | Select-Object Path,OldGB,NewGB,GrowthGB | Format-Table -AutoSize
Write-Host "Změněných USN záznamů: $(@($changes).Count); report: $OutputCsv"
