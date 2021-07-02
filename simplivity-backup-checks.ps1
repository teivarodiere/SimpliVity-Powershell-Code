# This script currently provides backup report for SimpliVity backup engines.
#Version : 0.3
#Updated : 24 March 2020
#Author  : teiva rodiere
#More info: Adapted from https://github.com/herseyc/SVT/blob/master/SVT-DailyBackupReport.ps1
# Example:
# ./<scriptname.ps1> -OvcIP  10.10.10.10 -Credentials (Import-Clixml .\OVCcred.XML)
# ./<scriptname.ps1> -OvcIP  10.10.10.10 -Credentials (Get-Credential -Username administrator@vsphere.local -Message "Enter the password")
# .\simplivity-backup-checks.ps1 -OvcIP 10.10.10.10 -Credentials (Import-Clixml .\OVCcred.XML) -hours 72 -VMName MYVMNAME
# .\simplivity-backup-checks.ps1 -OvcIP 10.10.10.10 -Credentials (Import-Clixml .\OVCcred.XML) -hours 0 -VMName MYVMNAME - gets all of the backups for this VM
<#


Feature Requests:
- SHow actual capacity (not logical) breakdown for VM Data, Loack Backups, and Remote Backups
- Show Per VM actual on disk consumption
- Show VM Primary and Secondary Copies - Use Get-SVTvmReplicaSet -Hostname or -VMname, or without any parameters show show everything
- Show in the backup list, which server hosts the Unique Data (Local Backups and Remote Backups)
    For example:
        VM1 Backup Day 1 has 100GB of Unique Blocks Locally on ESX 1 and ESX 3, and the remote copy on REMOTEESX2 and REMOTEESX3
.\simplivity-backup-checks.ps1 -logDir output -OvcIP 172.16.200.220 -Credentials $MyCredential -exportBackupInformation $false -skipCalculation $true -hours 0 -niceFormat $true
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
    [parameter(Mandatory=$false)][Int]$hours=0, # [ValidateRange(0,)] # #0 = ALL backups, 1 = Backups for the past 1hr
    [Parameter(Mandatory=$false)][bool]$showAllFields=$false,
    [Parameter(Mandatory=$false)][string]$sleepTime=5,
    [Parameter(Mandatory=$false)][bool]$skipCalculation=$false,
    [Parameter(Mandatory=$false)][bool]$niceFormat=$false,
    [Parameter(Mandatory=$false)][string]$VMName,
    [Parameter(Mandatory=$false)][bool]$exportBackupInformation=$true,
    [Parameter(Mandatory=$false)][bool]$exportHostInformation=$true,
    [Parameter(Mandatory=$false)][bool]$exportVMInformation=$true,
    [Parameter(Mandatory=$false)][bool]$exportBackupsToVMSummary=$false,
    [Parameter(Mandatory=$false)][bool]$exportVMHostMapping=$true
)
function logThis (
	[Parameter(Mandatory=$true)][string]$msg,
	[Parameter(Mandatory=$false)][object]$ColourScheme, #takes $global:colour.xxxx as input
	[Parameter(Mandatory=$false)][string]$logFile,
	[Parameter(Mandatory=$false)][string]$ForegroundColor = $global:colours.Information.Foreground,
	[Parameter(Mandatory=$false)][string]$BackgroundColor = $global:colours.Information.Background,
	[Parameter(Mandatory=$false)][bool]$logToScreen = $false,
	[Parameter(Mandatory=$false)][bool]$NoNewline = $false,
	[Parameter(Mandatory=$false)][bool]$keepLogInMemoryAlso=$false,
	[Parameter(Mandatory=$false)][bool]$showDate=$true
	)
{
	# overwrite the $ForegroundColor and $BackgroundColor if schema was provided
	# the schema to pass should be $global:colours.Error or $global:colours.Information etcc...$global:colours is defined at the tope of this module
	if ($showDate)
	{
		$msg = "$(get-date -f 'dd-MM-yyyy HH:mm:ss') $msg"
	}
	if ($ColourScheme)
	{
		$ForegroundColor = $ColourScheme.Foreground
		$BackgroundColor = $ColourScheme.Background
	}
	if ($global:logToScreen -or $logToScreen -and !$global:silent)
	{
		# Also verbose to screent
		if ($NoNewline)
		{
			Write-host $msg -BackgroundColor $BackgroundColor -Foreground $ForegroundColor -NoNewline;
		} else {
			Write-host $msg -BackgroundColor $BackgroundColor - Foreground $ForegroundColor;
		}
	}

	if ($global:runtimeLogFile -and !$global:lastLogEntry)
	{
		Set-Variable -Name lastLogEntry -Value ($global:runtimeLogFile -replace '.log','-lastest.log') -Scope Global
	}
	if ($global:logTofile)
	{
		if ($global:logDir -and ((Test-Path -path $global:logDir) -ne $true))
		{
			New-Item -type directory -Path $global:logDir
			$childitem = Get-Item -Path $global:logDir
			$global:logDir = $childitem.FullName
		}
		if ($logFile)
		{
			if (Test-Path -Path $logFile)
			{
				"$msg`n"  | out-file -filepath $logFile -append
			} else {
				logThis -msg "Error while writing to $logFile`n"
			}
		}
		if ($global:runtimeLogFile -and (Test-Path -Path $global:runtimeLogFile))
		{
			"$msg`n" | out-file -filepath $global:runtimeLogFile -append
		}

		if ($global:lastLogEntry -and (Test-Path -Path $global:lastLogEntry))
		{
			"$msg`n" | out-file -filepath $global:lastLogEntry
		}
	}
	if ($global:logInMemory -or $keepLogInMemoryAlso)
	{
		$global:runtimeLogFileInMemory += "$msg`n"
	}
}
function SetmyLogFile([Parameter(Mandatory=$true)][string] $filename)
{
	if(!(Get-Variable -Name runtimeLogFile -Scope Global -ErrorAction Ignore))
	{
		Set-Variable -Name runtimeLogFile -Value $filename -Scope Global
		logThis -msg "the global:runtimeLogFile does not exist, setting it to $($global:runtimeLogFile)"
	} else {
		logThis -msg "The runtime log file is already set. Re-using and logging to $($global:runtimeLogFile)"
	}
	if (!(Test-Path -path $global:runtimeLogFile))
	{
		getLongDateTime | out-file $filename
	}
}

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

