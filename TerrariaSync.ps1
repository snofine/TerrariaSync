Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ==============================================================================
# Global State & ADB Configuration
# ==============================================================================
$script:RootFolder = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $script:RootFolder) { $script:RootFolder = 'g:\NewPrograms\TerrariaSync' }
$script:ProjectRoot = Split-Path -Parent $script:RootFolder
$script:DeviceItems = @()
$script:AdbPath = $null

function Resolve-AdbPath {
    $candidates = @(
        (Join-Path $script:RootFolder '.android-sdk\platform-tools\adb.exe'),
        (Join-Path (Split-Path -Parent $script:RootFolder) '.android-sdk\platform-tools\adb.exe'),
        'G:\NewPrograms\.android-sdk\platform-tools\adb.exe',
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
        (Join-Path $env:ProgramFiles 'Android\platform-tools\adb.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Android\platform-tools\adb.exe')
    )
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
            return $cand
        }
    }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:AdbPath = Resolve-AdbPath

function Invoke-Adb {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not $script:AdbPath -or -not (Test-Path -LiteralPath $script:AdbPath)) {
        $resolved = Resolve-AdbPath
        if ($resolved) {
            $script:AdbPath = $resolved
        }
        else {
            throw "Не найден adb.exe. Убедитесь, что Android SDK platform-tools установлен или находится в PATH."
        }
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
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
        throw 'Сначала подключите телефон и выберите его в списке устройств.'
    }
    $script:DeviceItems[$script:DevicePicker.SelectedIndex]
}

function Set-Status {
    param([string]$Message)
    $script:StatusLabel.Text = $Message
    $script:MainForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Message
    )
    if ($Total -gt 0) {
        $pct = [Math]::Min(100, [int](($Current / $Total) * 100))
        $script:ProgressBar.Value = $pct
        $script:StatusLabel.Text = "[$Current/$Total — $pct%] $Message"
    }
    else {
        $script:ProgressBar.Value = 0
        $script:StatusLabel.Text = $Message
    }
    $script:MainForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-Log {
    param([string]$Message)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:LogBox.AppendText("[$stamp] $Message`r`n")
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

# ==============================================================================
# PC and Android Save File Discovery
# ==============================================================================
function Find-PcSaveFolder {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Documents\My Games\Terraria'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\My Games\Terraria'),
        (Join-Path $env:USERPROFILE 'Мои документы\My Games\Terraria')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path (Join-Path $candidate 'Players')) -or (Test-Path (Join-Path $candidate 'Worlds'))) {
            return $candidate
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    $candidates[0]
}

function Update-PcStats {
    try {
        $pcRoot = $script:PcPathBox.Text.Trim()
        if (-not $pcRoot -or -not (Test-Path -LiteralPath $pcRoot -PathType Container)) {
            $script:PcStatsLabel.Text = "⚠️ Папка не найдена"
            $script:PcStatsLabel.ForeColor = [System.Drawing.Color]::FromArgb(248, 81, 73)
            return
        }

        $playersDir = Join-Path $pcRoot 'Players'
        $worldsDir = Join-Path $pcRoot 'Worlds'

        $playerFiles = if (Test-Path $playersDir) {
            @(Get-ChildItem -LiteralPath $playersDir -Filter "*.plr" -File -ErrorAction SilentlyContinue)
        } else { @() }

        $worldFiles = if (Test-Path $worldsDir) {
            @(Get-ChildItem -LiteralPath $worldsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(wld|twld)$' })
        } else { @() }

        $script:PcStatsLabel.Text = "👤 Персонажей: $($playerFiles.Count)   |   🗺️ Миров: $($worldFiles.Count)"
        $script:PcStatsLabel.ForeColor = [System.Drawing.Color]::FromArgb(63, 185, 80)
    }
    catch {
        $script:PcStatsLabel.Text = "Ошибка чтения папки"
        $script:PcStatsLabel.ForeColor = [System.Drawing.Color]::FromArgb(139, 148, 158)
    }
}

function Refresh-Devices {
    try {
        $result = Invoke-Adb -Arguments @('devices', '-l')
        if ($result.ExitCode -ne 0) {
            throw $result.Output
        }

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
                    $caption = if ($model) { "$serial  —  $model" } else { $serial }
                    $script:DeviceItems += [pscustomobject]@{ Serial = $serial; Caption = $caption }
                    [void]$script:DevicePicker.Items.Add($caption)
                }
                else {
                    $blocked += "$serial ($state)"
                }
            }
        }

        if ($script:DevicePicker.Items.Count -gt 0) {
            $script:DevicePicker.SelectedIndex = 0
            $activeDevice = $script:DeviceItems[0]
            $script:DeviceStatusLabel.Text = "🟢 Подключен: $($activeDevice.Caption)"
            $script:DeviceStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(63, 185, 80)
            Set-Status "Телефон готов к работе: $($activeDevice.Caption)"
            Add-Log "Найдено активных устройств: $($script:DeviceItems.Count)."
        }
        elseif ($blocked.Count -gt 0) {
            $script:DeviceStatusLabel.Text = "🟡 Требуется разрешение на экране телефона"
            $script:DeviceStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(210, 153, 34)
            Set-Status "Разрешите USB отладку на телефоне и нажмите «Обновить»."
            Add-Log "Устройство ожидает авторизации: $($blocked -join ', ')."
        }
        else {
            $script:DeviceStatusLabel.Text = "🔴 Телефон не обнаружен (проверьте USB кабель)"
            $script:DeviceStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(248, 81, 73)
            Set-Status 'Телефон не найден. Подключите USB, включите USB отладку и нажмите «Обновить».'
            Add-Log 'ADB не обнаружил подключенных устройств.'
        }
    }
    catch {
        $script:DeviceStatusLabel.Text = "🔴 Ошибка вызова ADB"
        $script:DeviceStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(248, 81, 73)
        Set-Status 'Не удалось связаться с ADB.'
        Add-Log "Ошибка ADB: $($_.Exception.Message)"
    }
}

