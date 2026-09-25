Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:AdbPath = Join-Path $script:ProjectRoot '.android-sdk\platform-tools\adb.exe'
$script:DeviceItems = @()

function Invoke-Adb {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not (Test-Path -LiteralPath $script:AdbPath)) {
        throw "Не найден adb.exe: $script:AdbPath"
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Android returns UTF-8 file names. Windows PowerShell can otherwise decode
        # native output using the console OEM code page and corrupt Cyrillic paths.
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
        throw 'Сначала подключите телефон и выберите его в списке.'
    }
    $script:DeviceItems[$script:DevicePicker.SelectedIndex]
}

function Set-Status {
    param([string]$Message)
    $script:StatusLabel.Text = $Message
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
            Set-Status "Телефон подключён: $($script:DeviceItems[0].Caption)"
            Add-Log "Найдено устройств: $($script:DeviceItems.Count)."
        }
        elseif ($blocked.Count -gt 0) {
            Set-Status "Разрешите USB debugging на телефоне, затем обновите список."
            Add-Log "Устройство найдено, но ещё не авторизовано: $($blocked -join ', ')."
        }
        else {
            Set-Status 'Телефон не найден. Подключите USB, включите USB debugging и нажмите «Обновить». '
            Add-Log 'ADB не видит подключённых устройств.'
        }
    }
    catch {
        Set-Status 'Не удалось проверить подключение.'
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
        Set-Status 'Ищу папку сохранений Terraria на телефоне…'
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
                    Add-Log "Автоматически найдена папка телефона: $root"
                    return
                }
            }
        }

        Set-Status 'Папка не найдена. Введите путь, который содержит Players и Worlds.'
        Add-Log 'Автопоиск не нашёл каталог Players/Worlds. У пиратской сборки может быть другой package ID или приватное хранилище.'
        [System.Windows.Forms.MessageBox]::Show(
            "Автопоиск не нашёл папки Players и Worlds.`r`n`r`nУкажите путь к каталогу, в котором находятся эти папки. Например:`r`n/sdcard/Android/data/com.and.games505.TerrariaPaid`r`n`r`nЕсли ADB получает Permission denied, доступ к Android/data ограничивает Android или прошивка телефона. Если сохранения лежат во внутренней приватной папке приложения, обычно нужен встроенный экспорт игры либо root.",
            'Terraria Sync', 'OK', 'Information') | Out-Null
    }
    catch {
        Set-Status 'Не удалось найти папку телефона.'
        Add-Log "Ошибка поиска: $($_.Exception.Message)"
    }
}

function Get-SaveFiles {
    param([string]$Folder, [ValidateSet('Players', 'Worlds')][string]$Kind)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return @()
    }

    if ($Kind -eq 'Players') {
        $playerPattern = '(?i)^[^\\/]+\.plr(\.bak)?$'
        $mapPattern = '(?i)\.map(\.bak)?$'
    }
    else {
        $pattern = '(?i)\.(wld|twld)(\.bak)?$'
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
        throw "Не удалось прочитать телефонную папку $Folder. $($result.Output)"
    }

    $prefix = $Folder.TrimEnd('/') + '/'
    $relativePaths = @($result.Output -split "`r?`n" | ForEach-Object {
        if ($_.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $_.Substring($prefix.Length)
        }
    } | Where-Object { $_ })

    if ($Kind -eq 'Players') {
        $playerPattern = '(?i)^[^/]+\.plr(\.bak)?$'
        $mapPattern = '(?i)\.map(\.bak)?$'
        @($relativePaths | Where-Object { ($_ -match $playerPattern) -or ($_ -match $mapPattern) })
    }
    else {
        $pattern = '(?i)\.(wld|twld)(\.bak)?$'
        @($relativePaths | Where-Object { $_ -match $pattern })
    }
}

function New-BackupDirectory {
    param([string]$Direction)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $path = Join-Path $PSScriptRoot "Backups\${stamp}_$Direction"
    New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    $path
}