$runtimeStart = Get-Date
$datestring =  Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$PATHSEPARATOR=[IO.Path]::DirectorySeparatorChar
Set-Variable -Name scriptName -Value $($MyInvocation.MyCommand.name) -Scope Global
Set-Variable -Name logDir -Value $logDir -Scope Global
Set-Variable -Name logTofile -Value "$($global:logDir)$($PATHSEPARATOR)$($($global:scriptName).Replace(".ps1","-$($datestring).log"))" -Scope Global
Set-Variable -Name runtimeLogFile -Value "$($global:logDir)$($PATHSEPARATOR)$($($global:scriptName).Replace(".ps1","-$($datestring).log"))" -Scope Global
Set-Variable -Name lastLogEntry -Value "$($global:logDir)$($PATHSEPARATOR)$($($global:scriptName).Replace(".ps1","-$($datestring)-Lastlog.log"))" -Scope Global

#get-date | Out-file $global:runtimeLogFile #
Write-host  "Writing log file to $($global:logTofile)"


if ($hours -eq 0)
{
    $reportPeriod="ALL"
} else {
    $reportPeriod="$($hours)_hrs"
    $reportDateStart = (Get-Date).AddHours(-$hours)
}

$htmlOutfile="$logDir\backupreport-Past$($reportPeriod)_$datestring.html"



##### MAIN FUNCTION
Connect-SVT -OVC $OvcIP -Credential $Credentials

$metaInfo = @()
if ($hours -eq 0)
{
    $metaInfo += "tableHeader=All SimpliVity Backups"
    $metaInfo += "introduction=The following table summarises the all backup and their states found in the federation."
} else {
    $metaInfo += "tableHeader=SimpliVity Backups for the last $LastPeriodInHrs $hourString"
    $metaInfo += "introduction=The following table summarises the backup state for the last $LastPeriodInHrs$hourString."
}

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
$VMNameCount = ($VMName | Measure-Object).Count
if ($VMName -and $VMNameCount -eq 1)
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

