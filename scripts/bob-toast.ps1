#requires -Version 7
# Send-BobToast — Windows 10/11 toast notification via raw WinRT.
# Zero install required. Dot-source this file, then call Send-BobToast.
#
# Usage:
#   . "$repo\scripts\bob-toast.ps1"
#   Send-BobToast -Title "Bob" -Body "Morning brief complete"
#
# AppId: PowerShell host AUMID — always registered on Windows, appears in Action Center.

function Send-BobToast {
  param(
    [string]$Title = 'Bob',
    [string]$Body  = '',
    [string]$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\powershell.exe'
  )

  try {
    [Windows.UI.Notifications.ToastNotificationManager,
     Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument,
     Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
  } catch {
    Write-Warning "Send-BobToast: WinRT not available — $($_.Exception.Message)"
    return
  }

  # Truncate body to keep toast readable
  $Body = if ($Body.Length -gt 250) { $Body.Substring(0, 247) + '...' } else { $Body }

  # Escape XML special chars
  function Escape-Xml([string]$s) {
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&apos;"
  }

  $xmlStr = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$(Escape-Xml $Title)</text>
      <text>$(Escape-Xml $Body)</text>
    </binding>
  </visual>
</toast>
"@

  try {
    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $xml.LoadXml($xmlStr)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
  } catch {
    Write-Warning "Send-BobToast: failed to show notification — $($_.Exception.Message)"
  }
}
