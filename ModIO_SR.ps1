$updateMods = 0
$debug = 0
$clearCache = 0

# available args:
# -c or --clear-cache : clear cache
# -u or --update      : update mods
# -d or --debug       : show debug output
# -v or --version     : show version

# load environment variables
Get-Content .env | ForEach-Object {
    $name, $value = $_.split('=')
    $name = $name.Trim()
    $value = $value.Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('#')) {
        continue
    }
    Set-Content env:\$name $value
}

# check args
if ($args.Length -gt 0) {
    foreach ($arg in $args) {
        if ($arg -eq "-c" -or $arg -eq "--clear-cache") {
            $clearCache = 1
        }
        elseif ($arg -eq "-u" -or $arg -eq "--update") {
            $updateMods = 1
        }
        elseif ($arg -eq "-d" -or $arg -eq "--debug") {
            $debug = 1
        }
        elseif ($arg -eq "-v" -or $arg -eq "--version") {
            Write-Host "ModIO_SR.ps1 v1.2"
            exit 0
        }
        else {
            Write-Host "ERROR: Unknown argument: $arg"
            exit 1
        }
    }
}

# set debug preference
if ($debug -eq 1) { $DebugPreference = "Continue" }

# check if all environment variables are set

Write-Debug "Mods dir : $env:MODS_DIR"
Write-Debug "User profile : $env:USER_PROFILE"
Write-Debug "Access token : $($env:ACCESS_TOKEN.Substring(0, 10) + "..." + $env:ACCESS_TOKEN.Substring($env:ACCESS_TOKEN.Length - 10, 10))"

$envVars = $env:MODS_DIR, $env:USER_PROFILE, $env:ACCESS_TOKEN
if ($envVars -contains $null -or $envVars -contains '') {
    Write-Host "ERROR: AccessToken or UserProfile or ModsDir not set in .env file"
    exit 1
}

# check paths
if (-not (Test-Path env:USER_PROFILE)) {
    Write-Host "ERROR: UserProfile does not exist in given path"
    exit 1
}
if (-not (Test-Path env:MODS_DIR)) {
    Write-Host "ERROR: ModsDir does not exist in given path"
    exit 1
}

Set-Content env:CACHE_DIR "$env:MODS_DIR\..\cache"
Write-Debug "Cache dir : $env:CACHE_DIR"
# check if cache dir exists and create it if not
if (-not (Test-Path env:CACHE_DIR)) {
    Write-Debug "Creating cache dir..."
    New-Item -ItemType Directory -Path $env:CACHE_DIR | Out-Null
    Write-Debug "Done"
}

if ($clearCache -eq 1) {
    Write-Host "Clearing cache..."
    Remove-Item -LiteralPath $env:CACHE_DIR -Recurse -Confirm
    Write-Host "Done"
    exit 0
}

# load user profile
$UserProfile = Get-Content $env:USER_PROFILE
# if last character is not a } then remove it until it is
while ($UserProfileJson[-1] -ne "}") {
    $UserProfileJson = $UserProfileJson.Substring(0, $UserProfileJson.Length - 1)
}
$UserProfileJson = $UserProfileJson | ConvertFrom-Json

# check if userprofile is valid
if ($null -eq $UserProfileJson.UserProfile) {
    Write-Host "ERROR: UserProfile is not valid"
    exit 1
}

# get subscribed mods
Write-Host "Getting subscribed mods..."

$headers = @{
    "Authorization"    = "Bearer $env:ACCESS_TOKEN"
    "Accept"           = "application/json"
    "X-Modio-Platform" = "Windows"
}
$body = @{
    game_id = 306
}

$data = Invoke-RestMethod -Method Get -Uri "https://api.mod.io/v1/me/subscribed" -Headers $headers -Body $body

if ($data.result -eq "401") {
    Write-Host "ERROR: AccessToken is invalid"
    exit 1
}

Write-Debug $data
if ($DebugPreference -eq "Continue") { $data | ConvertTo-Json -Depth 100 | Out-File -FilePath "./data.json" }

$subscribedMods = @()

