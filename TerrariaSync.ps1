# Terraria Sync — selective save transfer between PC and Android over ADB.
param(
    [switch]$SelfTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

$script:RootFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:AdbPath = $null
$script:DeviceItems = @()
$script:Busy = $false
$script:CancelRequested = $false
$script:SuppressListEvents = $false
$script:SortColumn = 0
$script:SortAscending = $true
$script:DefaultMobilePath = '/sdcard/Android/data/com.and.games505.TerrariaPaid'

$script:StateText = @{
    OnlyPc      = 'Только на ПК'
    OnlyPhone   = 'Только на телефоне'
    PcNewer     = 'На ПК новее'
    PhoneNewer  = 'На телефоне новее'
    Same        = 'Совпадает'
    Different   = 'Различается'
}

function Resolve-AdbPath {
    $candidates = @(
        (Join-Path $script:RootFolder '.android-sdk\platform-tools\adb.exe'),
        (Join-Path (Split-Path -Parent $script:RootFolder) '.android-sdk\platform-tools\adb.exe'),
        'G:\NewPrograms\.android-sdk\platform-tools\adb.exe',
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function ConvertTo-ShellLiteral {
    param([string]$Value)
    "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-RuPlural {
    param([int]$Count, [string]$One, [string]$Few, [string]$Many)
    $tail = [Math]::Abs($Count) % 100
    $digit = $tail % 10
    if ($tail -ge 11 -and $tail -le 14) { return $Many }
    if ($digit -eq 1) { return $One }
    if ($digit -ge 2 -and $digit -le 4) { return $Few }
    return $Many
}

function Format-ByteSize {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return 'размер неизвестен' }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} КБ' -f ($Bytes / 1KB)) }
    return "$Bytes Б"
}

function Format-UnixLocal {
    param([long]$UnixTime)
    if ($UnixTime -le 0 -or $UnixTime -gt 4000000000) { return '' }
    return [DateTimeOffset]::FromUnixTimeSeconds($UnixTime).ToLocalTime().ToString('dd.MM.yy HH:mm')
}

function Format-SideSummary {
    param([object[]]$Files)
    $files = @($Files | Where-Object { $_ })
    if ($files.Count -eq 0) { return '—' }
    $known = @($files | Where-Object { $_.Size -ge 0 })
    $sizeText = if ($known.Count -eq $files.Count) {
        Format-ByteSize ([long](($known | Measure-Object Size -Sum).Sum))
    }
    else { 'размер неизвестен' }
    $newest = [long](($files | Measure-Object UnixTime -Maximum).Maximum)
    $when = Format-UnixLocal $newest
    $whenText = if ($when) { " · $when" } else { '' }
    $word = Get-RuPlural $files.Count 'файл' 'файла' 'файлов'
    return "$($files.Count) $word, $sizeText$whenText"
}

function Test-SaveRelativePath {
    param([string]$RelativePath, [ValidateSet('Players', 'Worlds')][string]$Kind)
    $relative = ($RelativePath -replace '\\', '/').TrimStart('/')
    if ($Kind -eq 'Players') {
        return ($relative -match '(?i)^[^/]+\.plr(\.bak)?$') -or ($relative -match '(?i)(?:^|/)[^/]+\.map(\.bak)?$')
    }
    return $relative -match '(?i)^[^/]+\.(wld|twld)(\.bak)?$'
}

function Get-BundleName {
    param([string]$RelativePath, [ValidateSet('Players', 'Worlds')][string]$Kind)
    $relative = ($RelativePath -replace '\\', '/').TrimStart('/')
    if ($Kind -eq 'Players') {
        if ($relative -match '(?i)^(.+?)\.plr(\.bak)?$') { return $Matches[1] }
        if ($relative -match '(?i)^(.+)/[^/]+\.map(\.bak)?$') { return $Matches[1] }
        if ($relative -match '(?i)^([^/]+)\.map(\.bak)?$') { return $Matches[1] }
        return $null
    }
    if ($relative -match '(?i)^(.+)\.(wld|twld)(\.bak)?$') { return $Matches[1] }
    return $null
}

function Get-PrimaryRelativePath {
    param([ValidateSet('Players', 'Worlds')][string]$Kind, [string]$Name)
    if ($Kind -eq 'Players') { return ($Name + '.plr') }
    return ($Name + '.wld')
}

function Get-SyncState {
    param([object[]]$PcFiles, [object[]]$PhoneFiles, [string]$Kind, [string]$Name)
    $pc = @($PcFiles | Where-Object { $_ })
    $phone = @($PhoneFiles | Where-Object { $_ })
    if ($pc.Count -eq 0 -and $phone.Count -eq 0) { return 'Empty' }
    if ($pc.Count -eq 0) { return 'OnlyPhone' }
    if ($phone.Count -eq 0) { return 'OnlyPc' }

    $primary = Get-PrimaryRelativePath -Kind $Kind -Name $Name
    $pcPrimary = $pc | Where-Object { $_.RelativePath -eq $primary } | Select-Object -First 1
    $phonePrimary = $phone | Where-Object { $_.RelativePath -eq $primary } | Select-Object -First 1
    $pcTime = if ($pcPrimary) { [long]$pcPrimary.UnixTime } else { [long](($pc | Measure-Object UnixTime -Maximum).Maximum) }
    $phoneTime = if ($phonePrimary) { [long]$phonePrimary.UnixTime } else { [long](($phone | Measure-Object UnixTime -Maximum).Maximum) }
    $pcSize = if ($pcPrimary) { [long]$pcPrimary.Size } else { -1 }
    $phoneSize = if ($phonePrimary) { [long]$phonePrimary.Size } else { -1 }

    if ($pcTime -gt 0 -and $phoneTime -gt 0) {
        $delta = [Math]::Abs($pcTime - $phoneTime)
        if ($delta -le 2 -and $pcSize -ge 0 -and $pcSize -eq $phoneSize) { return 'Same' }
        if ($delta -le 2) { return 'Different' }
        if ($pcTime -gt $phoneTime) { return 'PcNewer' }
        return 'PhoneNewer'
    }
    if ($pcSize -ge 0 -and $pcSize -eq $phoneSize) { return 'Same' }
    return 'Different'
}

function ConvertTo-SaveBundles {
    param([object[]]$PcPlayers, [object[]]$PcWorlds, [object[]]$PhonePlayers, [object[]]$PhoneWorlds)

    $map = @{}
    $groups = @(
        @{ Kind = 'Players'; Side = 'Pc'; Files = $PcPlayers },
        @{ Kind = 'Worlds'; Side = 'Pc'; Files = $PcWorlds },
        @{ Kind = 'Players'; Side = 'Phone'; Files = $PhonePlayers },
        @{ Kind = 'Worlds'; Side = 'Phone'; Files = $PhoneWorlds }
    )
    foreach ($group in $groups) {
        foreach ($file in @($group.Files | Where-Object { $_ })) {
            $name = Get-BundleName -RelativePath $file.RelativePath -Kind $group.Kind
            if (-not $name) { continue }
            $key = "$($group.Kind)|$name"
            if (-not $map.ContainsKey($key)) {
                $map[$key] = [pscustomobject]@{
                    Name   = $name
                    Kind   = $group.Kind
                    Pc     = New-Object System.Collections.ArrayList
                    Phone  = New-Object System.Collections.ArrayList
                    State  = 'Empty'
                }
            }
            [void]$map[$key].$($group.Side).Add($file)
        }
    }

    $bundles = foreach ($item in $map.Values) {
        $item.State = Get-SyncState -PcFiles $item.Pc.ToArray() -PhoneFiles $item.Phone.ToArray() -Kind $item.Kind -Name $item.Name
        $item
    }
    @($bundles | Sort-Object Kind, Name)
}

function Get-SettingsPath {
    Join-Path $script:RootFolder 'settings.json'
}

function Read-Settings {
    $path = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $null }
}