function Invoke-Transfer {
    param([ValidateSet('PhoneToPC', 'PCToPhone')][string]$Direction)

    $script:SyncFromPhoneButton.Enabled = $false
    $script:SyncToPhoneButton.Enabled = $false
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
            throw 'В указанной папке телефона не найдены Players или Worlds. Нажмите «Найти папку» и проверьте путь. На этом телефоне сохранения могут лежать прямо в com.and.games505.TerrariaPaid, без /files.'
        }

        $directionText = if ($Direction -eq 'PCToPhone') { 'с компьютера на телефон' } else { 'с телефона на компьютер' }
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Перед копированием полностью закройте Terraria на телефоне и на ПК.`r`n`r`nПродолжить: $directionText?`r`n`r`nСначала программа сохранит копии отправляемых файлов, а перед заменой — копии файлов на устройстве назначения.",
            'Подтвердите синхронизацию', 'YesNo', 'Warning')
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $backupRoot = New-BackupDirectory -Direction $Direction
        $sourceBackupRoot = Join-Path $backupRoot 'Source'
        $destinationBackupRoot = Join-Path $backupRoot 'DestinationBefore'
        $localFilesByKind = @{}
        $remoteNamesByKind = @{}
        $sourceBackupCount = 0

        Set-Status 'Готовлю резервную копию исходных сохранений…'
        foreach ($kind in @('Players', 'Worlds')) {
            $localFolder = Join-Path $pcRoot $kind
            $remoteFolder = "$mobileRoot/$kind"
            if ($Direction -eq 'PCToPhone') {
                $localFiles = if (Test-Path -LiteralPath $localFolder -PathType Container) {
                    @(Get-SaveFiles -Folder $localFolder -Kind $kind)
                }
                else { @() }
                $localFilesByKind[$kind] = $localFiles
                $remoteNamesByKind[$kind] = @(Get-RemoteSaveNames -Serial $device.Serial -Folder $remoteFolder -Kind $kind)
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
        Add-Log "Создана исходная резервная копия файлов: $sourceBackupCount."
        $copied = 0
        foreach ($kind in @('Players', 'Worlds')) {
            $localFolder = Join-Path $pcRoot $kind
            $remoteFolder = "$mobileRoot/$kind"
            $backupFolder = Join-Path (Join-Path $destinationBackupRoot $kind) 'Replaced'

            if ($Direction -eq 'PCToPhone') {
                $localFiles = @($localFilesByKind[$kind])
                $remoteNames = @($remoteNamesByKind[$kind])
                if ($localFiles.Count -eq 0) { continue }

                $mkdir = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'mkdir', '-p', "$mobileRoot/Players", "$mobileRoot/Worlds")
                if ($mkdir.ExitCode -ne 0) { throw "Не удалось создать папки на телефоне. $($mkdir.Output)" }

                foreach ($file in $localFiles) {
                    $relativeRemotePath = $file.RelativePath.Replace('\', '/')
                    $remoteFilePath = "$remoteFolder/$relativeRemotePath"
                    Set-Status "Копирую на телефон: $($file.RelativePath)"
                    [System.Windows.Forms.Application]::DoEvents()
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
                    $copied++
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
                    Set-Status "Копирую на ПК: $name"
                    [System.Windows.Forms.Application]::DoEvents()
                    $pull = Invoke-Adb -Arguments @('-s', $device.Serial, 'pull', "$remoteFolder/$name", $localPath)
                    if ($pull.ExitCode -ne 0) { throw "Не удалось получить $name. $($pull.Output)" }
                    $copied++
                }
            }
        }

        if ($copied -eq 0) {
            Set-Status 'Подходящих сохранений не найдено.'
            Add-Log 'Копирование не потребовалось: в выбранных папках нет файлов персонажей или миров.'
        }
        else {
            Set-Status "Готово: скопировано файлов — $copied. Резервная копия: $backupRoot"
            Add-Log "Готово ($directionText): файлов $copied. Резервные копии: $backupRoot"
            [System.Windows.Forms.MessageBox]::Show(
                "Скопировано файлов: $copied.`r`n`r`nРезервные копии находятся здесь:`r`n$backupRoot",
                'Синхронизация завершена', 'OK', 'Information') | Out-Null
        }
    }
    catch {
        Set-Status 'Синхронизация остановлена.'
        Add-Log "Ошибка: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Terraria Sync — ошибка', 'OK', 'Error') | Out-Null
    }
    finally {
        $script:SyncFromPhoneButton.Enabled = $true
        $script:SyncToPhoneButton.Enabled = $true
    }
}

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
    $candidates[0]
}

