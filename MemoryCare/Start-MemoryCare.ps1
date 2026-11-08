$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'MemoryCare 只能在 Windows 上运行。'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -ErrorAction Stop
        exit 0
    }
    catch {
        [void][System.Windows.MessageBox]::Show(
            "MemoryCare 需要管理员权限才能尝试处理所有进程。`n`n$($_.Exception.Message)",
            'MemoryCare',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning)
        exit 1
    }
}

if (-not ('MemoryCare.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace MemoryCare
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    public static class Native
    {
        private const uint PROCESS_SET_QUOTA = 0x0100;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("psapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EmptyWorkingSet(IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buffer);

        public static bool TryTrimWorkingSet(int processId, out int error)
        {
            IntPtr process = OpenProcess(
                PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION,
                false,
                processId);

            if (process == IntPtr.Zero)
            {
                error = Marshal.GetLastWin32Error();
                return false;
            }

            try
            {
                bool result = EmptyWorkingSet(process);
                error = result ? 0 : Marshal.GetLastWin32Error();
                return result;
            }
            finally
            {
                CloseHandle(process);
            }
        }
    }
}
'@
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MemoryCare - 温和释放内存"
        Width="680" Height="520" MinWidth="600" MinHeight="480"
        WindowStartupLocation="CenterScreen" Background="#F4F7FB"
        FontFamily="Microsoft YaHei UI">
    <Grid Margin="28">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0">
            <TextBlock Text="MemoryCare" FontSize="30" FontWeight="SemiBold" Foreground="#172B4D"/>
            <TextBlock Text="温和释放内存，不会关闭任何程序" Margin="0,7,0,0" FontSize="15" Foreground="#526581"/>
        </StackPanel>

        <Border Grid.Row="1" Margin="0,24,0,0" Padding="22" Background="White"
                CornerRadius="12" BorderBrush="#E1E8F0" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="使用中内存" FontSize="14" Foreground="#65758B"/>
                    <TextBlock x:Name="InUseText" Text="读取中…" Margin="0,7,0,0"
                               FontSize="28" FontWeight="SemiBold" Foreground="#146C5A"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="18,0,0,0">
                    <TextBlock Text="使用率" FontSize="14" Foreground="#65758B"/>
                    <TextBlock x:Name="LoadText" Text="—" Margin="0,7,0,0"
                               FontSize="28" FontWeight="SemiBold" Foreground="#172B4D"/>
                </StackPanel>
            </Grid>
        </Border>

        <StackPanel Grid.Row="2" Margin="0,22,0,0">
            <Button x:Name="CleanButton" Content="温和释放内存" Height="54"
                    FontSize="17" FontWeight="SemiBold" Foreground="White"
                    Background="#177A66" BorderThickness="0" Cursor="Hand"/>
            <TextBlock x:Name="StatusText" Margin="0,18,0,0" TextWrapping="Wrap"
                       FontSize="14" Foreground="#40516A"/>
        </StackPanel>

        <TextBlock Grid.Row="3" Margin="0,18,0,0" TextWrapping="Wrap"
                   FontSize="12" Foreground="#718096"
                   Text="管理员模式下尝试修剪所有进程的工作集；受保护进程可能无法处理。Windows 可能重新载入数据，且不会关闭任何程序。"/>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$inUseText = $window.FindName('InUseText')
$loadText = $window.FindName('LoadText')
$statusText = $window.FindName('StatusText')
$cleanButton = $window.FindName('CleanButton')

function Get-MemorySnapshot {
    $memory = New-Object MemoryCare.MEMORYSTATUSEX
    $memory.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][MemoryCare.MEMORYSTATUSEX])

    if (-not [MemoryCare.Native]::GlobalMemoryStatusEx([ref]$memory)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "读取系统内存状态失败（Windows 错误 $code）。"
    }

    [pscustomobject]@{
        Total = [uint64]$memory.ullTotalPhys
        InUse = [uint64]($memory.ullTotalPhys - $memory.ullAvailPhys)
        Load = [uint32][Math]::Round((($memory.ullTotalPhys - $memory.ullAvailPhys) * 100.0) / $memory.ullTotalPhys)
    }
}

function Update-MemoryDisplay {
    $snapshot = Get-MemorySnapshot
    $inUseText.Text = '{0:N2} GB / {1:N2} GB' -f ($snapshot.InUse / 1GB), ($snapshot.Total / 1GB)
    $loadText.Text = '{0}%' -f $snapshot.Load
    return $snapshot
}

$cleanButton.Add_Click({
    $cleanButton.IsEnabled = $false
    $statusText.Text = '正在尝试优化所有进程的工作集…'

    try {
        $before = Update-MemoryDisplay
        $examined = 0
        $trimmed = 0
        $skipped = 0
        $failed = 0

        foreach ($process in [Diagnostics.Process]::GetProcesses()) {
            try {
                $examined++
                $nativeError = 0
                if ([MemoryCare.Native]::TryTrimWorkingSet($process.Id, [ref]$nativeError)) {
                    $trimmed++
                }
                else {
                    $failed++
                }
            }
            catch [InvalidOperationException] {
                $skipped++
            }
            catch [ComponentModel.Win32Exception] {
                $skipped++
            }
            finally {
                $process.Dispose()
            }
        }

        Start-Sleep -Milliseconds 400
        $after = Update-MemoryDisplay
        $change = [int64]$after.InUse - [int64]$before.InUse
        $changeText = if ($change -ge 0) {
            '使用中内存变化：+{0:N0} MB' -f ($change / 1MB)
        }
        else {
            '使用中内存变化：-{0:N0} MB' -f ([Math]::Abs($change) / 1MB)
        }

        $statusText.Text = "已遍历 $examined 个进程，成功修剪 $trimmed 个工作集。$changeText`n跳过 $skipped 个已退出或状态变化的进程；$failed 个因系统保护、权限或进程状态未能处理。没有关闭任何程序。"
        if ($examined -eq 0) {
            $statusText.Text = "没有发现可处理的进程。$changeText`n没有关闭任何程序。"
        }
    }
    catch {
        $statusText.Text = "操作失败：$($_.Exception.Message)"
    }
    finally {
        $cleanButton.IsEnabled = $true
    }
})

try {
    [void](Update-MemoryDisplay)
    $statusText.Text = '点击按钮后将以管理员权限尝试修剪所有进程的工作集，不会退出或关闭程序。'
}
catch {
    $statusText.Text = "无法读取内存状态：$($_.Exception.Message)"
}

[void]$window.ShowDialog()