function Save-Settings {
    if (-not $script:PcPathBox) { return }
    $payload = [pscustomobject]@{
        PcPath       = $script:PcPathBox.Text.Trim()
        MobilePath   = $script:MobilePathBox.Text.Trim()
        DeviceSerial = ''
    }
    if ($script:DevicePicker.SelectedIndex -ge 0 -and $script:DevicePicker.SelectedIndex -lt $script:DeviceItems.Count) {
        $payload.DeviceSerial = [string]$script:DeviceItems[$script:DevicePicker.SelectedIndex].Serial
    }
    $json = $payload | ConvertTo-Json
    [System.IO.File]::WriteAllText((Get-SettingsPath), $json, [System.Text.UTF8Encoding]::new($true))
}

function Find-PcSaveFolder {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Documents\My Games\Terraria'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\My Games\Terraria'),
        (Join-Path $env:USERPROFILE 'OneDrive\Документы\My Games\Terraria'),
        (Join-Path $env:USERPROFILE 'Мои документы\My Games\Terraria')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'Players')) -or (Test-Path -LiteralPath (Join-Path $candidate 'Worlds'))) {
            return $candidate
        }
    }
    return $candidates[0]
}

function Invoke-Adb {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not $script:AdbPath -or -not (Test-Path -LiteralPath $script:AdbPath -PathType Leaf)) {
        $script:AdbPath = Resolve-AdbPath
    }
    if (-not $script:AdbPath) {
        throw 'Не найден adb.exe. Положите platform-tools в .android-sdk рядом с программой или добавьте adb в PATH.'
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Android returns UTF-8 names. Windows PowerShell otherwise decodes them with the OEM code page.
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $lines = @(& $script:AdbPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = (($lines | ForEach-Object { $_.ToString() }) -join "`r`n").Trim()
    }
}

function Get-SelectedDevice {
    if ($script:DevicePicker.SelectedIndex -lt 0 -or $script:DevicePicker.SelectedIndex -ge $script:DeviceItems.Count) {
        throw 'Сначала подключите телефон и выберите его в списке.'
    }
    $script:DeviceItems[$script:DevicePicker.SelectedIndex]
}