function Test-MobileFolder {
    param([string]$Serial, [string]$Root)

    $rootCheck = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'test', '-d', $Root)
    if ($rootCheck.ExitCode -ne 0) { return $false }
    $players = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'test', '-d', "$Root/Players")
    if ($players.ExitCode -eq 0) { return $true }
    $worlds = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'test', '-d', "$Root/Worlds")
    return ($worlds.ExitCode -eq 0)
}

function Find-MobileFolder {
    try {
        $device = Get-SelectedDevice
        Set-Status 'Поиск папки сохранений Terraria на телефоне…'
        Add-Log 'Автопоиск каталогов Terraria на телефоне…'

        $packagesResult = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'pm', 'list', 'packages')
        $packages = @()
        if ($packagesResult.ExitCode -eq 0) {
            $packages = @($packagesResult.Output -split "`r?`n" | ForEach-Object {
                if ($_ -match '^package:(.+)$') { $Matches[1] }
            } | Where-Object { $_ -match '(?i)terraria' })
        }
        $packages += @('com.and.games505.TerrariaPaid', 'com.and.games505.Terraria')
        $packages = @($packages | Select-Object -Unique)

        foreach ($package in $packages) {
            foreach ($suffix in @('', '/files')) {
                $root = "/sdcard/Android/data/$package$suffix"
                if (Test-MobileFolder -Serial $device.Serial -Root $root) {
                    $script:MobilePathBox.Text = $root
                    Set-Status "Папка Terraria найдена: $root"
                    Add-Log "Найдена папка на телефоне: $root"
                    return
                }
            }
        }

        Set-Status 'Папка не найдена автоматически. Укажите путь вручную.'
        Add-Log 'Автопоиск не нашел Players/Worlds. Введите Android-путь вручную.'
        [System.Windows.Forms.MessageBox]::Show(
            "Автопоиск не смог обнаружить папки Players и Worlds.`r`n`r`n" +
            "Укажите путь к каталогу вручную. Например:`r`n/sdcard/Android/data/com.and.games505.TerrariaPaid`r`n`r`n" +
            "Если ADB выдаёт Permission denied, доступ к Android/data блокируется системой Android (Android 11+).",
            'Terraria Sync — Поиск папки',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Set-Status 'Не удалось выполнить поиск папки на телефоне.'
        Add-Log "Ошибка поиска: $($_.Exception.Message)"
    }
}

function Get-SaveFiles {
    param([string]$Folder, [ValidateSet('Players', 'Worlds')][string]$Kind)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return @()
    }

    if ($Kind -eq 'Players') {
        $playerPattern = '(?i)^[^\\/]+\.plr(\.bak\d*)?$'
        $mapPattern = '(?i)\.map(\.bak\d*)?$'
    }
    else {
        $pattern = '(?i)\.(wld|twld)(\.bak\d*)?$'
    }

    $rootPrefix = $Folder.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $files = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction Stop)
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($rootPrefix.Length)
        $isSaveFile = if ($Kind -eq 'Players') {
            ($relativePath -match $playerPattern) -or ($relativePath -match $mapPattern)
        }
        else {
            $relativePath -match $pattern
        }
        if ($isSaveFile) {
            [void]$selected.Add([pscustomobject]@{
                Name         = $file.Name
                FullName     = $file.FullName
                RelativePath = $relativePath
            })
        }
    }
    $selected.ToArray()
}

