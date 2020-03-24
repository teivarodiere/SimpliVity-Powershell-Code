# This script currently provides backup report for SimpliVity backup engines.
#Version : 0.3
#Updated : 24 March 2020
#Author  : teiva rodiere
#More info: Adapted from https://github.com/herseyc/SVT/blob/master/SVT-DailyBackupReport.ps1
# Example:
# ./<scriptname.ps1> -OvcIP  10.10.10.10 -Credentials (Import-Clixml .\OVCcred.XML)
# ./<scriptname.ps1> -OvcIP  10.10.10.10 -Credentials (Get-Credential -Username administrator@vsphere.local -Message "Enter the password")
# .\simplivity-backup-checks.ps1 -OvcIP 10.10.10.10 -Credentials (Import-Clixml .\OVCcred.XML) -hours 72 -VMName MYVMNAME
<#


Feature Requests:
- SHow actual capacity (not logical) breakdown for VM Data, Loack Backups, and Remote Backups
- Show Per VM actual on disk consumption
- Show VM Primary and Secondary Copies - Use Get-SVTvmReplicaSet -Hostname or -VMname, or without any parameters show show everything
- Show in the backup list, which server hosts the Unique Data (Local Backups and Remote Backups)
    For example:
        VM1 Backup Day 1 has 100GB of Unique Blocks Locally on ESX 1 and ESX 3, and the remote copy on REMOTEESX2 and REMOTEESX3

#>
param(
	[Parameter(Mandatory=$false)][string]$logDir=".$([IO.Path]::DirectorySeparatorChar)output",
	[Parameter(Mandatory=$false)][string]$comment="",
	[Parameter(Mandatory=$false)][bool]$showDate=$false,
	[Parameter(Mandatory=$false)][ValidateRange(1, 5)][int]$headerType=1,
	[Parameter(Mandatory=$false)][bool]$showKeys=$false,
    [Parameter(Mandatory=$false)][bool]$returnResults=$true,
    [Parameter(Mandatory=$true)][string]$OvcIP,
    [Parameter(Mandatory=$true)][PSCredential]$Credentials,
    [parameter(Mandatory=$true)][Int]$hours, # [ValidateRange(0,)] #
    [Parameter(Mandatory=$false)][bool]$showAllFields=$false,
    [Parameter(Mandatory=$false)][string]$sleepTime=5,
    [Parameter(Mandatory=$false)][bool]$skipCalculation=$false,
    [Parameter(Mandatory=$false)][string]$VMName
)

$htmlOutfile=".\backupreport.html"

function getSize($TotalKB,$unit,$val)
{

	$valInt = [int]($val -replace ',','')
	if ($TotalKB) { $unit="KB"; $val=$TotalKB}

	if ($unit -eq "B") { $bytes=$valInt}
	elseif ($unit -eq "KB") { $bytes=$valInt*1KB }
	elseif ($unit -eq "MB") { $bytes=$valInt*1MB }
	elseif ($unit -eq "GB") { $bytes=$valInt*1GB }
	elseif ($unit -eq "TB") { $bytes=$valInt*1TB }
	elseif ($unit -eq "GB") { $bytes=$valInt*1PB }

	If ($bytes -lt 1MB) # Format TotalKB to reflect:
    {
     $value = "{0:N} KB" -f $($bytes/1KB) # KiloBytes or,
    }
    If (($bytes -ge 1MB) -AND ($bytes -lt 1GB))
    {
     $value = "{0:N} MB" -f $($bytes/1MB) # MegaBytes or,
    }
    If (($bytes -ge 1GB) -AND ($bytes -lt 1TB))
     {
     $value = "{0:N} GB" -f $($bytes/1GB) # GigaBytes or,
    }
    If ($bytes -ge 1TB -and $bytes -lt 1PB)
    {
     $value = "{0:N} TB" -f $($bytes/1TB) # TeraBytes
    }
	If ($bytes -ge 1PB)
  	 {
		$value = "{0:N} PB" -f $($bytes/1PB) # TeraBytes
    }
	return $value
}

##### MAIN FUNCTION
Connect-SVT -OVC $OvcIP -Credential $Credentials

$metaInfo = @()
$metaInfo += "tableHeader=SimpliVity Backups for the last $LastPeriodInHrs $hourString"
$metaInfo += "introduction=The following table summarises the backup state for the last $LastPeriodInHrs$hourString."
$metaInfo += "chartable=false"
$metaInfo += "titleHeaderType=h$($headerType)"
$metaInfo += "displayTableOrientation=Table" # options are List or Table
####