$script:MainForm = New-Object System.Windows.Forms.Form
$script:MainForm.Text = 'Terraria Sync'
$script:MainForm.StartPosition = 'CenterScreen'
$script:MainForm.Size = New-Object System.Drawing.Size(850, 680)
$script:MainForm.MinimumSize = New-Object System.Drawing.Size(780, 650)
$script:MainForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$header = New-Object System.Windows.Forms.Label
$header.Text = 'Terraria Sync'
$header.Location = New-Object System.Drawing.Point(20, 16)
$header.Size = New-Object System.Drawing.Size(300, 32)
$header.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$script:MainForm.Controls.Add($header)

$intro = New-Object System.Windows.Forms.Label
$intro.Text = 'Перенос персонажей и миров между Terraria на ПК и Android через USB.'
$intro.Location = New-Object System.Drawing.Point(22, 52)
$intro.Size = New-Object System.Drawing.Size(760, 22)
$script:MainForm.Controls.Add($intro)

$pcLabel = New-Object System.Windows.Forms.Label
$pcLabel.Text = 'Папка Terraria на компьютере (внутри Players и Worlds):'
$pcLabel.Location = New-Object System.Drawing.Point(22, 88)
$pcLabel.Size = New-Object System.Drawing.Size(600, 20)
$script:MainForm.Controls.Add($pcLabel)

$script:PcPathBox = New-Object System.Windows.Forms.TextBox
$script:PcPathBox.Location = New-Object System.Drawing.Point(22, 111)
$script:PcPathBox.Size = New-Object System.Drawing.Size(650, 26)
$script:PcPathBox.Anchor = 'Top,Left,Right'
$script:PcPathBox.Text = Find-PcSaveFolder
$script:MainForm.Controls.Add($script:PcPathBox)

$browsePc = New-Object System.Windows.Forms.Button
$browsePc.Text = 'Выбрать…'
$browsePc.Location = New-Object System.Drawing.Point(682, 109)
$browsePc.Size = New-Object System.Drawing.Size(130, 30)
$browsePc.Anchor = 'Top,Right'
$browsePc.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку Terraria, где находятся Players и Worlds'
    $dialog.SelectedPath = $script:PcPathBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:PcPathBox.Text = $dialog.SelectedPath }
})
$script:MainForm.Controls.Add($browsePc)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = 'Телефон (USB debugging должен быть включён):'
$deviceLabel.Location = New-Object System.Drawing.Point(22, 156)
$deviceLabel.Size = New-Object System.Drawing.Size(480, 20)
$script:MainForm.Controls.Add($deviceLabel)

$script:DevicePicker = New-Object System.Windows.Forms.ComboBox
$script:DevicePicker.DropDownStyle = 'DropDownList'
$script:DevicePicker.Location = New-Object System.Drawing.Point(22, 179)
$script:DevicePicker.Size = New-Object System.Drawing.Size(545, 27)
$script:DevicePicker.Anchor = 'Top,Left,Right'
$script:MainForm.Controls.Add($script:DevicePicker)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Обновить'
$refreshButton.Location = New-Object System.Drawing.Point(577, 177)
$refreshButton.Size = New-Object System.Drawing.Size(105, 30)
$refreshButton.Anchor = 'Top,Right'
$refreshButton.Add_Click({ Refresh-Devices })
$script:MainForm.Controls.Add($refreshButton)