function Get-RemoteSaveNames {
    param([string]$Serial, [string]$Folder, [ValidateSet('Players', 'Worlds')][string]$Kind)

    $exists = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'test', '-d', $Folder)
    if ($exists.ExitCode -ne 0) { return @() }
    $result = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'find', $Folder, '-type', 'f')
    if ($result.ExitCode -ne 0) {
        throw "Не удалось прочитать папку $Folder на телефоне. $($result.Output)"
    }

    $prefix = $Folder.TrimEnd('/') + '/'
    $relativePaths = @($result.Output -split "`r?`n" | ForEach-Object {
        if ($_.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $_.Substring($prefix.Length)
        }
    } | Where-Object { $_ })

    if ($Kind -eq 'Players') {
        $playerPattern = '(?i)^[^/]+\.plr(\.bak\d*)?$'
        $mapPattern = '(?i)\.map(\.bak\d*)?$'
        @($relativePaths | Where-Object { ($_ -match $playerPattern) -or ($_ -match $mapPattern) })
    }
    else {
        $pattern = '(?i)\.(wld|twld)(\.bak\d*)?$'
        @($relativePaths | Where-Object { $_ -match $pattern })
    }
}

function New-BackupDirectory {
    param([string]$Direction)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $path = Join-Path $script:RootFolder "Backups\${stamp}_$Direction"
    New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    $path
}