##################################################################
# Use PowerShell and the SimpliVity REST API  to
# To Create a Report of Backups Taken in the Last 24 Hours
#
# Usage: SVT-DailyBackupReport.ps1
#
# http://www.vhersey.com/
#
##################################################################
if ($VMName)
{
    $htmlReport = "<HTML>`n<TITLE>HPE SimpliVity Daily Backup Report for $VMName</TITLE>`n"
} else {
    $htmlReport = "<HTML>`n<TITLE>HPE SimpliVity Daily Backup Report</TITLE>`n"
}

$htmlReport += "<style type=""text/css"">
<!--
body {
	font-family: Verdana, Geneva, Arial, Helvetica, sans-serif;
}

#report { width: 835px; }
.red td{
	background-color: red;
}
.yellow  td{
	background-color: yellow;
}
.green td{
	background-color: green;
}
table{
   border-collapse: collapse;
   border: 1px solid #cccccc;
   font: 10pt Verdana, Geneva, Arial, Helvetica, sans-serif;
   color: black;
   margin-bottom: 10px;
   margin-left: 20px;
   width: auto;
}
table td{
       font-size: 12px;
       padding-left: 0px;
       padding-right: 20px;
       text-align: left;
	   width: auto;
	   border: 1px solid #cccccc;
}
table th {
       font-size: 12px;
       font-weight: bold;
       padding-left: 0px;
       padding-right: 20px;
       text-align: left;
	   border: 1px solid #cccccc;
	   width: auto;
	   border: 1px solid #cccccc;
}

h1{
	clear: both;
	font-size: 160%;
}

h2{
	clear: both;
	font-size: 130%;
}

h3{
   clear: both;
   font-size: 120%;
   margin-left: 20px;
   margin-top: 30px;
   font-style: italic;
}

h3{
   clear: both;
   font-size: 100%;
   margin-left: 20px;
   margin-top: 30px;
   font-style: italic;
}

p{ margin-left: 20px; font-size: 12px; }

ul li {
	font-size: 12px;
}

table.list{ float: left; }

table.list td:nth-child(1){
       font-weight: bold;
       border-right: 1px grey solid;
       text-align: right;
}