function Set-Status {
    param([string]$Message)
    if (-not $script:StatusLabel) { return }
    $script:StatusLabel.Text = $Message
    if ($script:MainForm) {
        $script:MainForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-Progress {
    param([int]$Percent, [string]$Message, [switch]$Marquee)
    if (-not $script:ProgressBar) { return }
    if ($Marquee) {
        $script:ProgressBar.Style = 'Marquee'
        $script:ProgressBar.MarqueeAnimationSpeed = 28
    }
    else {
        $script:ProgressBar.Style = 'Continuous'
        $script:ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
    }
    if ($Message) { Set-Status $Message }
}

function Add-Log {
    param([string]$Message)
    if (-not $script:LogBox) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:LogBox.AppendText("[$stamp] $Message`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Test-Cancel {
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:CancelRequested) { throw 'Отменено.' }
}

function Set-PrimaryButtonState {
    param($Button, [bool]$Enabled, [System.Drawing.Color]$Color)
    if (-not $Button) { return }
    $Button.Enabled = $Enabled
    if ($Enabled) {
        $Button.BackColor = $Color
        $Button.ForeColor = [System.Drawing.Color]::White
    }
    else {
        $Button.BackColor = [System.Drawing.Color]::FromArgb(214, 218, 224)
        $Button.ForeColor = [System.Drawing.Color]::FromArgb(110, 116, 124)
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:Busy = $Busy
    $enabled = -not $Busy
    Set-PrimaryButtonState $script:SyncToPhoneButton $enabled ([System.Drawing.Color]::FromArgb(29, 78, 137))
    Set-PrimaryButtonState $script:SyncFromPhoneButton $enabled ([System.Drawing.Color]::FromArgb(15, 110, 86))
    foreach ($button in @($script:RefreshListButton, $script:BrowsePcButton, $script:OpenPcButton, $script:RefreshDevicesButton, $script:DetectButton, $script:SelectAllButton, $script:SelectNoneButton, $script:SelectOnlyPcButton, $script:SelectOnlyPhoneButton, $script:SelectPcNewerButton, $script:SelectPhoneNewerButton, $script:OpenBackupsButton)) {
        if ($button) { $button.Enabled = $enabled }
    }
    if ($script:PcPathBox) { $script:PcPathBox.Enabled = $enabled }
    if ($script:MobilePathBox) { $script:MobilePathBox.Enabled = $enabled }
    if ($script:DevicePicker) { $script:DevicePicker.Enabled = $enabled }
    if ($script:CancelButton) { $script:CancelButton.Enabled = $Busy }
    if ($script:MainForm) { $script:MainForm.UseWaitCursor = $Busy }
}

function New-SaveFileRecord {
    param([string]$RelativePath, [long]$Size, [long]$UnixTime, [string]$FullName)
    [pscustomobject]@{
        RelativePath = ($RelativePath -replace '\\', '/').TrimStart('/')
        Size         = $Size
        UnixTime     = $UnixTime
        FullName     = $FullName
    }
}

function Get-LocalSaveFiles {
    param([string]$Folder, [ValidateSet('Players', 'Worlds')][string]$Kind)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    $root = $Folder.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $selected = New-Object System.Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($root.Length)
        if (-not (Test-SaveRelativePath -RelativePath $relative -Kind $Kind)) { continue }
        $unix = ([DateTimeOffset]$file.LastWriteTimeUtc).ToUnixTimeSeconds()
        [void]$selected.Add((New-SaveFileRecord -RelativePath $relative -Size $file.Length -UnixTime $unix -FullName $file.FullName))
    }
    return $selected.ToArray()
}

function Invoke-RemoteShell {
    param([string]$Serial, [string]$Command)
    Invoke-Adb -Arguments @('-s', $Serial, 'shell', $Command)
}

function Test-RemoteDirectory {
    param([string]$Serial, [string]$Path)
    $result = Invoke-RemoteShell -Serial $Serial -Command ("test -d " + (ConvertTo-ShellLiteral $Path))
    return ($result.ExitCode -eq 0)
}

function Test-RemoteFile {
    param([string]$Serial, [string]$Path)
    $result = Invoke-RemoteShell -Serial $Serial -Command ("test -f " + (ConvertTo-ShellLiteral $Path))
    return ($result.ExitCode -eq 0)
}

function New-RemoteDirectory {
    param([string]$Serial, [string]$Path)
    Invoke-RemoteShell -Serial $Serial -Command ("mkdir -p " + (ConvertTo-ShellLiteral $Path))
}

function Get-RemoteSaveFiles {
    param([string]$Serial, [string]$Folder, [ValidateSet('Players', 'Worlds')][string]$Kind)
    Test-Cancel
    if (-not (Test-RemoteDirectory -Serial $Serial -Path $Folder)) { return @() }
    $quoted = ConvertTo-ShellLiteral $Folder
    $stat = Invoke-RemoteShell -Serial $Serial -Command ("find $quoted -type f -exec stat -c '%s|%Y|%n' {} \;")
    $entries = New-Object System.Collections.ArrayList
    $parsed = $false
    if ($stat.ExitCode -eq 0) {
        foreach ($line in ($stat.Output -split "`r?`n")) {
            if ($line -match '^(\d+)\|(\d+)\|(.+)$') {
                $parsed = $true
                [void]$entries.Add([pscustomobject]@{
                    Size     = [int64]$Matches[1]
                    UnixTime = [int64]$Matches[2]
                    Full     = $Matches[3].Trim()
                })
            }
        }
        if (-not $stat.Output) { $parsed = $true }
    }
    if (-not $parsed) {
        $find = Invoke-RemoteShell -Serial $Serial -Command ("find $quoted -type f")
        if ($find.ExitCode -ne 0) {
            throw "Не удалось прочитать папку телефона $Folder. $($find.Output)"
        }
        foreach ($line in ($find.Output -split "`r?`n")) {
            $full = $line.Trim()
            if (-not $full -or $full -eq $Folder) { continue }
            [void]$entries.Add([pscustomobject]@{ Size = [int64]-1; UnixTime = [int64]0; Full = $full })
        }
    }

    $prefix = $Folder.TrimEnd('/') + '/'
    $selected = New-Object System.Collections.ArrayList
    foreach ($entry in $entries) {
        $full = [string]$entry.Full
        if (-not $full.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        $relative = $full.Substring($prefix.Length)
        if (-not (Test-SaveRelativePath -RelativePath $relative -Kind $Kind)) { continue }
        [void]$selected.Add((New-SaveFileRecord -RelativePath $relative -Size $entry.Size -UnixTime $entry.UnixTime -FullName $null))
    }
    return $selected.ToArray()
}

function Get-InventorySnapshot {
    $pcRoot = $script:PcPathBox.Text.Trim()
    $mobileRoot = $script:MobilePathBox.Text.Trim().TrimEnd('/')
    if (-not $pcRoot) { throw 'Укажите папку Terraria на компьютере.' }
    if (-not $mobileRoot.StartsWith('/')) { throw 'Укажите полный путь Android, начинающийся с /.' }

    Set-Progress -Percent 0 -Message 'Читаю сохранения на компьютере…' -Marquee
    $pcPlayers = @(Get-LocalSaveFiles -Folder (Join-Path $pcRoot 'Players') -Kind 'Players')
    Test-Cancel
    $pcWorlds = @(Get-LocalSaveFiles -Folder (Join-Path $pcRoot 'Worlds') -Kind 'Worlds')
    Test-Cancel

    $phonePlayers = @()
    $phoneWorlds = @()
    $phoneNote = ''
    try {
        $device = Get-SelectedDevice
        Set-Progress -Percent 0 -Message 'Читаю сохранения на телефоне…' -Marquee
        if (-not (Test-RemoteDirectory -Serial $device.Serial -Path $mobileRoot)) {
            throw 'В указанной папке телефона нет каталога. Нажмите «Найти папку» или проверьте путь.'
        }
        $playersDir = Test-RemoteDirectory -Serial $device.Serial -Path "$mobileRoot/Players"
        $worldsDir = Test-RemoteDirectory -Serial $device.Serial -Path "$mobileRoot/Worlds"
        if (-not $playersDir -and -not $worldsDir) {
            throw 'В папке телефона не найдены Players или Worlds. На этом телефоне сохранения могут лежать прямо в com.and.games505.TerrariaPaid, без /files.'
        }
        if ($playersDir) { $phonePlayers = @(Get-RemoteSaveFiles -Serial $device.Serial -Folder "$mobileRoot/Players" -Kind 'Players') }
        Test-Cancel
        if ($worldsDir) { $phoneWorlds = @(Get-RemoteSaveFiles -Serial $device.Serial -Folder "$mobileRoot/Worlds" -Kind 'Worlds') }
        $version = Invoke-RemoteShell -Serial $device.Serial -Command 'getprop ro.build.version.release'
        if ($version.ExitCode -eq 0 -and $version.Output) {
            $phoneNote = "Android $($version.Output.Trim())"
        }
    }
    catch {
        if ($_.Exception.Message -like 'Отменено*') { throw }
        $phoneNote = $_.Exception.Message
        Add-Log "Телефон не прочитан: $phoneNote"
    }

    $bundles = @(ConvertTo-SaveBundles -PcPlayers $pcPlayers -PcWorlds $pcWorlds -PhonePlayers $phonePlayers -PhoneWorlds $phoneWorlds)
    [pscustomobject]@{
        Bundles   = $bundles
        PhoneNote = $phoneNote
        PcRoot    = $pcRoot
        MobileRoot = $mobileRoot
    }
}

function Update-Summary {
    if (-not $script:SaveList -or -not $script:SummaryLabel) { return }
    $items = @($script:SaveList.Items)
    $players = @($items | Where-Object { $_.Tag.Kind -eq 'Players' }).Count
    $worlds = @($items | Where-Object { $_.Tag.Kind -eq 'Worlds' }).Count
    $checked = @($items | Where-Object { $_.Checked }).Count
    $playerWord = Get-RuPlural $players 'персонаж' 'персонажа' 'персонажей'
    $worldWord = Get-RuPlural $worlds 'мир' 'мира' 'миров'
    $script:SummaryLabel.Text = "В списке: $players $playerWord, $worlds $worldWord. Отмечено: $checked."
}

function Fill-SaveList {
    param($Snapshot)
    $list = $script:SaveList
    $script:SuppressListEvents = $true
    $list.BeginUpdate()
    try {
        $list.ListViewItemSorter = $null
        $list.Items.Clear()
        foreach ($bundle in @($Snapshot.Bundles)) {
            $kindText = if ($bundle.Kind -eq 'Players') { 'Персонаж' } else { 'Мир' }
            $item = New-Object System.Windows.Forms.ListViewItem($bundle.Name)
            $item.Name = "$($bundle.Kind)|$($bundle.Name)"
            $item.Tag = $bundle
            [void]$item.SubItems.Add($kindText)
            [void]$item.SubItems.Add((Format-SideSummary $bundle.Pc.ToArray()))
            [void]$item.SubItems.Add((Format-SideSummary $bundle.Phone.ToArray()))
            $state = [string]$bundle.State
            [void]$item.SubItems.Add($script:StateText[$state])
            $item.UseItemStyleForSubItems = $false
            $color = switch ($state) {
                'OnlyPc' { [System.Drawing.Color]::FromArgb(29, 78, 137) }
                'PcNewer' { [System.Drawing.Color]::FromArgb(29, 78, 137) }
                'OnlyPhone' { [System.Drawing.Color]::FromArgb(15, 110, 86) }
                'PhoneNewer' { [System.Drawing.Color]::FromArgb(15, 110, 86) }
                'Different' { [System.Drawing.Color]::FromArgb(138, 90, 0) }
                default { [System.Drawing.Color]::FromArgb(92, 101, 112) }
            }
            $item.SubItems[4].ForeColor = $color
            [void]$list.Items.Add($item)
        }
    }
    finally {
        $list.EndUpdate()
        $script:SuppressListEvents = $false
    }
    Update-Summary
    $count = @($Snapshot.Bundles).Count
    $noun = Get-RuPlural $count 'сохранение' 'сохранения' 'сохранений'
    if ($Snapshot.PhoneNote -and $Snapshot.PhoneNote -notlike 'Android *') {
        Set-Progress -Percent 0 -Message "Список ПК обновлён. Телефон: $($Snapshot.PhoneNote)"
    }
    else {
        $suffix = if ($Snapshot.PhoneNote) { " ($($Snapshot.PhoneNote))" } else { '' }
        Set-Progress -Percent 0 -Message "В списке $count $noun$suffix. Отметьте строки и выберите направление."
    }
    Add-Log "Список обновлён: $count $noun."
}

function Get-CheckedKeys {
    @($script:SaveList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Name })
}

function Restore-CheckedKeys {
    param([string[]]$Keys)
    $wanted = @{}
    foreach ($key in @($Keys)) { if ($key) { $wanted[$key] = $true } }
    $script:SuppressListEvents = $true
    try {
        foreach ($item in @($script:SaveList.Items)) {
            $item.Checked = $wanted.ContainsKey($item.Name)
        }
    }
    finally { $script:SuppressListEvents = $false }
    Update-Summary
}

function Set-ChecksByFilter {
    param([string]$Filter)
    $script:SuppressListEvents = $true
    try {
        foreach ($item in @($script:SaveList.Items)) {
            $state = [string]$item.Tag.State
            $item.Checked = switch ($Filter) {
                'All' { $true }
                'None' { $false }
                'OnlyPc' { $state -eq 'OnlyPc' }
                'OnlyPhone' { $state -eq 'OnlyPhone' }
                'PcNewer' { $state -in @('OnlyPc', 'PcNewer', 'Different') }
                'PhoneNewer' { $state -in @('OnlyPhone', 'PhoneNewer', 'Different') }
                default { $false }
            }
        }
    }
    finally { $script:SuppressListEvents = $false }
    Update-Summary
}

function Update-SaveList {
    if ($script:Busy) { return }
    $script:CancelRequested = $false
    Set-Busy $true
    try {
        $snapshot = Get-InventorySnapshot
        Fill-SaveList $snapshot
        Save-Settings
    }
    catch {
        if ($_.Exception.Message -like 'Отменено*') {
            Set-Progress -Percent 0 -Message 'Чтение списка отменено.'
            Add-Log 'Чтение списка отменено.'
        }
        else {
            Set-Progress -Percent 0 -Message 'Не удалось прочитать сохранения.'
            Add-Log "Ошибка: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Terraria Sync', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        $script:CancelRequested = $false
        Set-Busy $false
    }
}

function New-BackupDirectory {
    param([string]$Direction)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $path = Join-Path $script:RootFolder "Backups\${stamp}_$Direction"
    New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    return $path
}

function Copy-BundleFiles {
    param(
        [ValidateSet('PhoneToPC', 'PCToPhone')][string]$Direction,
        $Bundles,
        [string]$PcRoot,
        [string]$MobileRoot,
        [string]$Serial,
        [string]$BackupRoot
    )
    $sourceRoot = Join-Path $BackupRoot 'Source'
    $destinationRoot = Join-Path $BackupRoot 'DestinationBefore'
    $copied = 0
    $total = 0
    foreach ($bundle in @($Bundles)) {
        $sourceFiles = if ($Direction -eq 'PCToPhone') { @($bundle.Pc) } else { @($bundle.Phone) }
        $total += @($sourceFiles).Count
    }
    if ($total -eq 0) { return 0 }

    $index = 0
    foreach ($bundle in @($Bundles)) {
        $kind = $bundle.Kind
        $localFolder = Join-Path $PcRoot $kind
        $remoteFolder = "$MobileRoot/$kind"
        $sourceFiles = if ($Direction -eq 'PCToPhone') { @($bundle.Pc) } else { @($bundle.Phone) }
        foreach ($file in $sourceFiles) {
            Test-Cancel
            $index++
            $percent = [int](($index / $total) * 100)
            $relative = [string]$file.RelativePath
            $remotePath = "$remoteFolder/$relative"
            $localPath = Join-Path $localFolder ($relative -replace '/', '\')
            Set-Progress -Percent $percent -Message "$index/$total  $($bundle.Name)"

            if ($Direction -eq 'PCToPhone') {
                $sourceBackup = Join-Path (Join-Path $sourceRoot $kind) ($relative -replace '/', '\')
                $sourceParent = Split-Path -Parent $sourceBackup
                New-Item -ItemType Directory -Path $sourceParent -Force -ErrorAction Stop | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $sourceBackup -Force -ErrorAction Stop
                if (Test-RemoteFile -Serial $Serial -Path $remotePath) {
                    $destinationBackup = Join-Path (Join-Path (Join-Path $destinationRoot $kind) 'Replaced') ($relative -replace '/', '\')
                    $destinationParent = Split-Path -Parent $destinationBackup
                    New-Item -ItemType Directory -Path $destinationParent -Force -ErrorAction Stop | Out-Null
                    $pull = Invoke-Adb -Arguments @('-s', $Serial, 'pull', $remotePath, $destinationBackup)
                    if ($pull.ExitCode -ne 0) { throw "Не удалось сохранить прежнюю копию $relative. $($pull.Output)" }
                }
                $remoteParent = $remotePath.Substring(0, $remotePath.LastIndexOf('/'))
                $mkdir = New-RemoteDirectory -Serial $Serial -Path $remoteParent
                if ($mkdir.ExitCode -ne 0) { throw "Не удалось подготовить папку для $relative. $($mkdir.Output)" }
                $push = Invoke-Adb -Arguments @('-s', $Serial, 'push', $file.FullName, $remotePath)
                if ($push.ExitCode -ne 0) { throw "Не удалось отправить $relative. $($push.Output)" }
            }
            else {
                $sourceBackup = Join-Path (Join-Path $sourceRoot $kind) ($relative -replace '/', '\')
                $sourceParent = Split-Path -Parent $sourceBackup
                New-Item -ItemType Directory -Path $sourceParent -Force -ErrorAction Stop | Out-Null
                $sourceCopy = Invoke-Adb -Arguments @('-s', $Serial, 'pull', $remotePath, $sourceBackup)
                if ($sourceCopy.ExitCode -ne 0) {
                    throw "Не удалось создать исходную резервную копию $relative. Перенос этого файла не начат. $($sourceCopy.Output)"
                }
                $localParent = Split-Path -Parent $localPath
                New-Item -ItemType Directory -Path $localParent -Force -ErrorAction Stop | Out-Null
                if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                    $destinationBackup = Join-Path (Join-Path (Join-Path $destinationRoot $kind) 'Replaced') ($relative -replace '/', '\')
                    $destinationParent = Split-Path -Parent $destinationBackup
                    New-Item -ItemType Directory -Path $destinationParent -Force -ErrorAction Stop | Out-Null
                    Copy-Item -LiteralPath $localPath -Destination $destinationBackup -Force -ErrorAction Stop
                }
                $pull = Invoke-Adb -Arguments @('-s', $Serial, 'pull', $remotePath, $localPath)
                if ($pull.ExitCode -ne 0) { throw "Не удалось получить $relative. $($pull.Output)" }
            }
            $copied++
            Add-Log "Скопирован: $kind/$relative"
        }
    }
    return $copied
}

function Invoke-Transfer {
    param([ValidateSet('PhoneToPC', 'PCToPhone')][string]$Direction)
    if ($script:Busy) { return }
    $checked = @(Get-CheckedKeys)
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала отметьте сохранения в списке.`r`n`r`nМожно нажать «Список», затем «ПК новее» или «Телефон новее».",
            'Terraria Sync', 'OK', 'Information') | Out-Null
        return
    }

    $script:CancelRequested = $false
    Set-Busy $true
    $copied = 0
    $backupRoot = $null
    try {
        $snapshot = Get-InventorySnapshot
        Fill-SaveList $snapshot
        Restore-CheckedKeys $checked
        if ($snapshot.PhoneNote -and $snapshot.PhoneNote -notlike 'Android *') {
            throw $snapshot.PhoneNote
        }
        Test-Cancel
        $device = Get-SelectedDevice
        $selected = @($script:SaveList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
        $ready = @($selected | Where-Object {
            if ($Direction -eq 'PCToPhone') { @($_.Pc).Count -gt 0 } else { @($_.Phone).Count -gt 0 }
        })
        if ($ready.Count -eq 0) {
            $side = if ($Direction -eq 'PCToPhone') { 'на компьютере' } else { 'на телефоне' }
            throw "Среди отмеченных нет файлов $side."
        }

        $fileCount = 0
        foreach ($bundle in $ready) {
            $fileCount += if ($Direction -eq 'PCToPhone') { @($bundle.Pc).Count } else { @($bundle.Phone).Count }
        }
        $names = @($ready | Select-Object -First 12 | ForEach-Object {
            $kind = if ($_.Kind -eq 'Players') { 'персонаж' } else { 'мир' }
            "• $($_.Name) ($kind)"
        })
        if ($ready.Count -gt 12) { $names += "• и ещё $($ready.Count - 12)" }
        $directionText = if ($Direction -eq 'PCToPhone') { 'с компьютера на телефон' } else { 'с телефона на компьютер' }
        $script:MainForm.UseWaitCursor = $false
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Перед копированием полностью закройте Terraria на телефоне и на ПК.`r`n`r`nСкопировать $directionText?`r`nСохранений: $($ready.Count), файлов: $fileCount.`r`n`r`n$($names -join "`r`n")`r`n`r`nСначала программа сохранит копии отправляемых файлов, а перед заменой — прежние файлы назначения.",
            'Подтвердите копирование', 'YesNo', 'Warning')
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            Set-Progress -Percent 0 -Message 'Копирование не запущено.'
            return
        }
        $script:MainForm.UseWaitCursor = $true

        if (-not (Test-Path -LiteralPath $snapshot.PcRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $snapshot.PcRoot -Force | Out-Null
        }
        $mkdir = New-RemoteDirectory -Serial $device.Serial -Path "$($snapshot.MobileRoot)/Players"
        if ($mkdir.ExitCode -ne 0) { throw "Не удалось создать папки на телефоне. $($mkdir.Output)" }
        $mkdir = New-RemoteDirectory -Serial $device.Serial -Path "$($snapshot.MobileRoot)/Worlds"
        if ($mkdir.ExitCode -ne 0) { throw "Не удалось создать папки на телефоне. $($mkdir.Output)" }

        $backupRoot = New-BackupDirectory -Direction $Direction
        Add-Log "Резервная папка: $backupRoot"
        $copied = Copy-BundleFiles -Direction $Direction -Bundles $ready -PcRoot $snapshot.PcRoot -MobileRoot $snapshot.MobileRoot -Serial $device.Serial -BackupRoot $backupRoot
        Set-Progress -Percent 100 -Message "Готово: скопировано файлов — $copied."
        Add-Log "Готово ($directionText): файлов $copied."
        $script:MainForm.UseWaitCursor = $false
        [System.Windows.Forms.MessageBox]::Show(
            "Скопировано файлов: $copied.`r`n`r`nРезервные копии:`r`n$backupRoot",
            'Копирование завершено', 'OK', 'Information') | Out-Null
        $refreshed = Get-InventorySnapshot
        Fill-SaveList $refreshed
        Save-Settings
    }
    catch {
        $copiedNote = if ($copied -gt 0) { " Скопировано файлов до остановки: $copied." } else { '' }
        $backupNote = if ($backupRoot) { " Резервная папка: $backupRoot." } else { '' }
        if ($_.Exception.Message -like 'Отменено*') {
            Set-Progress -Percent 0 -Message "Копирование отменено.$copiedNote"
            Add-Log "Отменено.$copiedNote$backupNote"
            [System.Windows.Forms.MessageBox]::Show(
                "Копирование отменено.$copiedNote$backupNote",
                'Terraria Sync', 'OK', 'Warning') | Out-Null
        }
        else {
            Set-Progress -Percent 0 -Message 'Копирование остановлено.'
            Add-Log "Ошибка: $($_.Exception.Message)$copiedNote$backupNote"
            [System.Windows.Forms.MessageBox]::Show(
                "$($_.Exception.Message)$copiedNote$backupNote",
                'Terraria Sync — ошибка', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        $script:CancelRequested = $false
        Set-Busy $false
    }
}

function Refresh-Devices {
    try {
        $previous = ''
        if ($script:DevicePicker.SelectedIndex -ge 0 -and $script:DevicePicker.SelectedIndex -lt @($script:DeviceItems).Count) {
            $previous = [string]$script:DeviceItems[$script:DevicePicker.SelectedIndex].Serial
        }
        $result = Invoke-Adb -Arguments @('devices', '-l')
        if ($result.ExitCode -ne 0) { throw $result.Output }

        $script:DeviceItems = @()
        $script:DevicePicker.Items.Clear()
        $blocked = @()
        foreach ($line in ($result.Output -split "`r?`n")) {
            if ($line -match '^\s*(\S+)\s+(device|unauthorized|offline)(.*)$') {
                $serial = $Matches[1]
                $state = $Matches[2]
                $details = $Matches[3]
                if ($state -eq 'device') {
                    $model = ''
                    if ($details -match 'model:([^\s]+)') { $model = $Matches[1] -replace '_', ' ' }
                    $caption = if ($model) { "$model  —  $serial" } else { $serial }
                    $script:DeviceItems += [pscustomobject]@{ Serial = $serial; Caption = $caption }
                    [void]$script:DevicePicker.Items.Add($caption)
                }
                else { $blocked += "$serial ($state)" }
            }
        }

        $selected = 0
        for ($i = 0; $i -lt $script:DeviceItems.Count; $i++) {
            if ($script:DeviceItems[$i].Serial -eq $previous -or $script:DeviceItems[$i].Serial -eq $script:PreferredSerial) {
                $selected = $i
            }
        }
        if ($script:DevicePicker.Items.Count -gt 0) {
            $script:DevicePicker.SelectedIndex = $selected
            Set-Status "Телефон подключён: $($script:DeviceItems[$selected].Caption)"
            Add-Log "Устройств готово: $($script:DeviceItems.Count)."
        }
        elseif ($blocked.Count -gt 0) {
            Set-Status 'Разрешите отладку по USB на телефоне и нажмите «Устройства».'
            Add-Log "Устройство ждёт разрешения: $($blocked -join ', ')."
        }
        else {
            Set-Status 'Телефон не найден. Подключите USB, включите отладку и нажмите «Устройства».'
            Add-Log 'ADB не видит подключённых устройств.'
        }
    }
    catch {
        Set-Status 'Не удалось проверить подключение.'
        Add-Log "Ошибка ADB: $($_.Exception.Message)"
    }
}

function Find-MobileFolder {
    if ($script:Busy) { return }
    try {
        $device = Get-SelectedDevice
        Set-Busy $true
        Set-Progress -Percent 0 -Message 'Ищу папку сохранений Terraria на телефоне…' -Marquee
        $packagesResult = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'pm', 'list', 'packages')
        $packages = @()
        if ($packagesResult.ExitCode -eq 0) {
            $packages = @($packagesResult.Output -split "`r?`n" | ForEach-Object {
                if ($_ -match '^package:(.+)$') { $Matches[1].Trim() }
            } | Where-Object { $_ -match '(?i)terraria' })
        }
        $packages += @('com.and.games505.TerrariaPaid', 'com.and.games505.Terraria')
        $packages = @($packages | Select-Object -Unique)
        foreach ($package in $packages) {
            foreach ($suffix in @('', '/files')) {
                Test-Cancel
                $root = "/sdcard/Android/data/$package$suffix"
                if (Test-RemoteDirectory -Serial $device.Serial -Path $root) {
                    $hasPlayers = Test-RemoteDirectory -Serial $device.Serial -Path "$root/Players"
                    $hasWorlds = Test-RemoteDirectory -Serial $device.Serial -Path "$root/Worlds"
                    if ($hasPlayers -or $hasWorlds) {
                        $script:MobilePathBox.Text = $root
                        Set-Progress -Percent 0 -Message "Папка Terraria найдена."
                        Add-Log "Найдена папка телефона: $root"
                        Save-Settings
                        Set-Busy $false
                        Update-SaveList
                        return
                    }
                }
            }
        }
        Set-Progress -Percent 0 -Message 'Папка не найдена. Введите путь, в котором лежат Players и Worlds.'
        Add-Log 'Автопоиск не нашёл каталог Players или Worlds.'
        [System.Windows.Forms.MessageBox]::Show(
            "Автопоиск не нашёл папки Players и Worlds.`r`n`r`nУкажите путь к каталогу, в котором они лежат. Например:`r`n/sdcard/Android/data/com.and.games505.TerrariaPaid`r`n`r`nЕсли ADB отвечает Permission denied, доступ к Android/data ограничивает система. Если сохранения лежат во внутренней папке приложения, нужен экспорт самой игры или root.",
            'Terraria Sync', 'OK', 'Information') | Out-Null
    }
    catch {
        if ($_.Exception.Message -like 'Отменено*') {
            Set-Progress -Percent 0 -Message 'Поиск папки отменён.'
        }
        else {
            Set-Progress -Percent 0 -Message 'Не удалось найти папку телефона.'
            Add-Log "Ошибка поиска: $($_.Exception.Message)"
        }
    }
    finally {
        $script:CancelRequested = $false
        Set-Busy $false
    }
}

function Open-Folder {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.Windows.Forms.MessageBox]::Show("Папка ещё не создана:`r`n$Path", 'Terraria Sync', 'OK', 'Information') | Out-Null
        return
    }
    Start-Process -FilePath explorer.exe -ArgumentList "/e,`"$Path`""
}

function New-ToolButton {
    param([string]$Name, [string]$Text, [int]$Width, [scriptblock]$OnClick, [string]$Tip)
    $button = New-Object System.Windows.Forms.Button
    $button.Name = $Name
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width, 30)
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    $button.FlatStyle = 'Flat'
    $button.BackColor = [System.Drawing.Color]::White
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(206, 210, 216)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Add_Click($OnClick)
    if ($Tip) { $script:Tips.SetToolTip($button, $Tip) }
    return $button
}

function New-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Name = 'MainForm'
    $form.Text = 'Terraria Sync'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(1000, 860)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 248)
    $script:MainForm = $form
    $script:Tips = New-Object System.Windows.Forms.ToolTip
    $script:Tips.AutoPopDelay = 12000

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Size = New-Object System.Drawing.Size($form.ClientSize.Width, 252)
    $top.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 248)
    $top.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 8)

    $header = New-Object System.Windows.Forms.Label
    $header.Text = 'Terraria Sync'
    $header.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
    $header.ForeColor = [System.Drawing.Color]::FromArgb(28, 35, 43)
    $header.Location = New-Object System.Drawing.Point(16, 8)
    $header.Size = New-Object System.Drawing.Size(360, 34)
    $top.Controls.Add($header)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Сравните персонажей и миры, отметьте нужные и скопируйте их в одну сторону. Игру на обоих устройствах перед этим закройте.'
    $intro.ForeColor = [System.Drawing.Color]::FromArgb(78, 86, 96)
    $intro.Location = New-Object System.Drawing.Point(18, 44)
    $intro.Size = New-Object System.Drawing.Size(960, 36)
    $intro.Anchor = 'Top,Left,Right'
    $top.Controls.Add($intro)

    $pcLabel = New-Object System.Windows.Forms.Label
    $pcLabel.Text = 'Папка Terraria на компьютере'
    $pcLabel.Location = New-Object System.Drawing.Point(16, 86)
    $pcLabel.Size = New-Object System.Drawing.Size(400, 18)
    $top.Controls.Add($pcLabel)

    $script:PcPathBox = New-Object System.Windows.Forms.TextBox
    $script:PcPathBox.Name = 'PcPathBox'
    $script:PcPathBox.Location = New-Object System.Drawing.Point(16, 106)
    $script:PcPathBox.Size = New-Object System.Drawing.Size(752, 26)
    $script:PcPathBox.Anchor = 'Top,Left,Right'
    $script:PcPathBox.Text = Find-PcSaveFolder
    $top.Controls.Add($script:PcPathBox)

    $script:BrowsePcButton = New-Object System.Windows.Forms.Button
    $script:BrowsePcButton.Name = 'BrowsePcButton'
    $script:BrowsePcButton.Text = 'Обзор'
    $script:BrowsePcButton.Location = New-Object System.Drawing.Point(776, 104)
    $script:BrowsePcButton.Size = New-Object System.Drawing.Size(100, 28)
    $script:BrowsePcButton.Anchor = 'Top,Right'
    $script:BrowsePcButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите папку Terraria, где находятся Players и Worlds'
        if (Test-Path -LiteralPath $script:PcPathBox.Text) { $dialog.SelectedPath = $script:PcPathBox.Text }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:PcPathBox.Text = $dialog.SelectedPath
            Save-Settings
        }
    })
    $top.Controls.Add($script:BrowsePcButton)

    $script:OpenPcButton = New-Object System.Windows.Forms.Button
    $script:OpenPcButton.Name = 'OpenPcButton'
    $script:OpenPcButton.Text = 'Открыть'
    $script:OpenPcButton.Location = New-Object System.Drawing.Point(884, 104)
    $script:OpenPcButton.Size = New-Object System.Drawing.Size(100, 28)
    $script:OpenPcButton.Anchor = 'Top,Right'
    $script:OpenPcButton.Add_Click({ Open-Folder -Path $script:PcPathBox.Text.Trim() })
    $top.Controls.Add($script:OpenPcButton)

    $deviceLabel = New-Object System.Windows.Forms.Label
    $deviceLabel.Text = 'Телефон по USB'
    $deviceLabel.Location = New-Object System.Drawing.Point(16, 140)
    $deviceLabel.Size = New-Object System.Drawing.Size(400, 18)
    $top.Controls.Add($deviceLabel)

    $script:DevicePicker = New-Object System.Windows.Forms.ComboBox
    $script:DevicePicker.Name = 'DevicePicker'
    $script:DevicePicker.DropDownStyle = 'DropDownList'
    $script:DevicePicker.Location = New-Object System.Drawing.Point(16, 160)
    $script:DevicePicker.Size = New-Object System.Drawing.Size(752, 27)
    $script:DevicePicker.Anchor = 'Top,Left,Right'
    $top.Controls.Add($script:DevicePicker)

    $script:RefreshDevicesButton = New-Object System.Windows.Forms.Button
    $script:RefreshDevicesButton.Name = 'RefreshDevicesButton'
    $script:RefreshDevicesButton.Text = 'Устройства'
    $script:RefreshDevicesButton.Location = New-Object System.Drawing.Point(776, 158)
    $script:RefreshDevicesButton.Size = New-Object System.Drawing.Size(100, 28)
    $script:RefreshDevicesButton.Anchor = 'Top,Right'
    $script:RefreshDevicesButton.Add_Click({ Refresh-Devices })
    $top.Controls.Add($script:RefreshDevicesButton)

    $script:DetectButton = New-Object System.Windows.Forms.Button
    $script:DetectButton.Name = 'DetectButton'
    $script:DetectButton.Text = 'Найти папку'
    $script:DetectButton.Location = New-Object System.Drawing.Point(884, 158)
    $script:DetectButton.Size = New-Object System.Drawing.Size(100, 28)
    $script:DetectButton.Anchor = 'Top,Right'
    $script:DetectButton.Add_Click({ Find-MobileFolder })
    $top.Controls.Add($script:DetectButton)

    $mobileLabel = New-Object System.Windows.Forms.Label
    $mobileLabel.Text = 'Папка сохранений на телефоне'
    $mobileLabel.Location = New-Object System.Drawing.Point(16, 196)
    $mobileLabel.Size = New-Object System.Drawing.Size(500, 18)
    $top.Controls.Add($mobileLabel)

    $script:MobilePathBox = New-Object System.Windows.Forms.TextBox
    $script:MobilePathBox.Name = 'MobilePathBox'
    $script:MobilePathBox.Location = New-Object System.Drawing.Point(16, 216)
    $script:MobilePathBox.Size = New-Object System.Drawing.Size(968, 26)
    $script:MobilePathBox.Anchor = 'Top,Left,Right'
    $script:MobilePathBox.Text = $script:DefaultMobilePath
    $top.Controls.Add($script:MobilePathBox)

    $settings = Read-Settings
    if ($settings) {
        if ($settings.PcPath) { $script:PcPathBox.Text = [string]$settings.PcPath }
        if ($settings.MobilePath) { $script:MobilePathBox.Text = [string]$settings.MobilePath }
        $script:PreferredSerial = [string]$settings.DeviceSerial
    }

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 318
    $bottom.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 248)

    $script:SaveList = New-Object System.Windows.Forms.ListView
    $script:SaveList.Name = 'SaveList'
    $script:SaveList.Dock = 'Fill'
    $script:SaveList.View = 'Details'
    $script:SaveList.CheckBoxes = $true
    $script:SaveList.FullRowSelect = $true
    $script:SaveList.GridLines = $true
    $script:SaveList.HideSelection = $false
    $script:SaveList.MultiSelect = $false
    $script:SaveList.BackColor = [System.Drawing.Color]::White
    $script:SaveList.BorderStyle = 'None'
    [void]$script:SaveList.Columns.Add('Имя', 250)
    [void]$script:SaveList.Columns.Add('Тип', 110)
    [void]$script:SaveList.Columns.Add('На компьютере', 230)
    [void]$script:SaveList.Columns.Add('На телефоне', 230)
    [void]$script:SaveList.Columns.Add('Состояние', 150)
    $script:SaveList.Add_ItemChecked({ if (-not $script:SuppressListEvents) { Update-Summary } })
    $script:SaveList.Add_ItemActivate({
        $item = $script:SaveList.SelectedItems | Select-Object -First 1
        if (-not $item) { return }
        $bundle = $item.Tag
        $pcNames = @($bundle.Pc | ForEach-Object { $_.RelativePath }) -join ', '
        $phoneNames = @($bundle.Phone | ForEach-Object { $_.RelativePath }) -join ', '
        if (-not $pcNames) { $pcNames = 'нет' }
        if (-not $phoneNames) { $phoneNames = 'нет' }
        Add-Log "$($bundle.Name): ПК — $pcNames"
        Add-Log "$($bundle.Name): телефон — $phoneNames"
    })
    $script:SaveList.Add_ColumnClick({
        $column = $_.Column
        if ($script:SortColumn -eq $column) { $script:SortAscending = -not $script:SortAscending }
        else { $script:SortColumn = $column; $script:SortAscending = $true }
        $items = @($script:SaveList.Items)
        $sorted = @($items | Sort-Object { $_.SubItems[$column].Text })
        if (-not $script:SortAscending) { [array]::Reverse($sorted) }
        $script:SuppressListEvents = $true
        $script:SaveList.BeginUpdate()
        try {
            $script:SaveList.Items.Clear()
            if ($sorted.Count -gt 0) { $script:SaveList.Items.AddRange($sorted) }
        }
        finally {
            $script:SaveList.EndUpdate()
            $script:SuppressListEvents = $false
        }
    })
    $script:Tips.SetToolTip($script:SaveList, 'Состояние «новее» считается по времени файла .plr или .wld. Двойной щелчок показывает состав сохранения.')

    $summaryHost = New-Object System.Windows.Forms.Panel
    $summaryHost.Dock = 'Top'
    $summaryHost.Height = 28
    $script:SummaryLabel = New-Object System.Windows.Forms.Label
    $script:SummaryLabel.Name = 'SummaryLabel'
    $script:SummaryLabel.Dock = 'Fill'
    $script:SummaryLabel.Text = 'Нажмите «Список», чтобы прочитать сохранения на компьютере и телефоне.'
    $script:SummaryLabel.TextAlign = 'MiddleLeft'
    $script:SummaryLabel.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
    $script:SummaryLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $summaryHost.Controls.Add($script:SummaryLabel)

    $actionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $actionFlow.Dock = 'Top'
    $actionFlow.Height = 56
    $actionFlow.Padding = New-Object System.Windows.Forms.Padding(16, 6, 16, 0)
    $actionFlow.WrapContents = $false

    $script:SyncToPhoneButton = New-Object System.Windows.Forms.Button
    $script:SyncToPhoneButton.Name = 'SyncToPhoneButton'
    $script:SyncToPhoneButton.Text = 'Отправить отмеченные на телефон'
    $script:SyncToPhoneButton.Size = New-Object System.Drawing.Size(360, 40)
    $script:SyncToPhoneButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $script:SyncToPhoneButton.FlatStyle = 'Flat'
    $script:SyncToPhoneButton.FlatAppearance.BorderSize = 0
    $script:SyncToPhoneButton.BackColor = [System.Drawing.Color]::FromArgb(29, 78, 137)
    $script:SyncToPhoneButton.ForeColor = [System.Drawing.Color]::White
    $script:SyncToPhoneButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $script:SyncToPhoneButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:SyncToPhoneButton.Add_Click({ Invoke-Transfer -Direction 'PCToPhone' })
    $actionFlow.Controls.Add($script:SyncToPhoneButton)

    $script:SyncFromPhoneButton = New-Object System.Windows.Forms.Button
    $script:SyncFromPhoneButton.Name = 'SyncFromPhoneButton'
    $script:SyncFromPhoneButton.Text = 'Скачать отмеченные на компьютер'
    $script:SyncFromPhoneButton.Size = New-Object System.Drawing.Size(360, 40)
    $script:SyncFromPhoneButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $script:SyncFromPhoneButton.FlatStyle = 'Flat'
    $script:SyncFromPhoneButton.FlatAppearance.BorderSize = 0
    $script:SyncFromPhoneButton.BackColor = [System.Drawing.Color]::FromArgb(15, 110, 86)
    $script:SyncFromPhoneButton.ForeColor = [System.Drawing.Color]::White
    $script:SyncFromPhoneButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $script:SyncFromPhoneButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:SyncFromPhoneButton.Add_Click({ Invoke-Transfer -Direction 'PhoneToPC' })
    $actionFlow.Controls.Add($script:SyncFromPhoneButton)

    $script:CancelButton = New-Object System.Windows.Forms.Button
    $script:CancelButton.Name = 'CancelButton'
    $script:CancelButton.Text = 'Отмена'
    $script:CancelButton.Size = New-Object System.Drawing.Size(110, 40)
    $script:CancelButton.Enabled = $false
    $script:CancelButton.FlatStyle = 'Flat'
    $script:CancelButton.BackColor = [System.Drawing.Color]::White
    $script:CancelButton.Add_Click({
        $script:CancelRequested = $true
        Add-Log 'Останавливаю текущую операцию…'
    })
    $actionFlow.Controls.Add($script:CancelButton)

    $filterFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $filterFlow.Dock = 'Top'
    $filterFlow.Height = 42
    $filterFlow.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
    $filterFlow.WrapContents = $false
    $script:RefreshListButton = New-ToolButton 'RefreshListButton' 'Список' 90 { Update-SaveList } 'Прочитать персонажей и миры с компьютера и телефона.'
    $script:SelectAllButton = New-ToolButton 'SelectAllButton' 'Все' 64 { Set-ChecksByFilter 'All' } 'Отметить все строки.'
    $script:SelectNoneButton = New-ToolButton 'SelectNoneButton' 'Снять' 76 { Set-ChecksByFilter 'None' } 'Снять все отметки.'
    $script:SelectOnlyPcButton = New-ToolButton 'SelectOnlyPcButton' 'Только ПК' 108 { Set-ChecksByFilter 'OnlyPc' } 'Отметить сохранения, которых нет на телефоне.'
    $script:SelectOnlyPhoneButton = New-ToolButton 'SelectOnlyPhoneButton' 'Только телефон' 140 { Set-ChecksByFilter 'OnlyPhone' } 'Отметить сохранения, которых нет на компьютере.'
    $script:SelectPcNewerButton = New-ToolButton 'SelectPcNewerButton' 'ПК новее' 104 { Set-ChecksByFilter 'PcNewer' } 'Отметить то, что есть только на ПК, новее на ПК или различается.'
    $script:SelectPhoneNewerButton = New-ToolButton 'SelectPhoneNewerButton' 'Телефон новее' 140 { Set-ChecksByFilter 'PhoneNewer' } 'Отметить то, что есть только на телефоне, новее на телефоне или различается.'
    $script:OpenBackupsButton = New-ToolButton 'OpenBackupsButton' 'Копии' 80 { Open-Folder -Path (Join-Path $script:RootFolder 'Backups') } 'Открыть папку резервных копий.'
    foreach ($button in @($script:RefreshListButton, $script:SelectAllButton, $script:SelectNoneButton, $script:SelectOnlyPcButton, $script:SelectOnlyPhoneButton, $script:SelectPcNewerButton, $script:SelectPhoneNewerButton, $script:OpenBackupsButton)) {
        $filterFlow.Controls.Add($button)
    }

    $progressHost = New-Object System.Windows.Forms.Panel
    $progressHost.Dock = 'Top'
    $progressHost.Height = 28
    $progressHost.Padding = New-Object System.Windows.Forms.Padding(16, 4, 16, 4)
    $script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $script:ProgressBar.Name = 'ProgressBar'
    $script:ProgressBar.Dock = 'Fill'
    $script:ProgressBar.Minimum = 0
    $script:ProgressBar.Maximum = 100
    $progressHost.Controls.Add($script:ProgressBar)

    $statusHost = New-Object System.Windows.Forms.Panel
    $statusHost.Dock = 'Top'
    $statusHost.Height = 36
    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Name = 'StatusLabel'
    $script:StatusLabel.Dock = 'Fill'
    $script:StatusLabel.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
    $script:StatusLabel.TextAlign = 'MiddleLeft'
    $script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $script:StatusLabel.Text = 'Подключите телефон, разблокируйте его и подтвердите запрос отладки по USB.'
    $statusHost.Controls.Add($script:StatusLabel)

    $logHost = New-Object System.Windows.Forms.Panel
    $logHost.Dock = 'Fill'
    $logHost.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 12)
    $script:LogBox = New-Object System.Windows.Forms.TextBox
    $script:LogBox.Name = 'LogBox'
    $script:LogBox.Dock = 'Fill'
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = 'Vertical'
    $script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 252)
    $script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logHost.Controls.Add($script:LogBox)

    $bottom.Controls.Add($logHost)
    $bottom.Controls.Add($statusHost)
    $bottom.Controls.Add($progressHost)
    $bottom.Controls.Add($filterFlow)
    $bottom.Controls.Add($actionFlow)
    $bottom.Controls.Add($summaryHost)

    $form.Controls.Add($script:SaveList)
    $form.Controls.Add($bottom)
    $form.Controls.Add($top)
    $form.MinimumSize = $form.Size
    $form.Add_FormClosing({
        if ($script:Busy) {
            $_.Cancel = $true
            $script:CancelRequested = $true
            Add-Log 'Окно закроется после остановки текущей операции.'
        }
        elseif ($script:AllowSettingsSave) {
            Save-Settings
        }
    })
    return $form
}

function Invoke-SelfTest {
    $errors = New-Object System.Collections.Generic.List[string]
    function Assert-True {
        param($Condition, [string]$Message)
        if (-not $Condition) { $script:SelfTestErrors.Add($Message) }
    }
    $script:SelfTestErrors = $errors

    Assert-True ((Get-RuPlural 1 'файл' 'файла' 'файлов') -eq 'файл') 'plural 1'
    Assert-True ((Get-RuPlural 2 'файл' 'файла' 'файлов') -eq 'файла') 'plural 2'
    Assert-True ((Get-RuPlural 5 'файл' 'файла' 'файлов') -eq 'файлов') 'plural 5'
    Assert-True ((Get-RuPlural 11 'файл' 'файла' 'файлов') -eq 'файлов') 'plural 11'
    Assert-True ((Get-RuPlural 21 'файл' 'файла' 'файлов') -eq 'файл') 'plural 21'
    Assert-True ((ConvertTo-ShellLiteral "it's") -eq "'it'\''s'") 'shell quote'

    Assert-True (Test-SaveRelativePath 'Hero.plr' 'Players') 'plr accepted'
    Assert-True (Test-SaveRelativePath 'Hero.plr.bak' 'Players') 'plr bak accepted'
    Assert-True (Test-SaveRelativePath 'Hero/map.map' 'Players') 'map accepted'
    Assert-True (Test-SaveRelativePath 'Hero/map.map.bak' 'Players') 'map bak accepted'
    Assert-True (-not (Test-SaveRelativePath 'notes.txt' 'Players')) 'txt rejected'
    Assert-True (Test-SaveRelativePath 'World.wld' 'Worlds') 'wld accepted'
    Assert-True (Test-SaveRelativePath 'World.twld.bak' 'Worlds') 'twld bak accepted'
    Assert-True (-not (Test-SaveRelativePath 'World/extra.wld' 'Worlds')) 'nested world rejected'
    Assert-True ((Get-BundleName 'Hero/abc.map' 'Players') -eq 'Hero') 'map bundle name'
    Assert-True ((Get-BundleName 'Мир.wld.bak' 'Worlds') -eq 'Мир') 'world bak name'

    $pcPlayer = @(
        (New-SaveFileRecord 'Hero.plr' 100 1000 'C:\Hero.plr'),
        (New-SaveFileRecord 'Hero/a.map' 50 1000 $null)
    )
    $phonePlayer = @(
        (New-SaveFileRecord 'Hero.plr' 100 1000 $null),
        (New-SaveFileRecord 'Hero/a.map' 50 900 $null)
    )
    $phoneOnly = @((New-SaveFileRecord 'Newbie.plr' 10 2000 $null))
    $pcWorld = @((New-SaveFileRecord 'Мир.wld' 80 3000 $null), (New-SaveFileRecord 'Мир.twld' 20 3000 $null))
    $phoneWorld = @((New-SaveFileRecord 'Мир.wld' 90 1000 $null))
    $bundles = @(ConvertTo-SaveBundles -PcPlayers $pcPlayer -PcWorlds $pcWorld -PhonePlayers ($phonePlayer + $phoneOnly) -PhoneWorlds $phoneWorld)
    $hero = $bundles | Where-Object { $_.Name -eq 'Hero' } | Select-Object -First 1
    $newbie = $bundles | Where-Object { $_.Name -eq 'Newbie' } | Select-Object -First 1
    $world = $bundles | Where-Object { $_.Name -eq 'Мир' } | Select-Object -First 1
    Assert-True ($hero.State -eq 'Same') "hero state $($hero.State)"
    Assert-True (@($hero.Pc).Count -eq 2) 'hero keeps map with player'
    Assert-True ($newbie.State -eq 'OnlyPhone') "newbie state $($newbie.State)"
    Assert-True ($world.State -eq 'PcNewer') "world state $($world.State)"
    Assert-True ((Format-SideSummary @((New-SaveFileRecord 'A.plr' 1536 0 $null))) -like '1 файл, *КБ') 'side summary'

    $newerPhone = Get-SyncState -PcFiles @((New-SaveFileRecord 'A.plr' 10 1000 $null)) -PhoneFiles @((New-SaveFileRecord 'A.plr' 10 5000 $null)) -Kind 'Players' -Name 'A'
    Assert-True ($newerPhone -eq 'PhoneNewer') 'phone newer'
    $different = Get-SyncState -PcFiles @((New-SaveFileRecord 'A.plr' 10 1000 $null)) -PhoneFiles @((New-SaveFileRecord 'A.plr' 11 1001 $null)) -Kind 'Players' -Name 'A'
    Assert-True ($different -eq 'Different') 'different size'

    $form = New-MainForm
    foreach ($name in @('PcPathBox', 'MobilePathBox', 'DevicePicker', 'SaveList', 'SyncToPhoneButton', 'SyncFromPhoneButton', 'RefreshListButton', 'CancelButton', 'ProgressBar', 'StatusLabel', 'LogBox', 'SummaryLabel')) {
        $found = @($form.Controls.Find($name, $true))
        Assert-True ($found.Count -eq 1) "missing control $name"
    }
    Assert-True ($script:SaveList.CheckBoxes) 'list has checkboxes'
    Assert-True ($script:SaveList.Columns.Count -eq 5) 'five columns'
    $snapshot = [pscustomobject]@{ Bundles = $bundles; PhoneNote = 'Android 16' }
    Fill-SaveList $snapshot
    Assert-True ($script:SaveList.Items.Count -eq @($bundles).Count) 'row count'
    Set-ChecksByFilter 'PcNewer'
    $checkedNames = @($script:SaveList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Tag.Name })
    Assert-True ($checkedNames.Count -eq 1 -and $checkedNames[0] -eq 'Мир') 'pc newer selects the newer world'
    Set-ChecksByFilter 'PhoneNewer'
    $phoneNames = @($script:SaveList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Tag.Name })
    Assert-True (($phoneNames -contains 'Newbie') -and -not ($phoneNames -contains 'Hero')) 'phone filter skips identical hero'
    $expectedSummary = 'В списке: 2 персонажа, 1 мир. Отмечено: 1.'
    if ($script:SummaryLabel.Text -ne $expectedSummary) {
        $kinds = @($script:SaveList.Items | ForEach-Object { $_.Text + '=' + [string]$_.Tag.Kind }) -join ', '
        throw "SUMMARY [$($script:SummaryLabel.Text)] KINDS [$kinds]"
    }
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $bounds = $form.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $bounds.Width, $bounds.Height)))
    $shot = Join-Path $env:TEMP 'terraria-sync-ui.png'
    $bitmap.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Close()
    $form.Dispose()
    Assert-True ((Test-Path -LiteralPath $shot) -and ((Get-Item -LiteralPath $shot).Length -gt 1000)) 'ui bitmap'

    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Output "FAIL: $_" }
        exit 1
    }
    Write-Output 'PASS'
    exit 0
}

if ($SelfTest) {
    try { Invoke-SelfTest }
    catch {
        Write-Output "FAIL: $($_.Exception.Message)"
        exit 1
    }
}

$script:AdbPath = Resolve-AdbPath
$script:AllowSettingsSave = $true
$mainForm = New-MainForm
$mainForm.Add_Shown({
    if ($script:AdbPath) { Add-Log "ADB: $script:AdbPath" }
    else { Add-Log 'adb.exe не найден. Проверьте platform-tools.' }
    Refresh-Devices
    Update-SaveList
})
[void]$mainForm.ShowDialog()
$mainForm.Dispose()