# ==============================================================================
# Transfer Logic (PC <-> Android)
# ==============================================================================
function Invoke-Transfer {
    param([ValidateSet('PhoneToPC', 'PCToPhone')][string]$Direction)

    # Safety check: Is Terraria running on PC?
    $runningTerraria = Get-Process -Name 'Terraria' -ErrorAction SilentlyContinue
    if ($runningTerraria) {
        $warnChoice = [System.Windows.Forms.MessageBox]::Show(
            "Внимание! Обнаружен запущенный процесс Terraria на компьютере.`r`n`r`nЧтобы избежать повреждения или перезаписи сохранений игрой, рекомендуется закрыть Terraria перед синхронизацией.`r`n`r`nВы хотите всё равно продолжить?",
            'Terraria Sync — Внимание',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($warnChoice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $script:SyncFromPhoneButton.Enabled = $false
    $script:SyncToPhoneButton.Enabled = $false
    $script:ProgressBar.Value = 0

    try {
        $device = Get-SelectedDevice
        $pcRoot = $script:PcPathBox.Text.Trim()
        $mobileRoot = $script:MobilePathBox.Text.Trim().TrimEnd('/')

        if (-not $pcRoot) {
            throw 'Укажите папку Terraria на компьютере.'
        }
        if ($Direction -eq 'PCToPhone' -and -not (Test-Path -LiteralPath $pcRoot -PathType Container)) {
            throw 'Папка Terraria на компьютере не найдена. Проверьте путь или выберите существующую папку.'
        }
        if (-not $mobileRoot.StartsWith('/')) {
            throw 'Укажите полный путь Android, начинающийся с /.'
        }
        if (-not (Test-MobileFolder -Serial $device.Serial -Root $mobileRoot)) {
            throw 'В указанной папке телефона не найдены Players или Worlds. Нажмите «Найти папку» и проверьте путь.'
        }

        $directionText = if ($Direction -eq 'PCToPhone') { 'с компьютера на телефон' } else { 'с телефона на компьютер' }
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Перед копированием полностью закройте Terraria на телефоне и на ПК.`r`n`r`nПродолжить копирование: $directionText?`r`n`r`nПрограмма автоматически создаст резервные копии всех файлов перед их переносом или заменой.",
            'Подтвердите синхронизацию',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $backupRoot = New-BackupDirectory -Direction $Direction
        $sourceBackupRoot = Join-Path $backupRoot 'Source'
        $destinationBackupRoot = Join-Path $backupRoot 'DestinationBefore'
        $localFilesByKind = @{}
        $remoteNamesByKind = @{}
        $sourceBackupCount = 0

        Set-Status 'Подготовка резервной копии исходных сохранений…'
        Add-Log "=== Начало синхронизации: $directionText ==="
        Add-Log "Каталог резервной копии: $backupRoot"

        # Count total items for progress reporting
        $totalFiles = 0
        foreach ($kind in @('Players', 'Worlds')) {
            $localFolder = Join-Path $pcRoot $kind
            $remoteFolder = "$mobileRoot/$kind"
            if ($Direction -eq 'PCToPhone') {
                $localFiles = if (Test-Path -LiteralPath $localFolder -PathType Container) {
                    @(Get-SaveFiles -Folder $localFolder -Kind $kind)
                } else { @() }
                $localFilesByKind[$kind] = $localFiles
                $remoteNamesByKind[$kind] = @(Get-RemoteSaveNames -Serial $device.Serial -Folder $remoteFolder -Kind $kind)
                $totalFiles += $localFiles.Count

                foreach ($file in $localFiles) {
                    $sourceFolder = Join-Path $sourceBackupRoot $kind
                    $sourceBackupFile = Join-Path $sourceFolder $file.RelativePath
                    $sourceBackupParent = Split-Path -Parent $sourceBackupFile
                    New-Item -ItemType Directory -Path $sourceBackupParent -Force -ErrorAction Stop | Out-Null
                    Copy-Item -LiteralPath $file.FullName -Destination $sourceBackupFile -Force -ErrorAction Stop
                    $sourceBackupCount++
                }
            }
            else {
                $remoteNames = @(Get-RemoteSaveNames -Serial $device.Serial -Folder $remoteFolder -Kind $kind)
                $remoteNamesByKind[$kind] = $remoteNames
                $totalFiles += $remoteNames.Count

                foreach ($name in $remoteNames) {
                    $sourceFolder = Join-Path $sourceBackupRoot $kind
                    $sourceBackupFile = Join-Path $sourceFolder ($name -replace '/', '\')
                    $sourceBackupParent = Split-Path -Parent $sourceBackupFile
                    New-Item -ItemType Directory -Path $sourceBackupParent -Force -ErrorAction Stop | Out-Null
                    $sourceCopy = Invoke-Adb -Arguments @('-s', $device.Serial, 'pull', "$remoteFolder/$name", $sourceBackupFile)
                    if ($sourceCopy.ExitCode -ne 0) {
                        throw "Не удалось создать исходную резервную копию $name. Перенос не начат. $($sourceCopy.Output)"
                    }
                    $sourceBackupCount++
                }
            }
        }

        if (-not (Test-Path -LiteralPath $pcRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $pcRoot -Force | Out-Null
        }
        Add-Log "Создана резервная копия исходных файлов ($sourceBackupCount шт.)."

        $copied = 0
        foreach ($kind in @('Players', 'Worlds')) {
            $localFolder = Join-Path $pcRoot $kind
            $remoteFolder = "$mobileRoot/$kind"
            $backupFolder = Join-Path (Join-Path $destinationBackupRoot $kind) 'Replaced'

            if ($Direction -eq 'PCToPhone') {
                $localFiles = @($localFilesByKind[$kind])
                if ($localFiles.Count -eq 0) { continue }

                $remoteNames = @($remoteNamesByKind[$kind])
                $mkdir = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'mkdir', '-p', "$mobileRoot/Players", "$mobileRoot/Worlds")
                if ($mkdir.ExitCode -ne 0) { throw "Не удалось создать папки на телефоне. $($mkdir.Output)" }

                foreach ($file in $localFiles) {
                    $relativeRemotePath = $file.RelativePath.Replace('\', '/')
                    $remoteFilePath = "$remoteFolder/$relativeRemotePath"
                    $copied++
                    Set-Progress -Current $copied -Total $totalFiles -Message "Копирую на телефон: $($file.RelativePath)"
                    Add-Log "-> Отправка на телефон: $($file.RelativePath)"

                    if ($remoteNames -contains $relativeRemotePath) {
                        $backupFile = Join-Path $backupFolder $file.RelativePath
                        $backupParent = Split-Path -Parent $backupFile
                        New-Item -ItemType Directory -Path $backupParent -Force -ErrorAction Stop | Out-Null
                        $backup = Invoke-Adb -Arguments @('-s', $device.Serial, 'pull', $remoteFilePath, $backupFile)
                        if ($backup.ExitCode -ne 0) { throw "Не удалось сохранить резервную копию $($file.RelativePath). $($backup.Output)" }
                    }
                    $remoteParent = $remoteFilePath.Substring(0, $remoteFilePath.LastIndexOf('/'))
                    $mkdir = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'mkdir', '-p', $remoteParent)
                    if ($mkdir.ExitCode -ne 0) { throw "Не удалось подготовить папку для $($file.RelativePath). $($mkdir.Output)" }
                    $push = Invoke-Adb -Arguments @('-s', $device.Serial, 'push', $file.FullName, $remoteFilePath)
                    if ($push.ExitCode -ne 0) { throw "Не удалось отправить $($file.RelativePath). $($push.Output)" }
                }
            }
            else {
                $remoteNames = @($remoteNamesByKind[$kind])
                if ($remoteNames.Count -eq 0) { continue }
                New-Item -ItemType Directory -Path $localFolder -Force | Out-Null
                foreach ($name in $remoteNames) {
                    $localPath = Join-Path $localFolder ($name -replace '/', '\')
                    $localParent = Split-Path -Parent $localPath
                    New-Item -ItemType Directory -Path $localParent -Force -ErrorAction Stop | Out-Null
                    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                        $destinationBackupFile = Join-Path $backupFolder ($name -replace '/', '\')
                        $destinationBackupParent = Split-Path -Parent $destinationBackupFile
                        New-Item -ItemType Directory -Path $destinationBackupParent -Force -ErrorAction Stop | Out-Null
                        Copy-Item -LiteralPath $localPath -Destination $destinationBackupFile -Force -ErrorAction Stop
                    }
                    $copied++
                    Set-Progress -Current $copied -Total $totalFiles -Message "Копирую на ПК: $name"
                    Add-Log "<- Скачивание на ПК: $name"

                    $pull = Invoke-Adb -Arguments @('-s', $device.Serial, 'pull', "$remoteFolder/$name", $localPath)
                    if ($pull.ExitCode -ne 0) { throw "Не удалось получить $name. $($pull.Output)" }
                }
            }
        }

        if ($copied -eq 0) {
            Set-Status 'Подходящих сохранений не найдено.'
            Add-Log 'Копирование не потребовалось: в выбранных папках нет сохранений персонажей или миров.'
        }
        else {
            $script:ProgressBar.Value = 100
            Set-Status "Готово! Успешно скопировано файлов: $copied."
            Add-Log "Синхронизация завершена успешно ($directionText). Файлов: $copied."
            Add-Log "Резервные копии сохранены в: $backupRoot"
            Update-PcStats
            [System.Windows.Forms.MessageBox]::Show(
                "Синхронизация успешно завершена!`r`n`r`nСкопировано файлов: $copied`r`n`r`nРезервные копии сохранены здесь:`r`n$backupRoot",
                'Синхронизация завершена',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        Set-Status 'Синхронизация остановлена из-за ошибки.'
        Add-Log "ОШИБКА: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Terraria Sync — Ошибка',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $script:SyncFromPhoneButton.Enabled = $true
        $script:SyncToPhoneButton.Enabled = $true
    }
}

# ==============================================================================
# UI Construction (Modern Dark Theme)
# ==============================================================================

# Palette Definition
$cBgMain       = [System.Drawing.Color]::FromArgb(21, 24, 31)
$cCardBg       = [System.Drawing.Color]::FromArgb(28, 33, 44)
$cCardBorder   = [System.Drawing.Color]::FromArgb(44, 52, 68)
$cInputBg      = [System.Drawing.Color]::FromArgb(15, 17, 24)
$cInputText    = [System.Drawing.Color]::FromArgb(240, 246, 252)
$cTextMuted    = [System.Drawing.Color]::FromArgb(139, 148, 158)
$cTextPrimary  = [System.Drawing.Color]::FromArgb(240, 246, 252)
$cAccentBlue   = [System.Drawing.Color]::FromArgb(88, 166, 255)
$cBtnBlue      = [System.Drawing.Color]::FromArgb(31, 111, 235)
$cBtnBlueHover = [System.Drawing.Color]::FromArgb(56, 139, 253)
$cBtnGreen     = [System.Drawing.Color]::FromArgb(35, 134, 54)
$cBtnGreenHover= [System.Drawing.Color]::FromArgb(46, 160, 67)
$cBtnDark      = [System.Drawing.Color]::FromArgb(42, 49, 64)
$cBtnDarkHover = [System.Drawing.Color]::FromArgb(56, 64, 82)

# Helper: Create Styled Button
function New-StyledButton {
    param(
        [string]$Text,
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$HoverColor,
        [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White,
        [System.Drawing.Font]$Font = $null,
        [System.Windows.Forms.AnchorStyles]$Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left)
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = $Location
    $btn.Size = $Size
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $BackColor
    $btn.ForeColor = $ForeColor
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Anchor = $Anchor
    if ($Font) { $btn.Font = $Font }
    else { $btn.Font = New-Object System.Drawing.Font('Segoe UI', 9) }

    $btn.Tag = @{ Normal = $BackColor; Hover = $HoverColor }
    $btn.Add_MouseEnter({
        if ($this.Enabled) { $this.BackColor = $this.Tag.Hover }
    })
    $btn.Add_MouseLeave({
        $this.BackColor = $this.Tag.Normal
    })
    $btn.Add_EnabledChanged({
        if ($this.Enabled) {
            $this.BackColor = $this.Tag.Normal
        } else {
            $this.BackColor = [System.Drawing.Color]::FromArgb(40, 44, 56)
        }
    })
    return $btn
}

# Helper: Create Styled Card Panel
function New-CardPanel {
    param(
        [System.Drawing.Point]$Location,
        [System.Drawing.Size]$Size,
        [System.Windows.Forms.AnchorStyles]$Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
    )
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = $Location
    $p.Size = $Size
    $p.BackColor = $cCardBg
    $p.Anchor = $Anchor
    $p.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $p.Add_Paint({
        param($sender, $e)
        $rect = [System.Drawing.Rectangle]::new(0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen = [System.Drawing.Pen]::new($cCardBorder, 1)
        $e.Graphics.DrawRectangle($pen, $rect)
        $pen.Dispose()
    })
    return $p
}

# --- Main Form ---
$script:MainForm = New-Object System.Windows.Forms.Form
$script:MainForm.Text = 'Terraria Sync — ПК & Android USB'
$script:MainForm.StartPosition = 'CenterScreen'
$script:MainForm.Size = New-Object System.Drawing.Size(900, 800)
$script:MainForm.MinimumSize = New-Object System.Drawing.Size(840, 740)
$script:MainForm.BackColor = $cBgMain
$script:MainForm.ForeColor = $cTextPrimary
$script:MainForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# Enable DoubleBuffering to eliminate flicker
$script:MainForm.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic').SetValue($script:MainForm, $true, $null)

# --- Top Header ---
$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = '🌲 Terraria Sync'
$headerTitle.Location = New-Object System.Drawing.Point(20, 14)
$headerTitle.Size = New-Object System.Drawing.Size(320, 32)
$headerTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$headerTitle.ForeColor = $cTextPrimary
$script:MainForm.Controls.Add($headerTitle)

$headerSubtitle = New-Object System.Windows.Forms.Label
$headerSubtitle.Text = 'Синхронизация сохранений (персонажи и миры) между ПК и телефоном через USB ADB'
$headerSubtitle.Location = New-Object System.Drawing.Point(22, 46)
$headerSubtitle.Size = New-Object System.Drawing.Size(540, 20)
$headerSubtitle.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$headerSubtitle.ForeColor = $cTextMuted
$script:MainForm.Controls.Add($headerSubtitle)

# Header Action Buttons (Right Aligned)
$btnHelp = New-StyledButton -Text '❓ Справка' `
    -Location (New-Object System.Drawing.Point(770, 20)) `
    -Size (New-Object System.Drawing.Size(90, 32)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnHelp.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Инструкция по настройке и использованию:`r`n`r`n" +
        "1. На телефоне: «Настройки» → «Для разработчиков» → включите «Отладка по USB».`r`n" +
        "2. Подключите телефон кабелем к ПК, разблокируйте экран и выберите «Всегда разрешать с этого компьютера».`r`n" +
        "3. В блоке телефона нажмите «Обновить», затем «Найти папку».`r`n" +
        "4. Обязательно закройте Terraria на телефоне и ПК перед переносом!`r`n" +
        "5. Выберите нужное направление переноса. Перед любым изменением автоматически создаётся резервная копия.`r`n`r`n" +
        "Пути по умолчанию:`r`n" +
        "• ПК: Документы\My Games\Terraria`r`n" +
        "• Телефон: /sdcard/Android/data/com.and.games505.TerrariaPaid",
        'Terraria Sync — Справка',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})
$script:MainForm.Controls.Add($btnHelp)

$btnOpenPc = New-StyledButton -Text '📂 Папка ПК' `
    -Location (New-Object System.Drawing.Point(670, 20)) `
    -Size (New-Object System.Drawing.Size(94, 32)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnOpenPc.Add_Click({
    $p = $script:PcPathBox.Text.Trim()
    if ($p -and (Test-Path -LiteralPath $p)) {
        Invoke-Item -LiteralPath $p
    } else {
        [System.Windows.Forms.MessageBox]::Show('Папка на компьютере ещё не существует.', 'Terraria Sync', 'OK', 'Warning') | Out-Null
    }
})
$script:MainForm.Controls.Add($btnOpenPc)

$btnOpenBackups = New-StyledButton -Text '📁 Бэкапы' `
    -Location (New-Object System.Drawing.Point(576, 20)) `
    -Size (New-Object System.Drawing.Size(88, 32)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnOpenBackups.Add_Click({
    $backupDir = Join-Path $script:RootFolder 'Backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    Invoke-Item -LiteralPath $backupDir
})
$script:MainForm.Controls.Add($btnOpenBackups)

# ==============================================================================
# CARD 1: PC Settings
# ==============================================================================
$cardPc = New-CardPanel -Location (New-Object System.Drawing.Point(20, 74)) -Size (New-Object System.Drawing.Size(844, 96))
$script:MainForm.Controls.Add($cardPc)

$pcTitle = New-Object System.Windows.Forms.Label
$pcTitle.Text = '💻 Папка Terraria на компьютере'
$pcTitle.Location = New-Object System.Drawing.Point(16, 10)
$pcTitle.Size = New-Object System.Drawing.Size(350, 20)
$pcTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$pcTitle.ForeColor = $cAccentBlue
$cardPc.Controls.Add($pcTitle)

$script:PcStatsLabel = New-Object System.Windows.Forms.Label
$script:PcStatsLabel.Text = 'Поиск сохранений…'
$script:PcStatsLabel.Location = New-Object System.Drawing.Point(400, 10)
$script:PcStatsLabel.Size = New-Object System.Drawing.Size(428, 20)
$script:PcStatsLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:PcStatsLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$script:PcStatsLabel.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$cardPc.Controls.Add($script:PcStatsLabel)

$script:PcPathBox = New-Object System.Windows.Forms.TextBox
$script:PcPathBox.Location = New-Object System.Drawing.Point(16, 36)
$script:PcPathBox.Size = New-Object System.Drawing.Size(610, 26)
$script:PcPathBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:PcPathBox.BackColor = $cInputBg
$script:PcPathBox.ForeColor = $cInputText
$script:PcPathBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:PcPathBox.Text = Find-PcSaveFolder
$script:PcPathBox.Add_TextChanged({ Update-PcStats })
$cardPc.Controls.Add($script:PcPathBox)

$browsePc = New-StyledButton -Text 'Обзор…' `
    -Location (New-Object System.Drawing.Point(636, 35)) `
    -Size (New-Object System.Drawing.Size(94, 28)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$browsePc.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку Terraria на ПК, в которой лежат Players и Worlds'
    $dialog.SelectedPath = $script:PcPathBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:PcPathBox.Text = $dialog.SelectedPath
        Update-PcStats
    }
})
$cardPc.Controls.Add($browsePc)

$detectPc = New-StyledButton -Text 'Автопоиск' `
    -Location (New-Object System.Drawing.Point(736, 35)) `
    -Size (New-Object System.Drawing.Size(92, 28)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$detectPc.Add_Click({
    $script:PcPathBox.Text = Find-PcSaveFolder
    Update-PcStats
})
$cardPc.Controls.Add($detectPc)

$pcHint = New-Object System.Windows.Forms.Label
$pcHint.Text = 'Каталог должен содержать подпапки Players (файлы .plr) и Worlds (файлы .wld).'
$pcHint.Location = New-Object System.Drawing.Point(16, 68)
$pcHint.Size = New-Object System.Drawing.Size(650, 18)
$pcHint.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$pcHint.ForeColor = $cTextMuted
$cardPc.Controls.Add($pcHint)

# ==============================================================================
# CARD 2: Android USB Settings
# ==============================================================================
$cardMobile = New-CardPanel -Location (New-Object System.Drawing.Point(20, 178)) -Size (New-Object System.Drawing.Size(844, 134))
$script:MainForm.Controls.Add($cardMobile)

$mobileTitle = New-Object System.Windows.Forms.Label
$mobileTitle.Text = '📱 Телефон Android (USB Отладка)'
$mobileTitle.Location = New-Object System.Drawing.Point(16, 10)
$mobileTitle.Size = New-Object System.Drawing.Size(320, 20)
$mobileTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$mobileTitle.ForeColor = $cAccentBlue
$cardMobile.Controls.Add($mobileTitle)

$script:DeviceStatusLabel = New-Object System.Windows.Forms.Label
$script:DeviceStatusLabel.Text = 'Проверка устройств…'
$script:DeviceStatusLabel.Location = New-Object System.Drawing.Point(350, 10)
$script:DeviceStatusLabel.Size = New-Object System.Drawing.Size(478, 20)
$script:DeviceStatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:DeviceStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$script:DeviceStatusLabel.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$cardMobile.Controls.Add($script:DeviceStatusLabel)

# Device Picker Row
$script:DevicePicker = New-Object System.Windows.Forms.ComboBox
$script:DevicePicker.DropDownStyle = 'DropDownList'
$script:DevicePicker.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:DevicePicker.Location = New-Object System.Drawing.Point(16, 34)
$script:DevicePicker.Size = New-Object System.Drawing.Size(710, 26)
$script:DevicePicker.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:DevicePicker.BackColor = $cInputBg
$script:DevicePicker.ForeColor = $cInputText
$cardMobile.Controls.Add($script:DevicePicker)

$refreshButton = New-StyledButton -Text '🔄 Обновить' `
    -Location (New-Object System.Drawing.Point(734, 33)) `
    -Size (New-Object System.Drawing.Size(94, 28)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$refreshButton.Add_Click({ Refresh-Devices })
$cardMobile.Controls.Add($refreshButton)

# Android Path Row
$script:MobilePathBox = New-Object System.Windows.Forms.TextBox
$script:MobilePathBox.Location = New-Object System.Drawing.Point(16, 68)
$script:MobilePathBox.Size = New-Object System.Drawing.Size(710, 26)
$script:MobilePathBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:MobilePathBox.BackColor = $cInputBg
$script:MobilePathBox.ForeColor = $cInputText
$script:MobilePathBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:MobilePathBox.Text = '/sdcard/Android/data/com.and.games505.TerrariaPaid'
$cardMobile.Controls.Add($script:MobilePathBox)

$detectButton = New-StyledButton -Text '🔍 Найти папку' `
    -Location (New-Object System.Drawing.Point(734, 67)) `
    -Size (New-Object System.Drawing.Size(94, 28)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$detectButton.Add_Click({ Find-MobileFolder })
$cardMobile.Controls.Add($detectButton)

$mobileHint = New-Object System.Windows.Forms.Label
$mobileHint.Text = 'ADB обращается напрямую к файлам игры без root-прав. На телефоне должен быть включён режим отладки по USB.'
$mobileHint.Location = New-Object System.Drawing.Point(16, 102)
$mobileHint.Size = New-Object System.Drawing.Size(750, 18)
$mobileHint.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$mobileHint.ForeColor = $cTextMuted
$cardMobile.Controls.Add($mobileHint)

# ==============================================================================
# CARD 3: Actions & Progress
# ==============================================================================
$cardActions = New-CardPanel -Location (New-Object System.Drawing.Point(20, 320)) -Size (New-Object System.Drawing.Size(844, 134))
$script:MainForm.Controls.Add($cardActions)

$actionsTitle = New-Object System.Windows.Forms.Label
$actionsTitle.Text = '🚀 Синхронизация сохранений'
$actionsTitle.Location = New-Object System.Drawing.Point(16, 8)
$actionsTitle.Size = New-Object System.Drawing.Size(300, 20)
$actionsTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$actionsTitle.ForeColor = $cTextPrimary
$cardActions.Controls.Add($actionsTitle)

# Split width dynamically for 2 main action buttons
$btnWidth = [int](($cardActions.Width - 44) / 2)

$script:SyncToPhoneButton = New-StyledButton -Text '⬆️  Отправить на телефон   (ПК ➔ Android)' `
    -Location (New-Object System.Drawing.Point(16, 32)) `
    -Size (New-Object System.Drawing.Size($btnWidth, 44)) `
    -BackColor $cBtnGreen -HoverColor $cBtnGreenHover `
    -Font (New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold))
$script:SyncToPhoneButton.Add_Click({ Invoke-Transfer -Direction 'PCToPhone' })
$cardActions.Controls.Add($script:SyncToPhoneButton)

$script:SyncFromPhoneButton = New-StyledButton -Text '⬇️  Скачать на компьютер   (Android ➔ ПК)' `
    -Location (New-Object System.Drawing.Point(($btnWidth + 28), 32)) `
    -Size (New-Object System.Drawing.Size($btnWidth, 44)) `
    -BackColor $cBtnBlue -HoverColor $cBtnBlueHover `
    -Font (New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold))
$script:SyncFromPhoneButton.Add_Click({ Invoke-Transfer -Direction 'PhoneToPC' })
$cardActions.Controls.Add($script:SyncFromPhoneButton)

# Keep action buttons equally sized on resize
$cardActions.Add_Resize({
    $w = [int](($this.Width - 44) / 2)
    $script:SyncToPhoneButton.Width = $w
    $script:SyncFromPhoneButton.Left = $w + 28
    $script:SyncFromPhoneButton.Width = $w
})

# Progress Bar
$script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
$script:ProgressBar.Location = New-Object System.Drawing.Point(16, 84)
$script:ProgressBar.Size = New-Object System.Drawing.Size(812, 10)
$script:ProgressBar.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$cardActions.Controls.Add($script:ProgressBar)

# Status Label
$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Готов к работе. Подключите телефон и выберите направление переноса.'
$script:StatusLabel.Location = New-Object System.Drawing.Point(16, 102)
$script:StatusLabel.Size = New-Object System.Drawing.Size(812, 22)
$script:StatusLabel.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:StatusLabel.ForeColor = $cTextPrimary
$cardActions.Controls.Add($script:StatusLabel)

# ==============================================================================
# CARD 4: Log Window
# ==============================================================================
$cardLog = New-CardPanel -Location (New-Object System.Drawing.Point(20, 462)) `
    -Size (New-Object System.Drawing.Size(844, ($script:MainForm.ClientSize.Height - 462 - 16))) `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:MainForm.Controls.Add($cardLog)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = '📜 Журнал работы'
$logTitle.Location = New-Object System.Drawing.Point(16, 10)
$logTitle.Size = New-Object System.Drawing.Size(200, 20)
$logTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$logTitle.ForeColor = $cTextPrimary
$cardLog.Controls.Add($logTitle)

$btnCopyLog = New-StyledButton -Text '📋 Копировать лог' `
    -Location (New-Object System.Drawing.Point(686, 6)) `
    -Size (New-Object System.Drawing.Size(142, 24)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnCopyLog.Add_Click({
    if ($script:LogBox.Text) {
        [System.Windows.Forms.Clipboard]::SetText($script:LogBox.Text)
        Add-Log 'Журнал работы скопирован в буфер обмена.'
    }
})
$cardLog.Controls.Add($btnCopyLog)

$btnClearLog = New-StyledButton -Text '🧹 Очистить' `
    -Location (New-Object System.Drawing.Point(588, 6)) `
    -Size (New-Object System.Drawing.Size(92, 24)) `
    -BackColor $cBtnDark -HoverColor $cBtnDarkHover `
    -Anchor ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right)
$btnClearLog.Add_Click({
    $script:LogBox.Clear()
})
$cardLog.Controls.Add($btnClearLog)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(14, 34)
$script:LogBox.Size = New-Object System.Drawing.Size(814, ($cardLog.Height - 44))
$script:LogBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.BackColor = $cInputBg
$script:LogBox.ForeColor = [System.Drawing.Color]::FromArgb(201, 209, 217)
$script:LogBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$cardLog.Controls.Add($script:LogBox)

# ==============================================================================
# Initialization
# ==============================================================================
$script:MainForm.Add_Shown({
    Update-PcStats
    if ($script:AdbPath) {
        Add-Log "Используется ADB: $script:AdbPath"
    } else {
        Add-Log "ВНИМАНИЕ: adb.exe не найден автоматически! Укажите путь к platform-tools."
    }
    Refresh-Devices
})

[void]$script:MainForm.ShowDialog()