$detectButton = New-Object System.Windows.Forms.Button
$detectButton.Text = 'Найти папку'
$detectButton.Location = New-Object System.Drawing.Point(692, 177)
$detectButton.Size = New-Object System.Drawing.Size(120, 30)
$detectButton.Anchor = 'Top,Right'
$detectButton.Add_Click({ Find-MobileFolder })
$script:MainForm.Controls.Add($detectButton)

$mobileLabel = New-Object System.Windows.Forms.Label
$mobileLabel.Text = 'Папка сохранений на телефоне (каталог с Players и Worlds):'
$mobileLabel.Location = New-Object System.Drawing.Point(22, 222)
$mobileLabel.Size = New-Object System.Drawing.Size(670, 20)
$script:MainForm.Controls.Add($mobileLabel)

$script:MobilePathBox = New-Object System.Windows.Forms.TextBox
$script:MobilePathBox.Location = New-Object System.Drawing.Point(22, 245)
$script:MobilePathBox.Size = New-Object System.Drawing.Size(790, 26)
$script:MobilePathBox.Anchor = 'Top,Left,Right'
$script:MobilePathBox.Text = '/sdcard/Android/data/com.and.games505.TerrariaPaid'
$script:MainForm.Controls.Add($script:MobilePathBox)

$help = New-Object System.Windows.Forms.Label
$help.Text = 'ADB копирует прямо в папку Terraria, даже если файловый менеджер её не открывает. Перед копированием закройте игру на обоих устройствах. Резервные копии создаются автоматически.'
$help.Location = New-Object System.Drawing.Point(22, 279)
$help.Size = New-Object System.Drawing.Size(790, 40)
$help.Anchor = 'Top,Left,Right'
$script:MainForm.Controls.Add($help)

$script:SyncToPhoneButton = New-Object System.Windows.Forms.Button
$script:SyncToPhoneButton.Text = 'Отправить на телефон  (ПК → Android)'
$script:SyncToPhoneButton.Location = New-Object System.Drawing.Point(22, 326)
$script:SyncToPhoneButton.Size = New-Object System.Drawing.Size(380, 42)
$script:SyncToPhoneButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:SyncToPhoneButton.Add_Click({ Invoke-Transfer -Direction 'PCToPhone' })
$script:MainForm.Controls.Add($script:SyncToPhoneButton)

$script:SyncFromPhoneButton = New-Object System.Windows.Forms.Button
$script:SyncFromPhoneButton.Text = 'Скачать на компьютер  (Android → ПК)'
$script:SyncFromPhoneButton.Location = New-Object System.Drawing.Point(422, 326)
$script:SyncFromPhoneButton.Size = New-Object System.Drawing.Size(390, 42)
$script:SyncFromPhoneButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:SyncFromPhoneButton.Add_Click({ Invoke-Transfer -Direction 'PhoneToPC' })
$script:MainForm.Controls.Add($script:SyncFromPhoneButton)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Подключите телефон, разблокируйте его и подтвердите запрос USB debugging.'
$script:StatusLabel.Location = New-Object System.Drawing.Point(22, 380)
$script:StatusLabel.Size = New-Object System.Drawing.Size(790, 24)
$script:StatusLabel.Anchor = 'Top,Left,Right'
$script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$script:MainForm.Controls.Add($script:StatusLabel)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(22, 409)
$script:LogBox.Size = New-Object System.Drawing.Size(790, 185)
$script:LogBox.Anchor = 'Top,Bottom,Left,Right'
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:MainForm.Controls.Add($script:LogBox)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = 'Примечание: версии Terraria на телефоне и ПК должны быть совместимы. Синхронизация копирует файлы сохранений, но не конвертирует их.'
$footer.Location = New-Object System.Drawing.Point(22, 610)
$footer.Size = New-Object System.Drawing.Size(790, 24)
$footer.Anchor = 'Bottom,Left,Right'
$footer.ForeColor = [System.Drawing.Color]::DimGray
$script:MainForm.Controls.Add($footer)

$script:MainForm.Add_Shown({ Refresh-Devices })
[void]$script:MainForm.ShowDialog()