table.list td:nth-child(2){ padding-left: 7px; }
table tr:nth-child(even) td:nth-child(even){ background: #CCCCCC; }
table tr:nth-child(odd) td:nth-child(odd){ background: #F2F2F2; }
table tr:nth-child(even) td:nth-child(odd){ background: #DDDDDD; }
table tr:nth-child(odd) td:nth-child(even){ background: #E5E5E5; }

div.column { width: 320px; float: left; }
div.first{ padding-right: 20px; border-right: 1px  grey solid; }
div.second{ margin-left: 30px; }
	-->
    </style>
    <BODY>`n<h1>HPE SimpliVity Daily Backup Report $(get-date)</h1>`n"


Write-Host "--> Exporting a host Capacity information"
$htmlReport += "`n<h2>Federation OmniStack Hosts</h2><p>The table below presents of OmniStakc Controller VMs in the federation. This list was provided by OVC <i>$OvcIP</i>.</p>"
$hostReport = @()
Get-SVThost | Sort-Object ClusterName,Hostname | %{
    $svthost = $_
    $row = New-Object System.Object
    $row | Add-Member -MemberType NoteProperty -Name "vSphere Host" -Value $svthost.Hostname
    $row | Add-Member -MemberType NoteProperty -Name "Cluster" -Value $svthost.Clustername
    $row | Add-Member -MemberType NoteProperty -Name "OVC IP" -Value $svthost.ManagementIP
    $row | Add-Member -MemberType NoteProperty -Name "OVC Version" -Value $svthost.Version

    $perc = $($($svthost.FreeSpaceGB -replace ',','') * 1) / $($($svthost.AllocatedCapacityGB -replace ',','') * 1) * 100
    $row | Add-Member -MemberType NoteProperty -Name "Actual Node Capacity" -Value (getSize -unit "GB" -Val $svthost.AllocatedCapacityGB)
    $row | Add-Member -MemberType NoteProperty -Name "Actual Used Capacity" -Value (getSize -unit "GB" -Val $svthost.UsedCapacityGB)
    $row | Add-Member -MemberType NoteProperty -Name "Actual Free Capacity" -Value "$((getSize -unit GB -Val $svthost.FreeSpaceGB)) ($(([math]::round($perc,2)))%)"

    # Logical Capacity
    $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - Total" -Value (getSize -unit "GB" -Val $svthost.UsedLogicalCapacityGB)
    $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by VM Data" -Value (getSize -unit "GB" -Val $svthost.StoredVMdataGB)
    $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by Local Backups" -Value (getSize -unit "GB" -Val $svthost.LocalBackupCapacityGB)
    $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by Remote Backups" -Value (getSize -unit "GB" -Val $svthost.RemoteBackupCapacityGB)

    $hostReport += $row
}
if ($hostReport)
{
    $htmlReport +=  ($hostReport | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""aITTablesytle"""  -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
    $htmlReport += "`n"
    $hostReport | Export-csv -NoTypeInformation ".\hosts_capacity.csv"
} else {
    $htmlReport +=  "An error has occured and cannot export capacity information for any federation simplivity OVCs."
}


Write-Host "-> Collect backup data"
if ($VMName)
{
    $allbackups = Get-SVTbackup -Hour $hours -VMname $VMName
} else {
    $allbackups = Get-SVTbackup -Hour $hours
}


Write-Host "Exporting a list of non ACTIVE and FAILED backups"
if ($VMname)
{
    $htmlReport += "`n<h2>Incomplete or Failed Backups for $VMName for the past $hours hours</h2><p>The table below presents a list of incomplete and failed backups for the past $hours hours for virtual machine <i>$VMName</i>. The list is ordered from the most recent to oldest.</p>"
} else {
    $htmlReport += "`n<h2>All Incomplete or Failed Backups for the past $hours hours</h2><p>The table below presents a list of incomplete and failed backups for the past $hours hours for all virtual machines found in the federation. The list is ordered from the most recent to oldest.</p>"
}
# Enumerate NONE protected backups (Active or failures)
$nonProtectedBackups = $allbackups | Where-Object {$_.BackupState -ne "PROTECTED"}
$nonProtectedBackups | Export-csv -NoTypeInformation ".\backups_failed.csv"

if ($nonProtectedBackups)
{
    Write-Host "-> $(($nonProtectedBackups | measure-object).Count) found."
    $htmlReport += "<p> $($($nonProtectedBackups | measure-object).Count) found.</p>"
    $htmlReport += ($nonProtectedBackups | select-object @{n="Backup Taken On";e={$_.CreateDate}},@{n="Virtual Machine";e={$_.VMname}},@{n="Calculated Unique Size (GB)";e={getSize -unit "MB" -val $_.UniqueSizeMB}},@{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},@{n="Backup will expire on";e={$_.ExpiryDate}},@{n="Virtual Machine Size";e={getSize -unit "GB" -val $_.SizeGB}},@{n="Amt of Data Sent to Remote Site (GB)";e={getSize -unit "MB" -val $_.SentMB}},@{n="VM State During Backup";e={$_.VMState}},@{n="Backup Name";e={$_.BackupName}}  | sort-Object "Backup Taken On" -Descending  | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""aITTablesytle""" -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
    $htmlReport += "`n"
} else {
    $htmlReport += "<p><i>None found.</i></p>"
}
if ($VMname)
{
    $htmlReport += "`n<h2>Successful Backups for $VMName for the past $hours hours</h2><p>The table below presents a list of successful backups for the past $hours hours for virtual machine <i>$VMName</i>. The list is ordered from the most recent to oldest.</p>"
} else {
    $htmlReport += "`n<h2>All Successful Backups for the past $hours hours</h2><p>The table below presents a list of successful backups for the past $hours hours for all virtual machine in the federation. The list is ordered from the most recent to oldest.</p>"
} 

Write-Host "-> Collecting list of protected backups.."
$protectedBackups = $allbackups | Where-Object {$_.BackupState -eq "PROTECTED"}
Write-Host "-> Calculating Unique Data Sizes for backups"
if ($($protectedBackups | measure-object).Count -gt 0)
{
    if ($skipCalculation)
    {
        Write-Host "-> Skipping calculations"
    } else {
        $protectedBackups | Update-SVTbackupUniqueSize
    }
    Write-Host "-> Sleeping $sleepTime just in case.."
    sleep $sleepTime
    WRite-Host "-> Re-reading the backup lists with the updated Unique Size"

    if ($VMName)
    {
        $allbackups = (Get-SVTbackup -Hour $hours -VMname $VMName | Where-Object {$_.BackupState -eq "PROTECTED"})
    } else {
        $allbackups = (Get-SVTbackup -Hour $hours | Where-Object {$_.BackupState -eq "PROTECTED"})
    }
    $protectedBackupsRaw = $protectedBackups 
    $protectedBackupsRaw | Export-csv -NoTypeInformation ".\backups_successful_before.csv"
    $protectedBackups = $allbackups | select-object @{n="Backup Taken On";e={$_.CreateDate}},@{n="Virtual Machine";e={$_.VMname}},@{n="Calculated Unique Size";e={getSize -unit "MB" -val $_.UniqueSizeMB}},@{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},@{n="Backup will expire on";e={$_.ExpiryDate}},@{n="Virtual Machine Size";e={getSize -unit "GB" -val $_.SizeGB}},@{n="Amt of Data Sent to Remote Site (GB)";e={getSize -unit "MB" -val $_.SentMB}},@{n="VM State During Backup";e={$_.VMState}},@{n="Backup Name";e={$_.BackupName}}  | sort-Object "Backup Taken On" -Descending
    $protectedBackups | Export-csv -NoTypeInformation ".\backups_successful_Sanitised.csv"

    #select-object CreateDate,VMname,@{n="UniqueSizeGB As of Now";e={[math]::round($_.UniqueSizeMB/1024,2)}},@{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},ExpiryDate,SizeGB,SentMB,@{n="VMStateDuringBackup";e={$_.VMState}},BackupName | sort-Object CreateDate -Descending

    Write-Host "-> Getting VM information"
    $vms = @()
    $protectedBackups | Group-Object -Property "Virtual Machine" | ForEach-Object {
        Write-Host "." -NoNewline
        $vmObject = Get-SVTvm -VMname $_.Name
        if ($vmObject)
        {
            $vms += $vmObject
        }
    }

    # Adding VM inforamtion in the array for inclusion
    $protectedBackups | ForEach-Object {
        Write-Host "*" -NoNewline
        $vmName = $_."Virtual Machine"
        $matchingVM = $vms | Where-Object {$_.VMname -like $vmName}
        if ($matchingVM)
        {
            $_ | Add-Member -MemberType NoteProperty -Name "VM Location" -Value "$($matchingVM.DataCenterName)\$($matchingVM.ClusterName)\$($matchingVM.DataStoreName)"
            $_ | Add-Member -MemberType NoteProperty -Name "Policy Name" -Value "$($matchingVM.PolicyName)"

        } else {
            $_ | Add-Member -MemberType NoteProperty -Name "VM Location" -Value "Unknown"
            $_ | Add-Member -MemberType NoteProperty -Name "Policy Name" -Value "Unknown"

        }
    }
    
    # # Calculate extra capacity at each Sites    
    $capacityPerSite = ""
    $protectedBackupsRaw | Select-Object UniqueSizeMB,DestinationName | Group-Object DestinationName | ForEach-Object {
        $groupItem = $_
        $capacityAmt = getSize -unit "MB" -val (($groupItem.Group | measure-Object -Sum -Property 'UniqueSizeMB').Sum)
        $capacityPerSite += ", $capacityAmt more in $($groupItem.Name)"
    }

    $totalCapacity = getSize -unit "MB" -val (($protectedBackupsRaw | measure-Object -Sum -Property "UniqueSizeMB").Sum)
    $totalBackupCount = ($protectedBackupsRaw | measure-object).Count
    $totalVMCount = ($protectedBackupsRaw | Select-Object -Property 'VMName' -Unique | measure-object -Property 'VMName').Count
    $largestBackupString = ""
    $protectedBackupsRaw | group-object DestinationName | ForEach-Object {
        $groupItem = $_
        $largestBackup = $groupItem.Group | sort-object -Property UniqueSizeMB -Descending | select-Object -First 1
        $largestBackupSize = getSize -unit "MB" -val $largestBackup.UniqueSizeMB
        $largestBackupSite = $largestBackup.DestinationName
        $largestBackupVM = $largestBackup.VMName
        $largestBackupName = $largestBackup.BackupName
        $largestBackupString += "$largestBackupSize in $largestBackupSite for $largestBackupVM ($largestBackupName), "
    }
    
    $htmlReport += "`n<p>Summary: <ul><li>$totalBackupCount backups found</li><li>$totalVMCount VMs protected</li><li>$totalCapacity additional capacity was added overall$capacityPerSite</li><li>The largest backups during this period: $largestBackupString</li></ul></p>"

    $htmlReport +=  ($protectedBackups | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""aITTablesytle"""  -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
    $htmlReport += "`n"

} else {
    $htmlReport += "<p><i>None found.</i></p>"
}

$htmlReport += @"
</div></BODY>
"@

$htmlReport | Out-File $htmlOutfile

# Open the report
& $htmlOutfile