<# Get HOST INFORMATION #>


if($exportHostInformation)
{   
    Write-Progress -Activity "Running report" -Id 0 -PercentComplete (1/3*100) -CurrentOperation "Exporting Omnistack Systems information"
    logThis -msg "Exporting a OmniStack Host Capacity information -----------"
    $hostReport = @()
    $htmlReport += "`n<h2>Federation OmniStack Hosts</h2><p>The table below presents of OmniStakc Controller VMs in the federation. This list was provided by OVC <i>$OvcIP</i>.</p>"
    $objects = Get-SVThost | Sort-Object ClusterName,Hostname 
    $jindex=0
    $objects | ForEach-Object {
        Write-Progress -Id 1 -Activity "Processing OmnitStack Node $($_.Hostname) :- $jindex/$(($objects | measure-object).Count)" -ParentId 0 -PercentComplete ($jindex / ($objects | measure-object).Count * 100) -CurrentOperation "Processing OmniStakc System"
        $svthost = $_
        logThis -msg "Processing $($svthost.Hostname)"
        $row = New-Object System.Object
        $row | Add-Member -MemberType NoteProperty -Name "vSphere Host" -Value $svthost.Hostname
        $row | Add-Member -MemberType NoteProperty -Name "Cluster" -Value $svthost.Clustername
        $row | Add-Member -MemberType NoteProperty -Name "OVC IP" -Value $svthost.ManagementIP
        $row | Add-Member -MemberType NoteProperty -Name "OVC Version" -Value $svthost.Version

        $perc = $($($svthost.FreeSpaceGB -replace ',','') * 1) / $($($svthost.AllocatedCapacityGB -replace ',','') * 1) * 100
        if ($niceFormat)
        {
            $row | Add-Member -MemberType NoteProperty -Name "Actual Node Capacity" -Value (getSize -unit "GB" -Val $svthost.AllocatedCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Actual Used Capacity" -Value (getSize -unit "GB" -Val $svthost.UsedCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Actual Free Capacity" -Value "$((getSize -unit GB -Val $svthost.FreeSpaceGB)) ($(([math]::round($perc,2)))%)"
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - Total" -Value (getSize -unit "GB" -Val $svthost.UsedLogicalCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by VM Data" -Value (getSize -unit "GB" -Val $svthost.StoredVMdataGB)
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by Local Backups" -Value (getSize -unit "GB" -Val $svthost.LocalBackupCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by Remote Backups" -Value (getSize -unit "GB" -Val $svthost.RemoteBackupCapacityGB)
        } else {
            $row | Add-Member -MemberType NoteProperty -Name "Actual Node Capacity(GB)" -Value ("{0:N}" -f $svthost.AllocatedCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Actual Used Capacity(GB)" -Value ("{0:N}" -f $svthost.UsedCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Actual Free Capacity(GB)" -Value "$(('{0:N}' -f $svthost.FreeSpaceGB)) ($(([math]::round($perc,2)))%)"
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - Total(GB)" -Value ("{0:N}" -f $svthost.UsedLogicalCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by VM Data(GB)" -Value ("{0:N}" -f $svthost.StoredVMdataGB)
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by Local Backups(GB)" -Value ("{0:N}" -f $svthost.LocalBackupCapacityGB)
            $row | Add-Member -MemberType NoteProperty -Name "Logical Used Capacity - by Remote Backups(GB)" -Value ("{0:N}" -f $svthost.RemoteBackupCapacityGB)
        }
        $hostReport += $row
        $jindex++
        #pause
    }
    logThis -msg "Complete"
    Write-Progress -Id 1 -Activity "Processing OmnitStack Node" -Completed

    if ($hostReport)
    {
        
        logThis -msg "Writing to CSV"
        $hostReport | Export-csv -NoTypeInformation "$logDir\hosts_capacity_Past$($reportPeriod)_$datestring.csv"
        
        logThis -msg "Writing to HTML file"
        $htmlReport +=  ($hostReport | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""MyTablesytle"""  -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
        $htmlReport += "`n"
    } else {
        logThis -msg "An error has occured and cannot export capacity information for any federation simplivity OVCs"
        $htmlReport +=  "An error has occured and cannot export capacity information for any federation simplivity OVCs."
    }
}



# This is intended to export the same thing as exportVMinformation, but limited to VMs with backup files only
if ($exportBackupsToVMSummary)
{ 
    #Get the list of VMs from the backups
    $allvmBackups = get-svtbackup -ALL 

    # If not skipping calculation meaning we want to know the size of all backups
    if (!$skipCalculation -and $allvmBackups)
    {
        $allvmBackups | Update-SVTbackupUniqueSize
        #re-read the backups again
        $allvmBackups = get-svtbackup -ALL
    }

}

# List VMs with Backups
if ($exportListOfVMsWithBackups)
{ 

}

# List VMs without Backups
if ($exportListOfVMsWithBackups)
{ 
    
}

# Show host table utilisation
if ($exportVMHostMapping)
{ 
    logThis -msg "Exporting replica to Host Mapping -------------"
    $htmlReport += "`n<h2>VM Replica Objects vs Host Mapping</h2><p>The section below presents of the mapping of VM replica to Hosts broken down by cluster.</p>"
    Write-Progress -Activity "Running report" -Id 0 -PercentComplete (2/3*100) -CurrentOperation "Exporting VM replica to Host Mapping"
    $omnistackHost = Get-SVThost
    $replicaSets = Get-SVTvmReplicaSet
    # Show by Cluster
    $omnistackHost | Group-Object -Property "ClusterName" | ForEach-Object {
        $cluster = $_
        $objects = @()
        logThis -msg "Processing $($cluster.Name)"
        $htmlReport += "`n<h3>Cluster Mappings for $($cluster.Name)</h3>"
        $replicaSets | Where-Object {$_.Clustername -eq $cluster.Name} | ForEach-Object {
            $replicaSet = $_
            $row = New-Object System.Object
            $row | Add-Member -MemberType NoteProperty -Name "VMnane" -Value $replicaSet.VMname
            $cluster.Group.HostName | sort-object | ForEach-Object {
                $hostname = $_
                if ($replicaSet.Primary -eq $hostname)
                {
                    $row | Add-Member -MemberType NoteProperty -Name "$hostname" -Value "P"
                } elseif ($replicaSet.Secondary -eq $hostname){
                    $row | Add-Member -MemberType NoteProperty -Name "$hostname" -Value "S"
                } else {
                    $row | Add-Member -MemberType NoteProperty -Name "$hostname" -Value ""
                }
            }
            $objects += $row
        }
        $htmlReport += ( $objects | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""MyTablesytle""" -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
        $htmlReport += "`n"
    }
}


if ($exportVMInformation)
{
    $objects = @()
    Write-Progress -Activity "Running report" -Id 0 -PercentComplete (2/3*100) -CurrentOperation "Exporting Virtual Machines System information"
    logThis -msg "Exporting VM information -----------------"
    $reportingPeriodTxt=""

    if ($hours -eq 0)
    {
        $reportingPeriodTxt += "all backups"
    } else {
        $reportingPeriodTxt += "backups found for the past $hours hours"
    }
    
    $targetSystems=""
    if ($VMName -and $VMNameCount -eq 1)
    {   
        $targetSystems="virtual machine $VMName"
        $objects = Get-SVTvm -VMname $VMName
    } elseif ($VMName -and $VMNameCount -gt 1)
    {   
        $targetSystems="several virtual machines"
        $objects = @() 
        $VMName | ForEach-Object {
            $tmpObject = Get-SVTvm -VMname $_
            if ($tmpObject)
            {
                $VMName += $tmpObject
            } else {
                logThis -msg "One or more of the VMs specified doesn't exist"
            }
        }
    } else {
        $targetSystems="all virtual machines"
        $objects = Get-SVTVm 
    }
    $htmlReport += "`n<h2>Usage summary for $targetSystems</h2>"
    $htmlReport += "`n<p>The following table list a usage report for $targetSystems. The calculations of backups are made from the list of $reportingPeriodTxt .</p>"
    <## Process providing there are objects to pr#>
    if ($objects)
    {
        <# it is faster to get a list of all backups and store them in a varliable and make a comparision with the VM that you need.
        Write-Progress -Id 1 -Activity "Processing all Backup Snapshots ""$($_.VMName)""" -CurrentOperation "Calculating Unique Bcakup Sizes"
        $allvmBackups = get-svtbackup -ALL
        if (!$skipCalculation -and $allvmBackups)
        {
            $allvmBackups | Update-SVTbackupUniqueSize
            #re-read the backups again
            $allvmBackups = get-svtbackup -ALL
        }#>
        $vms = @()
        $jindex=0
        $objects | ForEach-Object {
            Write-Progress -Id 1 -Activity "Processing VM ""$($_.VMName)"" :- $jindex/$(($objects | measure-object).Count)" -ParentId 0 -PercentComplete ($jindex / ($objects | measure-object).Count * 100)
            $vmObject = $_ | Select-Object -Property "VMName","ClusterName","DatastoreName","PolicyName","CreateDate","Hostname","HAStatus"
            logThis -msg "Processing $($vmObject.VMName) :- $jindex/$(($objects | measure-object).Count)"
            #$vmObject = Get-SVTVm -VMName $VMName | Select-Object -Property "VMName","ClusterName","DatastoreName","PolicyName","CreateDate","Hostname","HAStatus"
            $vmReplicaSet = Get-SVTvmReplicaSet -VMName $vmObject.VMName
            $vmObject | Add-Member -MemberType NoteProperty -Name "Primary Copy" -Value $vmReplicaSet.Primary
            $vmObject | Add-Member -MemberType NoteProperty -Name "Secondary Copy" -Value $vmReplicaSet.Secondary
            
            # 1 Read
            if ($hours -eq 0)
            {
                # Grab all of the backups for this guy
                #$vmBackups = $allvmBackups | Where-Object {$_.VMname -eq $vmObject.VMName}
                $vmBackups = Get-SVTBackup -VMName $vmObject.VMName -Limit 3000 -ErrorAction SilentlyContinue #  3000 is the max in simplivity
            } else {
                #$vmBackups = $allvmBackups | Where-Object {$_.VMname -eq $vmObject.VMName -and $_.CreateDate -gt $reportDateStart}
                $vmBackups = Get-SVTBackup -VMName $vmObject.VMName -Hour $hours -ErrorAction SilentlyContinue
            }
         
             #$vmBackupsTemp = Get-SVTbackup -VMName $vmObject.VMName -ErrorAction SilentlyContinue
             # Need to calculate teh Unique Sizes, and read a second time
             if (!$skipCalculation -and $vmBackups)
             {
                 $hindex=0
                 $vmBackups | ForEach-Object {
                     Write-Progress -Id 2 -Activity "Calculating Snapshots of VM $($_.VMName) :- $hindex/$($($vmBackups | measure-object).Count)" -ParentId 1 -PercentComplete ($hindex / ($vmBackups | measure-object).Count * 100) -CurrentOperation "Calculated Unique Size for backups"
                     Update-SVTbackupUniqueSize -BackupId $_.BackupID
                     $hindex++
                 }
                 Write-Progress -Id 2 -Completed -Activity ""
                 # 2nd Read after the calculations
                if ($hours -eq 0)
                {
                    # Grab all of the backups for this guy
                    #$vmBackups = $allvmBackups | Where-Object {$_.VMname -eq $vmObject.VMName}
                    $vmBackups = Get-SVTBackup -VMName $vmObject.VMName -Limit 3000 #  3000 is the max in simplivity
                } else {
                    #$vmBackups = $allvmBackups | Where-Object {$_.VMname -eq $vmObject.VMName -and $_.CreateDate -gt $reportDateStart}
                    $vmBackups = Get-SVTBackup -VMName $vmObject.VMName -Hour $hours
                }
            }

            if ($vmBackups)
            {
                $backupCount = ($vmBackups | Measure-Object).Count
                $backupSizeMB = (($vmBackups | measure-object -Property UniqueSizeMB -Sum).Sum)
            } else 
            {
                $backupCount = 0
                $backupSizeMB = 0
            }
            $vmObject | Add-Member -MemberType NoteProperty -Name "Backups Found" -Value $backupCount
            if ($niceFormat)
            {
                $vmObject | Add-Member -MemberType NoteProperty -Name "Backup Size" -Value (getSize -unit "MB" -val $backupSizeMB)
            } else {
                $vmObject | Add-Member -MemberType NoteProperty -Name "Backup Size (GB)" -Value ("{0:N}" -f ($backupSizeMB/1024))
            }
            $vms += $vmObject
            
            $jindex++
        }
        
        if ($vms)
        {
            logThis -msg "Writing to CSV"
            $vms | Export-csv -NoTypeInformation "$logDir\virtualmachines_$datestring.csv"

            logThis -msg "Writing to HTML"
            $htmlReport += ( $vms | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""MyTablesytle""" -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
        }
        $htmlReport += "`n"
    } else {
        logThis -msg "None found"
        $htmlReport += "<p><i>None found.</i></p>"
    }
}

<# Get BACKUP INFORMATION #>
if ($exportBackupInformation)
{
    ######### BACKUPS ##############
    Write-Progress -Activity "Running report" -Id 1 -PercentComplete (3/3*100)
    logThis -msg "Exporting backup data information ---------"
    if ($VMName)
    {
        if ($hours -eq 0)
        {
            $allbackups = Get-SVTbackup -VMname $VMName -Limit 3000  -ErrorAction SilentlyContinue
        } else {
            $allbackups = Get-SVTbackup -Hour $hours -VMname $VMName  -ErrorAction SilentlyContinue
        }
    } else {
        if ($hours -eq 0)
        {  
            $allbackups = Get-SVTbackup -All  -ErrorAction SilentlyContinue
        } else {
            $allbackups = Get-SVTbackup -Hour $hours  -ErrorAction SilentlyContinue
        }
    }


    <#
        Exporting list of failed or uncompleted backups
    #>
    logThis -msg "Exporting a list of non ACTIVE and FAILED backups"
    if ($VMname)
    {
        $htmlReport += "`n<h2>Incomplete or Failed Backups for $VMName for the past $hours hours</h2><p>The table below presents a list of incomplete and failed backups for the past $hours hours for virtual machine <i>$VMName</i>. The list is ordered from the most recent to oldest.</p>"
    } else {
        $htmlReport += "`n<h2>All Incomplete or Failed Backups for the past $hours hours</h2><p>The table below presents a list of incomplete and failed backups for the past $hours hours for all virtual machines found in the federation. The list is ordered from the most recent to oldest.</p>"
    }
    # Enumerate NONE protected backups (Active or failures)
    $nonProtectedBackups = $allbackups | Where-Object {$_.BackupState -ne "PROTECTED"}
    #$nonProtectedBackups | Export-csv -NoTypeInformation "$logDir\backups_failed_Past$($reportPeriod)_$($datestring)_raw.csv"

    if ($nonProtectedBackups)
    {
        logThis -msg "-> $(($nonProtectedBackups | measure-object).Count) found."
        $htmlReport += "<p> $($($nonProtectedBackups | measure-object).Count) found.</p>"
        if ($niceFormat)
        {
            $nonProtectedBackupsFinal = $nonProtectedBackups | select-object @{n="Backup Taken On";e={$_.CreateDate}},
                                                                            @{n="Virtual Machine";e={$_.VMname}},
                                                                            @{n="Calculated Unique Size";e={getSize -unit "MB" -val $_.UniqueSizeMB}},
                                                                            @{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},
                                                                            @{n="Backup will expire on";e={$_.ExpiryDate}},
                                                                            @{n="Virtual Machine Size";e={getSize -unit "GB" -val $_.SizeGB}},
                                                                            @{n="Amt of Data Sent to Remote Site";e={getSize -unit "MB" -val $_.SentMB}},
                                                                            @{n="VM State During Backup";e={$_.VMState}},
                                                                            @{n="Backup Name";e={$_.BackupName}}  | sort-Object "Backup Taken On" -Descending
        } else {
            $nonProtectedBackupsFinal = $nonProtectedBackups | select-object @{n="Backup Taken On";e={$_.CreateDate}},
                                                                            @{n="Virtual Machine";e={$_.VMname}},
                                                                            @{n="Calculated Unique Size (GB)";e={"{0:N}" -f ($_.UniqueSizeMB/1024)}},
                                                                            @{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},
                                                                            @{n="Backup will expire on";e={$_.ExpiryDate}},
                                                                            @{n="Virtual Machine Size (GB)";e={"{0:N}" -f $_.SizeGB}},
                                                                            @{n="Amt of Data Sent to Remote Site (GB)";e={"{0:N}" -f ($_.SentMB/1024)}},
                                                                            @{n="VM State During Backup";e={$_.VMState}},
                                                                            @{n="Backup Name";e={$_.BackupName}}  | sort-Object "Backup Taken On" -Descending
        }
                                     
        logThis -msg "Writing to HTML file"
        $htmlReport += ( $nonProtectedBackupsFinal | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""MyTablesytle""" -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
        $htmlReport += "`n"

        logThis -msg "Writing to CSV"
        $nonProtectedBackupsFinal | Export-csv -NoTypeInformation "$logDir\backups_failed_Past$($reportPeriod)_$datestring.csv"

    } else {
        logThis -msg "None found"
        $htmlReport += "<p><i>None found.</i></p>"
    }
    if ($VMname)
    {
        $htmlReport += "`n<h2>Successful Backups for $VMName for the past $hours hours</h2><p>The table below presents a list of successful backups for the past $hours hours for virtual machine <i>$VMName</i>. The list is ordered from the most recent to oldest.</p>"
    } else {
        $htmlReport += "`n<h2>All Successful Backups for the past $hours hours</h2><p>The table below presents a list of successful backups for the past $hours hours for all virtual machine in the federation. The list is ordered from the most recent to oldest.</p>"
    } 

    logThis -msg "-> Collecting list of protected backups.."
    $protectedBackups = $allbackups | Where-Object {$_.BackupState -eq "PROTECTED"}
    logThis -msg "-> Calculating Unique Data Sizes for backups"
    if ($($protectedBackups | measure-object).Count -gt 0)
    {
        logthis -msg "$($($protectedBackups | measure-object).Count -gt 0) protected backups found"
        if ($skipCalculation)
        {
            logThis -msg "Skipping Unique Size calculations [User option]"
        } else {
            logThis -msg "Calculating unique sizes of backups [default]"
            $protectedBackups | Update-SVTbackupUniqueSize
        }
        logThis -msg "-> Sleeping $sleepTime just in case.."
        sleep $sleepTime

        logThis -msg "Re-reading the backup lists with the updated Unique Size"
        if ($VMName)
        {
            if ($hours -eq 0)
            {
                logThis -msg "Loading all backup details for VM $VMname (Protected backups only)"
                $allbackups = (Get-SVTbackup -VMname $VMName -Limit 3000 -ErrorAction SilentlyContinue| Where-Object {$_.BackupState -eq "PROTECTED"})
            } else {
                logThis -msg "Loading backups details for the past $hours for VM $VMname (Protected backups only)"
                $allbackups = (Get-SVTbackup -Hour $hours -VMname $VMName -ErrorAction SilentlyContinue | Where-Object {$_.BackupState -eq "PROTECTED"})
            }

        } else {
            if ($hours -eq 0)
            {
                $allbackups = (Get-SVTbackup -All -ErrorAction SilentlyContinue | Where-Object {$_.BackupState -eq "PROTECTED"})
            } else {
                $allbackups = (Get-SVTbackup -Hour $hours -ErrorAction SilentlyContinue | Where-Object {$_.BackupState -eq "PROTECTED"})
            }
        }
        $protectedBackupsRaw = $protectedBackups
        #$protectedBackupsRaw | Export-csv -NoTypeInformation "$logDir\backups_successful_before_Past$($reportPeriod)_$datestring.csv"
        if ($niceFormat)
        {
            logThis -msg "Formatting output in nice file sizes output"
            $protectedBackups = $allbackups | select-object @{n="Backup Taken On";e={$_.CreateDate}},
                                                        @{n="Virtual Machine";e={$_.VMname}},
                                                        @{n="Calculated Unique Size";e={getSize -unit "MB" -val $_.UniqueSizeMB}},
                                                        @{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},
                                                        @{n="Backup will expire on";e={$_.ExpiryDate}},
                                                        @{n="Virtual Machine Size";e={getSize -unit "GB" -val $_.SizeGB}},
                                                        @{n="Amt of Data Sent to Remote Site (GB)";e={getSize -unit "MB" -val $_.SentMB}},
                                                        @{n="VM State During Backup";e={$_.VMState}},
                                                        @{n="Backup Name";e={$_.BackupName}}  | sort-Object "Backup Taken On" -Descending
        } else {
            logThis -msg "Formating output - all output in GB"
            $protectedBackups = $allbackups | select-object @{n="Backup Taken On";e={$_.CreateDate}},
                                                        @{n="Virtual Machine";e={$_.VMname}},
                                                        @{n="Calculated Unique Size (GB)";e={"{0:N}" -f ($_.UniqueSizeMB/1024)}},
                                                        @{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},
                                                        @{n="Backup will expire on";e={$_.ExpiryDate}},
                                                        @{n="Virtual Machine Size (GB)";e={"{0:N}" -f $_.SizeGB}},
                                                        @{n="Amt of Data Sent to Remote Site (GB)";e={"{0:N}" -f ($_.SentMB/1024)}},
                                                        @{n="VM State During Backup";e={$_.VMState}},
                                                        @{n="Backup Name";e={$_.BackupName}}  | sort-Object "Backup Taken On" -Descending
        }
        logThis -msg "Writing to CSV"                 
        $protectedBackups | Export-csv -NoTypeInformation "$logDir\backups_successful_Past$($reportPeriod)_$datestring.csv"

        #select-object CreateDate,VMname,@{n="UniqueSizeGB As of Now";e={[math]::round($_.UniqueSizeMB/1024,2)}},@{n="Backup Data Written To";e={"$($_.DataCenterName)\$($_.DestinationName)"}},ExpiryDate,SizeGB,SentMB,@{n="VMStateDuringBackup";e={$_.VMState}},BackupName | sort-Object CreateDate -Descending

        logThis -msg "Getting VM information"
        $vms = @()
        $protectedBackups | Group-Object -Property "Virtual Machine" | ForEach-Object {
            logThis -msg "." -NoNewline $true
            logThis -msg "Processing $($_.Name)"
            $vmObject = Get-SVTvm -VMname $_.Name
            if ($vmObject)
            {
                $vms += $vmObject
            }
        }

        # Adding VM inforamtion in the array for inclusion
        $protectedBackups | ForEach-Object {
            logThis -msg "*" -NoNewline $true
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
        $totalCapacity = ""
        $totalCapacity = getSize -unit "MB" -val (($protectedBackupsRaw | measure-Object -Sum -Property "UniqueSizeMB").Sum)
        $totalBackupCount = ($protectedBackupsRaw | measure-object).Count

        $totalVMCount = 0
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
        logThis -msg "Writing to HTML"
        $htmlReport +=  ($protectedBackups | ConvertTo-HTML -Fragment -As "Table") -replace "<table","$caption<table class=""MyTablesytle"""  -replace "&lt;/li&gt;","</li>" -replace "&lt\;li&gt;","<li>" -replace "&lt\;/ul&gt;","</ul>" -replace "&lt\;ul&gt;","<ul>"  -replace "`r","<br>"
        $htmlReport += "`n"

    } else {
        logThis -msg "Non found."
        $htmlReport += "<p><i>None found.</i></p>"
    }
}

# DEBUG INFORMATION
$runtimeEnd = Get-Date
$htmlReport += "`n--------------------------------- DEBUG ---------------------------"
Get-Variable | ForEach-Object {
    if ($_.Name -notlike "htmlReport")
    {
        $htmlReport += "`n$($_.Name) = $($_.Value)"
        logThis -msg "$($_.Name) = $($_.Value)"
    }
}
$htmlReport += @"
</div></BODY>
"@

$htmlReport | Out-File $htmlOutfile

# Open the report
& $htmlOutfile

