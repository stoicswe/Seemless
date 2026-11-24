# Creates the Seemless local account as an administrator. Run as SYSTEM by
# firstboot.cmd (SetupComplete), which on build 26300 runs before OOBE.
#
# Why not the answer file's <LocalAccounts>: on build 26300 OOBE created the
# account but ignored <Group>Administrators</Group> (the account had no local
# group membership at all; found by S2, confirmed in the guest 2026-11-23),
# so nothing could elevate. Creating the account here, in SYSTEM context,
# and adding it to the groups by SID (language-independent) is
# deterministic. unattend.xml then only hides OOBE's account pages and sets
# up auto-logon.
#
# The name and password come from the AutoLogon section of the payload
# disk's copy of the answer file (Windows' unattend encoding: base64 of
# UTF-16LE password + "Password"), so no second copy of the secret is needed.
# Not from Panther\unattend.xml: Setup rewrites the password values in its
# cached copy (seen on build 26300), so they no longer decode.
#
# Also registers a one-shot SYSTEM task that deletes the cached answer files
# at the first logon (after OOBE has used them). A FirstLogonCommand cannot
# do this reliably: it runs as the user, and Panther is admin-only.
param([Parameter(Mandatory)][string]$AnswerFile)

$ErrorActionPreference = 'Stop'

[xml]$xml = Get-Content -LiteralPath $AnswerFile -Raw
$ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
$autoLogon = (Select-Xml -Xml $xml -Namespace $ns -XPath "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']/u:AutoLogon").Node
if (-not $autoLogon) { throw "no AutoLogon section in $AnswerFile" }
$name = $autoLogon.Username
$encoded = [string]$autoLogon.Password.Value
try {
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
} catch {
    $decoded = ''
}
if (-not $decoded.EndsWith('Password')) {
    # Describe the value without revealing it.
    throw "AutoLogon password in $AnswerFile is not in the unattend encoding ($($encoded.Length) characters)"
}
$password = ConvertTo-SecureString $decoded.Substring(0, $decoded.Length - 'Password'.Length) -AsPlainText -Force

$user = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
if ($user) {
    Set-LocalUser -InputObject $user -Password $password -PasswordNeverExpires $true
    Enable-LocalUser -InputObject $user
} else {
    $user = New-LocalUser -Name $name -Password $password -PasswordNeverExpires -AccountNeverExpires `
        -Description 'Seemless user (made by the image build)'   # 48 characters at most
}

foreach ($sid in 'S-1-5-32-544', 'S-1-5-32-545') {   # Administrators, Users
    $group = Get-LocalGroup -SID $sid
    try {
        Add-LocalGroupMember -Group $group -Member $user
    } catch [Microsoft.PowerShell.Commands.MemberExistsException] { }
}

# Verify rather than trust: the original bug was a silent no-op.
$adminSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
$members = net localgroup ($adminSid.Translate([Security.Principal.NTAccount]).Value.Split('\')[-1])
if (-not ($members -contains $name)) { throw "$name is not in Administrators after adding it" }
Write-Output "account $name ready (Administrators, Users)"

# One-shot cleanup of the cached answer files at the first logon, as SYSTEM.
$del = 'del /f /q "%WINDIR%\Panther\unattend.xml" "%WINDIR%\Panther\unattend-original.xml" & schtasks /delete /tn "\Seemless\RemoveAnswerFile" /f'
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c $del"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskPath '\Seemless\' -TaskName 'RemoveAnswerFile' -Action $action -Trigger $trigger `
    -Principal $principal -Force | Out-Null
Write-Output 'registered \Seemless\RemoveAnswerFile'