foreach ($mod in $data.data) {
    $modID = $mod.id
    $modName = $mod.name
    $modVersionDownload = $mod.modfile.version
    $modDir = "$env:MODS_DIR\$modID"
    $subscribedMods += @{
        id = $modID
    }
    if (Test-Path "$env:CACHE_DIR\$modID") {
        Write-Host "Mod with ID $modID found in cache, moving from cache to mods dir..."
        Move-Item -Path "$env:CACHE_DIR\$modID" -Destination $modDir
        Write-Host "Done"
        continue
    }
    $updateRequired = 0
    if (Test-Path $modDir) {
        $installedVersion = Get-Content "$modDir\modio.json" | ConvertFrom-Json | Select-Object -ExpandProperty modfile | Select-Object -ExpandProperty version
        if ($installedVersion -eq $modVersionDownload) {
            Write-Debug "Mod $modID is up to date"
            continue
        }
        elseif ($updateMods -ne 1) {
            Write-Host "Update available for mod $modID ($modName), use -u or --update to update"
            continue
        }
        else {
            $updateRequired = 1
        }
    }
    if ($updateRequired -eq 1) {
        Write-Host "Updating mod $modID ($modName)..."
        Remove-Item -LiteralPath $modDir -Recurse
    }
    else {
        Write-Host "Installing mod $modID ($modName)..."
    }

    if (-not (Test-Path $modDir)) {
        New-Item -ItemType Directory -Path $modDir | Out-Null
    }

    $resolutions = @('320x180', '640x360')
    foreach ($res in $resolutions) {
        $url = $mod.logo."thumb_$res"
        $logo_path = "$modDir\logo_$res.png"
        Invoke-WebRequest -Uri $url -Method Get -OutFile $logo_path
    }
    Write-Host "--> Downloading thumbs --> OK"

    Set-Content -Path "$modDir\modio.json" -Value ($mod | ConvertTo-Json -Depth 100)
    Write-Host "--> Creating modio.json --> OK"

    $modUrl = $mod.modfile.download.binary_url
    $modFileName = $mod.modfile.filename
    $modFullPath = "$modDir\$modFileName"
    Write-Host "--> Downloading mod"
    Invoke-WebRequest -Uri $modUrl -Method Get -Headers $headers -OutFile $modFullPath
    Write-Host "--> OK"

    Write-Host "--> Extracting mod $modID ($modName)..."
    Expand-Archive -Path $modFullPath -DestinationPath $modDir
    Remove-Item -Path $modFullPath
    Write-Host "--> OK"
}

# get previously installed mods
$modsInstalled = $UserProfileJson.userprofile.modDependencies.SslValue.dependencies

# check if mods are no longer subscribed
$modsInstalled | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {
    # if mod is no longer subscribed, move to cache
    if ($subscribedMods.id -notcontains $_) {
        Write-Host "Mod with ID $_ is no longer subscribed, moving to cache..."
        Move-Item -Path "$env:MODS_DIR\$_" -Destination "$env:CACHE_DIR"
        Write-Host "Done"
    }
}

# update installed mods
$modsInstalled = @{}
foreach ($mod in $subscribedMods) {
    $modsInstalled["$($mod.id)"] = @()
}
$UserProfileJson.userprofile.modDependencies.SslValue.dependencies = $modsInstalled
Write-Debug "Mods Installed: $(ConvertTo-Json $modsInstalled)"

# check if user profile has modStateList, if not create it
if ($null -eq $UserProfileJson.UserProfile.modStateList) {
    $UserProfileJson.UserProfile | Add-Member -MemberType NoteProperty -Name modStateList -Value @()
    Write-Debug "modStateList created"
}

# get current enabled mods
$currentStateList = $UserProfileJson.UserProfile.modStateList
$newStateList = @()

# get keys of $modsInstalled
$modIDs = @()
    foreach ($key in $modsInstalled.Keys) {
        $modIDs += $key
}

Write-Debug "ModIDs: $(ConvertTo-Json $modIDs -Depth 100)"

foreach ($mod in $modIDs) {
    Write-Debug "Checking mod $mod..."
    if ($currentStateList.modId -contains $mod) {
        $newStateList += @{
                modId    = [int]$mod
                modState = $true
            }
        }
    }

Write-Debug "Mod States:"
    Write-Debug (ConvertTo-Json $newStateList -Depth 100)
    $UserProfileJson.UserProfile.modStateList = $newStateList

Write-Host "Updating user profile..."
Set-Content -Path $env:USER_PROFILE -Value ($UserProfileJson | ConvertTo-Json -Depth 100)
Write-Host "Done"

Pause